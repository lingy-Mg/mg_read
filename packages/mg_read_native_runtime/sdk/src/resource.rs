//! Self-contained source-resource URLs, matching Node's reversible Base64URL
//! JSON design. No transient registry, expiry or generation in resource identity.
//! A resource can be rebound to a new plugin port without repeating source calls.
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
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::{Value, json};
use std::sync::Arc;
use tokio_util::sync::CancellationToken;

pub struct Resources {
    pub plugin_id: String,
    pub port: u16,
    client: reqwest::Client,
    stopping: CancellationToken,
    slots: Arc<tokio::sync::Semaphore>,
    test_mode: bool,
}
impl Resources {
    pub fn new(
        plugin_id: String,
        port: u16,
        client: reqwest::Client,
        stopping: CancellationToken,
        test_mode: bool,
    ) -> Arc<Self> {
        Arc::new(Self {
            plugin_id,
            port,
            client,
            stopping,
            slots: Arc::new(tokio::sync::Semaphore::new(16)),
            test_mode,
        })
    }
    pub fn close(&self) {
        self.stopping.cancel();
        self.slots.close();
    }
    pub fn prefix(&self) -> String {
        format!("http://127.0.0.1:{}/v1/source-resource/", self.port)
    }
    fn validate(&self, descriptor: &Value) -> Result<()> {
        http::check_url(
            descriptor["url"]
                .as_str()
                .ok_or_else(|| invalid("Missing resource URL"))?,
            self.test_mode,
        )?;
        http::headers(&descriptor["headers"])?;
        if !["image", "audio", "video", "hls"].contains(&descriptor["kind"].as_str().unwrap_or(""))
            || descriptor.get("resourceTransform").is_some()
        {
            return Err(invalid("Unsupported native resource descriptor"));
        }
        Ok(())
    }
    pub fn register(&self, descriptor: Value) -> Result<String> {
        if self.stopping.is_cancelled() {
            return Err(invalid("Resource service is closed"));
        }
        self.validate(&descriptor)?;
        let token = URL_SAFE_NO_PAD.encode(serde_json::to_vec(
            &json!({"version":1,"engine":"native","pluginId":self.plugin_id,"request":descriptor}),
        )?);
        if token.len() > 24 * 1024 {
            return Err(invalid("Resource descriptor exceeds its limit"));
        }
        Ok(format!("{}{token}", self.prefix()))
    }
    pub fn decode(&self, token: &str) -> Result<Value> {
        if token.len() < 16 || token.len() > 24 * 1024 {
            return Err(invalid("Invalid resource payload"));
        }
        let bytes = URL_SAFE_NO_PAD
            .decode(token)
            .map_err(|_| invalid("Invalid resource payload"))?;
        if URL_SAFE_NO_PAD.encode(&bytes) != token {
            return Err(invalid("Invalid resource encoding"));
        }
        let value: Value = serde_json::from_slice(&bytes)?;
        if value["version"] != 1
            || value["engine"] != "native"
            || value["pluginId"] != self.plugin_id
        {
            return Err(invalid("Resource belongs to another source"));
        }
        self.validate(&value["request"])?;
        Ok(value["request"].clone())
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
    pub fn validate_output(&self, value: &Value) -> Result<()> {
        match value {
            Value::Object(map) => {
                for (key, child) in map {
                    if key == "$resource" {
                        return Err(invalid("Unresolved resource descriptor"));
                    }
                    if let Some(url) = child.as_str() {
                        if key == "coverUrl"
                            || (key == "url"
                                && (map.contains_key("resourcePolicy")
                                    || map.contains_key("resourceType")
                                    || map.contains_key("index")))
                            || url.contains("/v1/source-resource/")
                        {
                            let token = url
                                .strip_prefix(&self.prefix())
                                .ok_or_else(|| invalid("Resource owner or port mismatch"))?;
                            self.decode(token)?;
                        }
                    }
                    self.validate_output(child)?;
                }
            }
            Value::Array(items) => {
                for child in items {
                    self.validate_output(child)?;
                }
            }
            _ => {}
        }
        Ok(())
    }
    pub fn router(self: Arc<Self>) -> Router {
        Router::new()
            .route("/v1/source-resource/{token}", get(serve).head(serve))
            .with_state(self)
    }
}
async fn serve(
    State(resources): State<Arc<Resources>>,
    Path(token): Path<String>,
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
    let Ok(descriptor) = resources.decode(&token) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let response = tokio::select! {
        biased;
        _ = resources.stopping.cancelled() => return StatusCode::GONE.into_response(),
        result = open_resource(resources.clone(), descriptor, method, headers) => result,
    };
    response.unwrap_or_else(|_| StatusCode::BAD_GATEWAY.into_response())
}
async fn open_resource(
    resources: Arc<Resources>,
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
            resources.register(next)
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
            (upstream, permit, resources),
            |(mut response, permit, resources)| async move {
                tokio::select! {
                    biased;
                    _ = resources.stopping.cancelled() => Err(crate::error::cancelled()),
                    chunk = response.chunk() => match chunk {
                        Ok(Some(chunk)) => { Ok(Some((chunk, (response, permit, resources)))) },
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
    use std::{
        sync::atomic::{AtomicUsize, Ordering},
        time::Duration,
    };
    #[test]
    fn resource_payload_survives_another_instance_and_has_no_registry_limit() {
        let first = Resources::new(
            "fixture".into(),
            1234,
            reqwest::Client::new(),
            CancellationToken::new(),
            false,
        );
        let next = Resources::new(
            "fixture".into(),
            2345,
            reqwest::Client::new(),
            CancellationToken::new(),
            false,
        );
        let descriptor = json!({"kind":"image","url":"https://example.test/image"});
        let url = first.register(descriptor.clone()).unwrap();
        let token = url.strip_prefix(&first.prefix()).unwrap();
        first.close();
        assert_eq!(next.decode(token).unwrap(), descriptor);
        for n in 0..5000 {
            next.register(json!({"kind":"image","url":format!("https://example.test/{n}")}))
                .unwrap();
        }
        assert_eq!(next.decode(token).unwrap(), descriptor);
        assert_eq!(
            next.register(descriptor).unwrap(),
            format!("{}{token}", next.prefix())
        );
    }
    #[test]
    fn slow_client_applies_backpressure_and_disconnect_releases_stream_slot() {
        let mut random = [0u8; 16];
        getrandom::fill(&mut random).unwrap();
        let path =
            std::env::temp_dir().join(format!("mgread-stream-{:x}", u128::from_ne_bytes(random)));
        std::fs::create_dir(&path).unwrap();
        let context = crate::Context::open(
            crate::Config {
                plugin_id: "fixture".into(),
                generation: "a".repeat(64),
                source_name: "Fixture".into(),
                control_token: "s".repeat(64),
                capabilities: vec!["search".into()],
                cache_dir: path.clone(),
                upstream_proxy: None,
                test_mode: true,
            },
            crate::tests::echo,
        )
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
        context.shutdown();
        upstream.abort();
        drop(context);
        std::fs::remove_dir_all(path).unwrap();
    }
}
