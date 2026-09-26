//! Plugin-owned HTTP data plane. URLs contain only plugin identity, generation
//! and random capabilities; upstream descriptors never leave this library.
//! Streaming owns its semaphore permit and upstream response until client drop.
use crate::{
    error::{Result, invalid},
    http,
};
use axum::{
    Router,
    body::Body,
    extract::{Path, State},
    http::{HeaderMap, Method, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio_util::sync::CancellationToken;

const IDLE_TTL: Duration = Duration::from_secs(30 * 60);
struct Entry {
    descriptor: Value,
    touched: Instant,
    // HLS descendants share the root playlist activity window.
    family: Option<String>,
}
pub struct Resources {
    pub plugin_id: String,
    pub generation: String,
    pub port: u16,
    entries: Mutex<HashMap<String, Entry>>,
    client: reqwest::Client,
    stopping: CancellationToken,
    slots: Arc<tokio::sync::Semaphore>,
    test_mode: bool,
}
impl Resources {
    pub fn new(
        plugin_id: String,
        generation: String,
        port: u16,
        client: reqwest::Client,
        stopping: CancellationToken,
        test_mode: bool,
    ) -> Arc<Self> {
        Arc::new(Self {
            plugin_id,
            generation,
            port,
            entries: Mutex::new(HashMap::new()),
            client,
            stopping,
            slots: Arc::new(tokio::sync::Semaphore::new(16)),
            test_mode,
        })
    }
    pub fn close(&self) {
        self.stopping.cancel();
        self.slots.close();
        self.entries.lock().unwrap().clear();
    }
    pub fn endpoint(&self) -> Value {
        json!({"pluginId":self.plugin_id,"generation":self.generation,"port":self.port})
    }
    pub fn prefix(&self) -> String {
        format!(
            "http://127.0.0.1:{}/v2/source-resource/native/{}/{}/",
            self.port, self.plugin_id, self.generation
        )
    }
    pub fn register(&self, descriptor: Value) -> Result<String> {
        self.register_in_family(descriptor, None)
    }
    fn register_in_family(&self, descriptor: Value, family: Option<String>) -> Result<String> {
        if self.stopping.is_cancelled() {
            return Err(invalid("Resource service is closed"));
        }
        let url = descriptor["url"]
            .as_str()
            .ok_or_else(|| invalid("Missing resource URL"))?;
        http::check_url(url, self.test_mode)?;
        http::headers(&descriptor["headers"])?;
        if !["image", "audio", "video", "hls"].contains(&descriptor["kind"].as_str().unwrap_or(""))
            || descriptor.get("resourceTransform").is_some()
        {
            return Err(invalid("Unsupported native resource descriptor"));
        }
        if serde_json::to_vec(&descriptor)?.len() > 16384 {
            return Err(invalid("Resource descriptor exceeds its limit"));
        }
        let mut entries = self.entries.lock().unwrap();
        let active_roots = entries
            .iter()
            .filter(|(_, e)| e.family.is_none() && e.touched.elapsed() < IDLE_TTL)
            .map(|(id, _)| id.clone())
            .collect::<HashSet<_>>();
        entries.retain(|_, entry| {
            entry.touched.elapsed() < IDLE_TTL
                || entry
                    .family
                    .as_ref()
                    .is_some_and(|root| active_roots.contains(root))
        });
        if let Some((key, entry)) = entries
            .iter_mut()
            .find(|(_, e)| e.descriptor == descriptor && e.family == family)
        {
            entry.touched = Instant::now();
            return Ok(format!("{}{key}", self.prefix()));
        }
        if entries.len() >= 4096 {
            return Err(invalid("Too many active source resources"));
        }
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes).map_err(|_| invalid("Resource token creation failed"))?;
        let token = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
        entries.insert(
            token.clone(),
            Entry {
                descriptor,
                touched: Instant::now(),
                family,
            },
        );
        Ok(format!("{}{token}", self.prefix()))
    }
    pub fn project(&self, value: &mut Value, depth: usize) -> Result<()> {
        if depth > 48 {
            return Err(invalid("Source result is too deeply nested"));
        }
        match value {
            Value::Object(o) if o.len() == 1 && o.contains_key("$resource") => {
                *value = json!(self.register(o["$resource"].clone())?)
            }
            Value::Object(o) => {
                for value in o.values_mut() {
                    self.project(value, depth + 1)?;
                }
            }
            Value::Array(a) => {
                for value in a {
                    self.project(value, depth + 1)?;
                }
            }
            _ => {}
        }
        Ok(())
    }
    pub fn inspect(&self, url: &str) -> Result<Value> {
        let token = url
            .strip_prefix(&self.prefix())
            .ok_or_else(|| invalid("Resource belongs to another plugin instance"))?;
        let (descriptor, _) = self
            .lookup(token)
            .ok_or_else(|| invalid("Resource expired"))?;
        Ok(
            json!({"pluginId":self.plugin_id,"request":{"engine":"native","kind":descriptor["kind"],"generation":self.generation}}),
        )
    }
    fn lookup(&self, token: &str) -> Option<(Value, String)> {
        let mut entries = self.entries.lock().unwrap();
        let entry = entries.get(token)?;
        let family = entry.family.as_deref().unwrap_or(token).to_string();
        let family_active = entries
            .get(&family)
            .is_some_and(|e| e.touched.elapsed() < IDLE_TTL);
        if entry.touched.elapsed() >= IDLE_TTL && !family_active {
            entries.remove(token);
            return None;
        }
        let descriptor = entry.descriptor.clone();
        entries.get_mut(token)?.touched = Instant::now();
        if let Some(root) = entries.get_mut(&family) {
            root.touched = Instant::now();
        }
        Some((descriptor, family))
    }
    fn touch_stream(&self, token: &str) {
        let mut entries = self.entries.lock().unwrap();
        if let Some(entry) = entries.get_mut(token) {
            entry.touched = Instant::now();
            let family = entry.family.clone();
            if let Some(root) = family.and_then(|id| entries.get_mut(&id)) {
                root.touched = Instant::now();
            }
        }
    }
    pub fn router(self: Arc<Self>) -> Router {
        Router::new()
            .route(
                "/v2/source-resource/native/{plugin}/{generation}/{token}",
                get(serve).head(serve),
            )
            .with_state(self)
    }
}
async fn serve(
    State(resources): State<Arc<Resources>>,
    Path((plugin, generation, token)): Path<(String, String, String)>,
    method: Method,
    headers: HeaderMap,
) -> Response {
    let authority = format!("127.0.0.1:{}", resources.port);
    if headers.contains_key("origin")
        || headers.get("host").and_then(|v| v.to_str().ok()) != Some(&authority)
    {
        return StatusCode::FORBIDDEN.into_response();
    }
    if resources.stopping.is_cancelled() {
        return StatusCode::GONE.into_response();
    }
    if plugin != resources.plugin_id || generation != resources.generation {
        return StatusCode::NOT_FOUND.into_response();
    }
    let Some((descriptor, family)) = resources.lookup(&token) else {
        return StatusCode::GONE.into_response();
    };
    let response = tokio::select! {
        biased;
        _ = resources.stopping.cancelled() => return StatusCode::GONE.into_response(),
        result = open_resource(resources.clone(), token, family, descriptor, method, headers) => result,
    };
    response.unwrap_or_else(|_| StatusCode::BAD_GATEWAY.into_response())
}
async fn open_resource(
    resources: Arc<Resources>,
    token: String,
    family: String,
    descriptor: Value,
    method: Method,
    headers: HeaderMap,
) -> Result<Response> {
    let permit = resources
        .slots
        .clone()
        .acquire_owned()
        .await
        .map_err(|_| invalid("Resource server closed"))?;
    let playlist = descriptor["kind"] == "hls";
    let mut forwarded = http::headers(&descriptor["headers"])?;
    forwarded.insert("accept-encoding", "identity".parse().unwrap());
    if !playlist && descriptor["resourceRole"] != "hlsKey" {
        for name in ["range", "if-range"] {
            if let Some(value) = headers.get(name).filter(|v| v.as_bytes().len() <= 512) {
                forwarded.insert(name, value.clone());
            }
        }
    }
    let url = http::check_url(descriptor["url"].as_str().unwrap(), resources.test_mode)?;
    let upstream_method = if playlist {
        Method::GET
    } else {
        method.clone()
    };
    let upstream = http::open(
        &resources.client,
        upstream_method,
        url,
        forwarded,
        resources.test_mode,
    )
    .await?;
    let status = upstream.status();
    if playlist && status.is_success() {
        let base = upstream.url().clone();
        let bytes = http::bounded_body(upstream, 1024 * 1024).await?;
        let text = std::str::from_utf8(&bytes).map_err(|_| invalid("Invalid HLS text"))?;
        let body = crate::hls::rewrite(text, &base, |uri, kind, role| {
            let mut next = descriptor.clone();
            // Do not forward original-origin authentication to an HLS CDN.
            if reqwest::Url::parse(uri).ok().map(|u| u.origin())
                != reqwest::Url::parse(descriptor["url"].as_str().unwrap())
                    .ok()
                    .map(|u| u.origin())
            {
                if let Some(headers) = next["headers"].as_object_mut() {
                    headers.retain(|name, _| {
                        !["authorization", "cookie", "proxy-authorization"]
                            .contains(&name.to_lowercase().as_str())
                    });
                }
            }
            next["url"] = json!(uri);
            next["kind"] = json!(kind);
            next["resourceRole"] = json!(role);
            resources.register_in_family(next, Some(family.clone()))
        })?;
        let length = body.len();
        let mut response = Response::new(if method == Method::HEAD {
            Body::empty()
        } else {
            Body::from(body)
        });
        response.headers_mut().insert(
            "content-type",
            "application/vnd.apple.mpegurl; charset=utf-8"
                .parse()
                .unwrap(),
        );
        response
            .headers_mut()
            .insert("content-length", length.into());
        response
            .headers_mut()
            .insert("cache-control", "no-store".parse().unwrap());
        return Ok(response);
    }
    let mut selected = HeaderMap::new();
    for name in [
        "accept-ranges",
        "content-length",
        "content-range",
        "content-type",
        "content-encoding",
        "etag",
        "last-modified",
    ] {
        if let Some(value) = upstream.headers().get(name) {
            selected.insert(name, value.clone());
        }
    }
    selected.insert("cache-control", "no-store".parse().unwrap());
    if descriptor["kind"] == "image"
        && status.is_success()
        && !selected
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.starts_with("image/"))
    {
        return Err(invalid("Upstream did not return an image"));
    }
    let body = if method == Method::HEAD {
        Body::empty()
    } else {
        let stream = futures_util::stream::try_unfold(
            (upstream, permit, resources, token),
            |(mut response, permit, resources, token)| async move {
                tokio::select! {
                    biased;
                    _ = resources.stopping.cancelled() => Err(crate::error::cancelled()),
                    chunk = response.chunk() => match chunk {
                        Ok(Some(chunk)) => { resources.touch_stream(&token); Ok(Some((chunk, (response, permit, resources, token)))) },
                        Ok(None) => Ok(None),
                        Err(_) => Err(invalid("Resource upstream stream failed")),
                    }
                }
            },
        );
        Body::from_stream(stream)
    };
    let mut response = Response::new(body);
    *response.status_mut() = status;
    *response.headers_mut() = selected;
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn tokens_expire_and_shutdown_discards_descriptors() {
        let resources = Resources::new(
            "fixture".into(),
            "a".repeat(64),
            1234,
            reqwest::Client::new(),
            CancellationToken::new(),
            false,
        );
        let descriptor = json!({"kind":"image","url":"https://example.test/image"});
        let url = resources.register(descriptor.clone()).unwrap();
        let token = url.strip_prefix(&resources.prefix()).unwrap();
        resources
            .entries
            .lock()
            .unwrap()
            .get_mut(token)
            .unwrap()
            .touched = Instant::now() - IDLE_TTL;
        assert!(resources.inspect(&url).is_err());
        assert_ne!(url, resources.register(descriptor.clone()).unwrap());
        resources.close();
        assert!(resources.entries.lock().unwrap().is_empty());
        assert!(resources.register(descriptor).is_err());
    }

    #[test]
    fn hls_children_remain_valid_while_the_root_playback_is_active() {
        let resources = Resources::new(
            "fixture".into(),
            "a".repeat(64),
            1234,
            reqwest::Client::new(),
            CancellationToken::new(),
            false,
        );
        let root_url = resources
            .register(json!({"kind":"hls","url":"https://example.test/master"}))
            .unwrap();
        let root = root_url
            .strip_prefix(&resources.prefix())
            .unwrap()
            .to_string();
        let child_url = resources
            .register_in_family(
                json!({"kind":"video","url":"https://example.test/late-segment"}),
                Some(root.clone()),
            )
            .unwrap();
        let child = child_url
            .strip_prefix(&resources.prefix())
            .unwrap()
            .to_string();
        resources
            .entries
            .lock()
            .unwrap()
            .get_mut(&child)
            .unwrap()
            .touched = Instant::now() - IDLE_TTL;
        resources
            .register(json!({"kind":"image","url":"https://example.test/another"}))
            .unwrap();
        assert!(
            resources.lookup(&child).is_some(),
            "Future HLS segments share the active root lease"
        );
        for entry in resources.entries.lock().unwrap().values_mut() {
            entry.touched = Instant::now() - IDLE_TTL;
        }
        assert!(resources.lookup(&child).is_none());
        assert!(resources.lookup(&root).is_none());
    }

    #[test]
    fn slow_client_applies_backpressure_and_disconnect_releases_stream_slot() {
        let mut random = [0u8; 16];
        getrandom::fill(&mut random).unwrap();
        let path =
            std::env::temp_dir().join(format!("mgread-stream-{:x}", u128::from_ne_bytes(random)));
        std::fs::create_dir(&path).unwrap();
        let context = crate::Context::open(crate::Config {
            plugin_id: "fixture".into(),
            generation: "a".repeat(64),
            cache_dir: path.clone(),
            upstream_proxy: None,
            test_mode: true,
        })
        .unwrap();
        let count = Arc::new(AtomicUsize::new(0));
        let upstream_count = count.clone();
        let listener = context
            .executor
            .block_on(tokio::net::TcpListener::bind("127.0.0.1:0"))
            .unwrap();
        let upstream_url = format!("http://{}/stream", listener.local_addr().unwrap());
        let upstream = context.executor.spawn(async move {
            let router = Router::new().route(
                "/stream",
                get(move || {
                    let count = upstream_count.clone();
                    async move {
                        let stream =
                            futures_util::stream::unfold((0, count), |(index, count)| async move {
                                if index == 4096 {
                                    return None;
                                }
                                count.fetch_add(1, Ordering::SeqCst);
                                Some((
                                    Ok::<_, std::io::Error>(vec![0u8; 64 * 1024]),
                                    (index + 1, count),
                                ))
                            });
                        Body::from_stream(stream)
                    }
                }),
            );
            axum::serve(listener, router).await.unwrap();
        });
        let url = context
            .resources
            .register(json!({"kind":"video","url":upstream_url}))
            .unwrap();
        context.executor.block_on(async {
            let client = reqwest::Client::builder().no_proxy().build().unwrap();
            let response = client
                .get(url)
                .header("connection", "close")
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), 200);
            tokio::time::sleep(Duration::from_millis(100)).await;
            assert!(
                count.load(Ordering::SeqCst) < 4096,
                "The proxy must not buffer the entire upstream body"
            );
            assert_eq!(context.resources.slots.available_permits(), 15);
            drop(response);
            for _ in 0..200 {
                if context.resources.slots.available_permits() == 16 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            assert_eq!(context.resources.slots.available_permits(), 16);
        });
        context.shutdown().unwrap();
        upstream.abort();
        drop(context);
        std::fs::remove_dir_all(path).unwrap();
    }
}
