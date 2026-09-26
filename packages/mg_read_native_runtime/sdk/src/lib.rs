//! Small statically linked source SDK. A library owns one initialized instance
//! until worker exit. Content operations are serialized; async resource streams
//! and cancellation use one I/O executor thread, not parallel source execution.
pub mod cache;
pub mod error;
mod hls;
mod http;
mod resource;

use error::{Error, Result, invalid};
use mgread_native_abi::{Buffer, MAX_MESSAGE};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio_util::sync::CancellationToken;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    plugin_id: String,
    generation: String,
    cache_dir: PathBuf,
    upstream_proxy: Option<String>,
    #[serde(default)]
    test_mode: bool,
}
pub struct Context {
    pub cache: cache::Cache,
    executor: tokio::runtime::Runtime,
    client: reqwest::Client,
    resources: Arc<resource::Resources>,
    stop: CancellationToken,
    server: Mutex<Option<tokio::task::JoinHandle<()>>>,
    calls: Mutex<Calls>,
    test_mode: bool,
}
#[derive(Default)]
struct Calls {
    active: Option<(u64, CancellationToken)>,
    early_cancel: HashSet<u64>,
}
pub struct Call<'a> {
    context: &'a Context,
    cancel: CancellationToken,
    started: Instant,
}
impl Call<'_> {
    pub fn cancelled(&self) -> bool {
        self.cancel.is_cancelled()
            || self.context.stop.is_cancelled()
            || self.started.elapsed() > Duration::from_secs(90)
    }
    pub fn cache(&self) -> &cache::Cache {
        &self.context.cache
    }
    pub fn http(&self, request: &Value) -> Result<Value> {
        if self.cancelled() {
            return Err(error::cancelled());
        }
        let url = http::check_url(
            request["url"]
                .as_str()
                .ok_or_else(|| invalid("Missing URL"))?,
            self.context.test_mode,
        )?;
        let headers = http::headers(&request["headers"])?;
        self.context.executor.block_on(async {
            let operation = async {
                let response = http::open(&self.context.client, reqwest::Method::GET, url, headers, self.context.test_mode).await?;
                let status = response.status().as_u16();
                if !response.status().is_success() { return Err(Error::new("source_http_error", &format!("Upstream HTTP {status}"))); }
                let body = String::from_utf8(http::bounded_body(response, 4 * 1024 * 1024).await?).map_err(|_| invalid("Source text is not UTF-8"))?;
                Ok(json!({"body":body,"status":status,"headers":{}}))
            };
            tokio::select! { biased; _ = self.cancel.cancelled() => Err(error::cancelled()), _ = self.context.stop.cancelled() => Err(error::cancelled()), result = tokio::time::timeout(Duration::from_secs(20), operation) => result.map_err(|_| Error::new("runtime_timeout", "Source HTTP timed out"))? }
        })
    }
}
impl Context {
    fn open(config: Config) -> Result<Arc<Self>> {
        if !component(&config.plugin_id)
            || config.generation.len() != 64
            || !config.generation.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err(invalid("Invalid plugin initialization identity"));
        }
        let cache = cache::Cache::open(&config.cache_dir)?;
        let client = http::client(config.upstream_proxy.as_deref())?;
        let executor = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()?;
        let stop = CancellationToken::new();
        let listener = executor.block_on(tokio::net::TcpListener::bind("127.0.0.1:0"))?;
        let port = listener.local_addr()?.port();
        let resources = resource::Resources::new(
            config.plugin_id,
            config.generation,
            port,
            client.clone(),
            stop.clone(),
            config.test_mode,
        );
        let router = resources.clone().router();
        let shutdown = stop.clone();
        let server = executor.spawn(async move {
            let _ = axum::serve(listener, router)
                .with_graceful_shutdown(shutdown.cancelled_owned())
                .await;
        });
        Ok(Arc::new(Self {
            cache,
            executor,
            client,
            resources,
            stop,
            server: Mutex::new(Some(server)),
            calls: Mutex::new(Calls::default()),
            test_mode: config.test_mode,
        }))
    }
    fn invoke(
        &self,
        id: u64,
        input: Value,
        handler: fn(&Call<'_>, Value) -> Result<Value>,
    ) -> Result<Value> {
        if id == 0 || self.stop.is_cancelled() {
            return Err(Error::new("plugin_closed", "Source is closed"));
        }
        let cancel = self.stop.child_token();
        {
            let mut calls = self.calls.lock().unwrap();
            if calls.active.is_some() {
                return Err(Error::new(
                    "runtime_busy",
                    "Source calls must be serialized",
                ));
            }
            if calls.early_cancel.remove(&id) {
                cancel.cancel();
            }
            calls.active = Some((id, cancel.clone()));
        }
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let call = Call {
                context: self,
                cancel,
                started: Instant::now(),
            };
            if call.cancelled() {
                return Err(error::cancelled());
            }
            if input["method"] == "resource.inspect" {
                return self
                    .resources
                    .inspect(input["request"]["url"].as_str().unwrap_or(""));
            }
            let mut result = handler(&call, input)?;
            if call.cancelled() {
                return Err(error::cancelled());
            }
            self.resources.project(&mut result, 0)?;
            Ok(result)
        }))
        .unwrap_or_else(|_| Err(Error::new("native_panic", "Source call failed internally")));
        self.calls.lock().unwrap().active = None;
        result
    }
    fn cancel(&self, id: u64) {
        let mut calls = self.calls.lock().unwrap();
        if let Some((active, cancel)) = &calls.active {
            if *active == id {
                cancel.cancel();
                return;
            }
        }
        // Only the host's current ABI call can arrive just before registration.
        if calls.early_cancel.len() < 64 {
            calls.early_cancel.insert(id);
        }
    }
    fn shutdown(&self) -> Result<Value> {
        self.resources.close();
        if self.calls.lock().unwrap().active.is_some() {
            return Err(Error::new("runtime_busy", "Source call is still running"));
        }
        if let Some(mut server) = self.server.lock().unwrap().take() {
            self.executor.block_on(async {
                if tokio::time::timeout(Duration::from_secs(1), &mut server)
                    .await
                    .is_err()
                {
                    server.abort();
                    let _ = server.await;
                }
            });
        }
        Ok(json!({"stopped":true}))
    }
}
fn component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 160
        && value != "."
        && value != ".."
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

