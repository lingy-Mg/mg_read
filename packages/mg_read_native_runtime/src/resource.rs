//! Opaque bounded resource registrations. Descriptors remain Runtime-private;
//! streaming response ownership automatically cancels upstream on client drop.
use crate::{
    Runtime,
    catalog::hash,
    error::{Result, invalid, string},
    io::check_url,
};
use axum::{
    body::Body,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use serde_json::Value;
use std::{
    collections::{HashMap, VecDeque},
    sync::Arc,
};

#[derive(Default)]
pub struct Resources {
    entries: HashMap<String, (String, Value)>,
    order: VecDeque<String>,
}
impl Resources {
    pub fn register(
        &mut self,
        runtime: &Runtime,
        plugin: &str,
        descriptor: Value,
    ) -> Result<String> {
        check_url(runtime, string(&descriptor, "url")?)?;
        let encoded = serde_json::to_vec(&descriptor)?;
        if encoded.len() > 16384 {
            return Err(invalid("Resource descriptor is too large"));
        }
        let key = hash(&[runtime.token.as_bytes(), plugin.as_bytes(), &encoded].concat());
        if !self.entries.contains_key(&key) {
            while self.entries.len() >= 4096 {
                if let Some(old) = self.order.pop_front() {
                    self.entries.remove(&old);
                }
            }
            self.order.push_back(key.clone());
            self.entries
                .insert(key.clone(), (plugin.to_string(), descriptor));
        }
        Ok(format!("http://127.0.0.1:{}/resource/{key}", runtime.port))
    }
    pub fn get(&self, key: &str) -> Option<(String, Value)> {
        self.entries.get(key).cloned()
    }
    pub fn remove_plugin(&mut self, id: &str) {
        self.entries.retain(|_, (p, _)| p != id);
        self.order.retain(|k| self.entries.contains_key(k));
    }
}
pub fn resolve(runtime: &Runtime, plugin: &str, value: &mut Value, depth: usize) -> Result<()> {
    if depth > 48 {
        return Err(invalid("Source result is too deeply nested"));
    }
    match value {
        Value::Object(map) if map.len() == 1 && map.contains_key("$resource") => {
            let descriptor = map["$resource"].clone();
            *value = Value::String(
                runtime
                    .resources
                    .lock()
                    .unwrap()
                    .register(runtime, plugin, descriptor)?,
            );
        }
        Value::Object(map) => {
            for v in map.values_mut() {
                resolve(runtime, plugin, v, depth + 1)?;
            }
        }
        Value::Array(items) => {
            for v in items {
                resolve(runtime, plugin, v, depth + 1)?;
            }
        }
        _ => {}
    }
    Ok(())
}
pub async fn serve(
    State(runtime): State<Arc<Runtime>>,
    Path(key): Path<String>,
    headers: HeaderMap,
) -> Response {
    let Some((plugin, descriptor)) = runtime.resources.lock().unwrap().get(&key) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if !runtime
        .catalog
        .lock()
        .unwrap()
        .entry(&plugin)
        .is_ok_and(|e| e.enabled)
    {
        return StatusCode::GONE.into_response();
    }
    let Ok(url) = check_url(&runtime, descriptor["url"].as_str().unwrap_or("")) else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    // v1 is for novel covers. Media ranges/transform pipelines are deliberately
    // rejected rather than accidentally serving an incomplete media contract.
    if headers.contains_key("range") || descriptor.get("resourceTransform").is_some() {
        return StatusCode::NOT_IMPLEMENTED.into_response();
    }
    let client = runtime.client.read().unwrap().clone();
    let mut req = client.get(url);
    if let Some(h) = descriptor["headers"].as_object() {
        for (k, v) in h {
            if let Some(v) = v.as_str() {
                req = req.header(k, v);
            }
        }
    }
    let response = match req.send().await {
        Ok(r) => r,
        Err(_) => return StatusCode::BAD_GATEWAY.into_response(),
    };
    if !response.status().is_success() {
        return StatusCode::from_u16(response.status().as_u16())
            .unwrap_or(StatusCode::BAD_GATEWAY)
            .into_response();
    }
    let mime = response
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/octet-stream")
        .to_string();
    if !mime.starts_with("image/") {
        return StatusCode::UNSUPPORTED_MEDIA_TYPE.into_response();
    }
    let mut out = Response::new(Body::from_stream(response.bytes_stream()));
    if let Ok(v) = mime.parse() {
        out.headers_mut().insert("content-type", v);
    }
    out.headers_mut()
        .insert("cache-control", "private, max-age=300".parse().unwrap());
    out
}
