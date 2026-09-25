//! Native host I/O: one shared client policy, cancellation reaches sockets, storage
//! is plugin-owned. No source bytes, credentials or raw paths are written to logs.
use crate::{
    Runtime,
    catalog::{atomic_write, safe_relative, usage},
    error::{Error, Result, invalid, string},
};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};
use tokio_util::sync::CancellationToken;

pub fn http_client(proxy: Option<&str>) -> Result<reqwest::Client> {
    let mut b=reqwest::Client::builder().timeout(Duration::from_secs(20)).connect_timeout(Duration::from_secs(10))
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")
        .redirect(reqwest::redirect::Policy::limited(5));
    if let Some(url) = proxy {
        let parsed = reqwest::Url::parse(url).map_err(|_| invalid("Invalid upstream proxy"))?;
        if !["http", "https", "socks5", "socks5h"].contains(&parsed.scheme()) {
            return Err(invalid("Unsupported proxy protocol"));
        }
        b = b.proxy(reqwest::Proxy::all(url).map_err(|_| invalid("Invalid upstream proxy"))?);
    }
    b.build().map_err(|_| {
        Error::new(
            "runtime_unavailable",
            "Native HTTP client initialization failed",
        )
    })
}
pub fn check_url(runtime: &Runtime, url: &str) -> Result<reqwest::Url> {
    let u = reqwest::Url::parse(url).map_err(|_| invalid("Invalid HTTP URL"))?;
    if (u.scheme() != "https" && !(runtime.test_mode && u.scheme() == "http"))
        || u.host_str().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
    {
        return Err(invalid("HTTP requires an HTTPS URL without credentials"));
    }
    Ok(u)
}
pub async fn fetch(
    runtime: Arc<Runtime>,
    request: Value,
    cancel: CancellationToken,
) -> Result<Value> {
    let url = check_url(&runtime, string(&request, "url")?)?;
    let operation = async {
        let _permit = runtime
            .http_slots
            .acquire()
            .await
            .map_err(|_| Error::new("runtime_unavailable", "HTTP worker closed"))?;
        let client = runtime.client.read().unwrap().clone();
        let mut q = client.get(url);
        if let Some(headers) = request["headers"].as_object() {
            if headers.len() > 32 {
                return Err(invalid("Too many HTTP headers"));
            }
            for (key, value) in headers {
                let v = value
                    .as_str()
                    .filter(|s| s.len() <= 8192)
                    .ok_or_else(|| invalid("Invalid HTTP header"))?;
                if ["host", "content-length", "connection"].contains(&key.to_lowercase().as_str()) {
                    return Err(invalid("Restricted HTTP header"));
                }
                q = q.header(key, v);
            }
        }
        runtime
            .http_requests
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut response = q.send().await.map_err(|e| {
            Error::new(
                if e.is_timeout() {
                    "runtime_timeout"
                } else {
                    "network_error"
                },
                "Native HTTP request failed",
            )
        })?;
        let status = response.status().as_u16();
        if !response.status().is_success() {
            return Err(Error::new(
                "source_http_error",
                &format!("Upstream HTTP {status}"),
            ));
        }
        let mut body = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| Error::new("network_error", "HTTP body read failed"))?
        {
            if body.len() + chunk.len() > 4 * 1024 * 1024 {
                return Err(invalid("HTTP body exceeds 4 MiB"));
            }
            body.extend_from_slice(&chunk);
        }
        Ok(
            json!({"body":String::from_utf8(body).map_err(|_|invalid("HTTP text is not UTF-8"))?,"status":status,"headers":{}}),
        )
    };
    tokio::select! {biased; _=cancel.cancelled()=>Err(Error::new("cancelled","Native HTTP request cancelled")), result=operation=>result}
}
pub struct CallContext {
    pub runtime: Arc<Runtime>,
    pub plugin_id: String,
    pub cancel: CancellationToken,
    pub started: Instant,
    pub requests: std::sync::atomic::AtomicUsize,
}
impl CallContext {
    pub fn call(&self, request: Value) -> Result<Value> {
        let op = string(&request, "op")?;
        if op == "cancelled" {
            return Ok(json!(self.cancel.is_cancelled()));
        }
        if self.cancel.is_cancelled() {
            return Err(Error::new("cancelled", "Native operation cancelled"));
        }
        if self.started.elapsed() > Duration::from_secs(90) {
            self.cancel.cancel();
            return Err(Error::new(
                "runtime_timeout",
                "Native invocation deadline exceeded",
            ));
        }
        match op {
            "http" => {
                if self
                    .requests
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                    >= 128
                {
                    return Err(invalid("Too many HTTP requests"));
                }
                self.runtime.handle.block_on(fetch(
                    self.runtime.clone(),
                    request,
                    self.cancel.clone(),
                ))
            }
            "storage.read" | "storage.write" | "storage.remove" => self.storage(&request),
            "log" => Ok(Value::Null),
            _ => Err(Error::new("unsupported", "Unknown native host operation")),
        }
    }
    fn storage(&self, request: &Value) -> Result<Value> {
        let _guard = self.runtime.storage_lock.lock().unwrap();
        let area = string(request, "area")?;
        if !["data", "cache"].contains(&area) {
            return Err(invalid("Invalid private storage area"));
        }
        let relative = string(request, "path")?;
        if relative.len() > 240 || !safe_relative(relative) {
            return Err(invalid("Invalid private storage path"));
        }
        let base = self
            .runtime
            .root
            .join("plugins")
            .join(&self.plugin_id)
            .join(area);
        std::fs::create_dir_all(&base)?;
        let path = checked_path(&base, relative)?;
        match string(request, "op")? {
            "storage.read" => match std::fs::read(&path) {
                Ok(bytes) if bytes.len() <= 8 * 1024 * 1024 => Ok(json!(
                    String::from_utf8(bytes).map_err(|_| invalid("Storage value is not UTF-8"))?
                )),
                Ok(_) => Err(invalid("Storage file exceeds 8 MiB")),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Value::Null),
                Err(e) => Err(e.into()),
            },
            "storage.write" => {
                let text = string(request, "value")?;
                let existing = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
                if text.len() > 8 * 1024 * 1024
                    || usage(&base)?.0.saturating_sub(existing) + text.len() as u64
                        > 64 * 1024 * 1024
                {
                    return Err(invalid("Private storage quota exceeded"));
                }
                atomic_write(&path, text.as_bytes())?;
                Ok(Value::Null)
            }
            _ => {
                if path.exists() {
                    std::fs::remove_file(path)?;
                }
                Ok(Value::Null)
            }
        }
    }
}
fn checked_path(base: &Path, relative: &str) -> Result<PathBuf> {
    let mut path = base.to_path_buf();
    for p in Path::new(relative).components() {
        path.push(p);
        if let Ok(m) = std::fs::symlink_metadata(&path) {
            if m.file_type().is_symlink() {
                return Err(invalid("Storage symlinks are unsupported"));
            }
        }
    }
    Ok(path)
}