pub struct PluginInstance {
    plugin_id: &'static str,
    context: Mutex<Option<Arc<Context>>>,
}
impl PluginInstance {
    pub const fn new(plugin_id: &'static str) -> Self {
        Self {
            plugin_id,
            context: Mutex::new(None),
        }
    }
    /// # Safety
    /// Input must be readable for length bytes until return.
    pub unsafe fn init(&self, input: *const u8, length: usize) -> Buffer {
        boundary(|| {
            let mut slot = self.context.lock().unwrap();
            if slot.is_some() {
                return Err(invalid("Source is already initialized"));
            }
            let config: Config = serde_json::from_value(unsafe { decode(input, length)? })?;
            if config.plugin_id != self.plugin_id {
                return Err(invalid("Plugin identity mismatch"));
            }
            let context = Context::open(config)?;
            let endpoint = context.resources.endpoint();
            *slot = Some(context);
            Ok(endpoint)
        })
    }
    /// # Safety
    /// Input must be readable for length bytes until return; invoke is serialized.
    pub unsafe fn invoke(
        &self,
        id: u64,
        input: *const u8,
        length: usize,
        handler: fn(&Call<'_>, Value) -> Result<Value>,
    ) -> Buffer {
        boundary(|| {
            let input = unsafe { decode(input, length)? };
            let context = self
                .context
                .lock()
                .unwrap()
                .clone()
                .ok_or_else(|| invalid("Source is not initialized"))?;
            context.invoke(id, input, handler)
        })
    }
    pub fn cancel(&self, id: u64) {
        if let Some(context) = self.context.lock().unwrap().as_ref() {
            context.cancel(id);
        }
    }
    pub fn shutdown(&self) -> Buffer {
        boundary(|| match self.context.lock().unwrap().as_ref() {
            Some(context) => context.shutdown(),
            None => Ok(json!({"stopped":true})),
        })
    }
}
unsafe fn decode(input: *const u8, length: usize) -> Result<Value> {
    if input.is_null() || length == 0 || length > MAX_MESSAGE {
        return Err(invalid("Invalid ABI input"));
    }
    Ok(serde_json::from_slice(unsafe {
        std::slice::from_raw_parts(input, length)
    })?)
}
fn boundary(action: impl FnOnce() -> Result<Value>) -> Buffer {
    let value = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(action)) {
        Ok(Ok(value)) => json!({"ok":true,"value":value}),
        Ok(Err(error)) => error.envelope(),
        Err(_) => Error::new("native_panic", "Source operation failed internally").envelope(),
    };
    let bytes = serde_json::to_vec(&value).unwrap_or_default();
    Buffer::from_vec(if bytes.len() <= MAX_MESSAGE {
        bytes
    } else {
        br#"{"ok":false,"error":{"code":"result_too_large","message":"Source result exceeds its limit"}}"#.to_vec()
    })
}

#[cfg(test)]
mod tests;
