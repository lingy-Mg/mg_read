//! Statically linked HTTP source SDK. The single worker calls init once per DLL;
//! content and resources then use independent HTTP requests on one loopback port.
//! Source handlers are async. Dropping a disconnected request drops its upstream
//! work; shared cache mutations stay protected. No per-call ABI or RPC cancel map.
pub mod cache;
pub mod error;
mod hls;
mod http;
mod resource;
mod server;
mod validation;

use axum::{
    Extension, Json, Router,
    extract::{DefaultBodyLimit, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::post,
};
use error::{Error, Result, invalid};
use futures_util::{FutureExt, future::BoxFuture};
use mgread_native_abi::{InitResult, MAX_MESSAGE};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio_util::sync::CancellationToken;

pub type SourceFuture = BoxFuture<'static, Result<Value>>;
pub type Handler = fn(Call, Value) -> SourceFuture;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    plugin_id: String,
    source_name: String,
    generation: String,
    control_token: String,
    cache_dir: PathBuf,
    upstream_proxy: Option<String>,
    capabilities: Vec<String>,
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
    config: Config,
    handler: Handler,
}
pub struct Call {
    context: Arc<Context>,
    cancel: CancellationToken,
    started: Instant,
}
impl Call {
    pub fn cancelled(&self) -> bool {
        self.cancel.is_cancelled()
            || self.context.stop.is_cancelled()
            || self.started.elapsed() > Duration::from_secs(90)
    }
    pub fn cache(&self) -> &cache::Cache {
        &self.context.cache
    }
    pub async fn http(&self, request: &Value) -> Result<Value> {
        if self.cancelled() {
            return Err(error::cancelled());
        }
        let url = http::check_url(
            request["url"]
                .as_str()
                .ok_or_else(|| invalid("Missing URL"))?,
            self.context.config.test_mode,
        )?;
        let headers = http::headers(&request["headers"])?;
        let operation = async {
            let response = http::open(
                &self.context.client,
                reqwest::Method::GET,
                url,
                headers,
                self.context.config.test_mode,
            )
            .await?;
            let status = response.status().as_u16();
            if !response.status().is_success() {
                return Err(Error::new(
                    "source_http_error",
                    &format!("Upstream HTTP {status}"),
                ));
            }
            let body = String::from_utf8(http::bounded_body(response, 4 * 1024 * 1024).await?)
                .map_err(|_| invalid("Source text is not UTF-8"))?;
            Ok(json!({"body":body,"status":status,"headers":{}}))
        };
        tokio::select! { biased;
            _ = self.cancel.cancelled() => Err(error::cancelled()),
            _ = self.context.stop.cancelled() => Err(error::cancelled()),
            result = tokio::time::timeout(Duration::from_secs(20), operation) => result.map_err(|_| Error::new("runtime_timeout", "Source HTTP timed out"))?,
        }
    }
}
impl Context {
    fn open(config: Config, handler: Handler) -> Result<Arc<Self>> {
        if !component(&config.plugin_id)
            || config.generation.len() != 64
            || config.control_token.len() < 32
            || config.capabilities.is_empty()
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
            config.plugin_id.clone(),
            port,
            client.clone(),
            stop.clone(),
            config.test_mode,
        );
        let context = Arc::new(Self {
            cache,
            executor,
            client,
            resources,
            stop,
            server: Mutex::new(None),
            config,
            handler,
        });
        let router = Router::new()
            .route("/invoke", post(invoke))
            .route("/shutdown", post(shutdown))
            .layer(DefaultBodyLimit::max(MAX_MESSAGE))
            .with_state(context.clone())
            .merge(context.resources.clone().router());
        let server = context
            .executor
            .spawn(server::serve(listener, router, context.stop.clone()));
        *context.server.lock().unwrap() = Some(server);
        Ok(context)
    }
    async fn invoke(self: &Arc<Self>, input: Value, cancel: CancellationToken) -> Result<Value> {
        if self.stop.is_cancelled() {
            return Err(Error::new("plugin_closed", "Source is closed"));
        }
        let raw_method = input["method"]
            .as_str()
            .ok_or_else(|| invalid("Missing source method"))?;
        let method = raw_method
            .strip_prefix("source.")
            .and_then(|v| v.strip_suffix(".v1"))
            .unwrap_or(raw_method);
        if !self.config.capabilities.iter().any(|v| v == method) {
            return Err(Error::new(
                "unsupported",
                "Source capability is not declared",
            ));
        }
        let mut request = input["params"].clone();
        let params = request
            .as_object_mut()
            .ok_or_else(|| invalid("Invalid source request"))?;
        if params
            .remove("pluginId")
            .is_some_and(|v| v != self.config.plugin_id)
        {
            return Err(invalid("Wrong source owner"));
        }
        if !params.contains_key("id") {
            if let Some(id) = params.remove("contentId") {
                params.insert("id".into(), id);
            }
        }
        if ["discover", "search", "searchSuggestions"].contains(&method) {
            params.entry("pageSize").or_insert(json!(20));
            params.entry("cursor").or_insert(Value::Null);
        }
        if method == "discover" {
            params.entry("target").or_insert(Value::Null);
            params.entry("collectionId").or_insert(Value::Null);
        }
        let call = Call {
            context: self.clone(),
            cancel: cancel.clone(),
            started: Instant::now(),
        };
        let operation = std::panic::AssertUnwindSafe((self.handler)(
            call,
            json!({"method":method,"request":request}),
        ))
        .catch_unwind();
        let mut value = tokio::select! { biased;
            _ = cancel.cancelled() => return Err(error::cancelled()),
            _ = self.stop.cancelled() => return Err(error::cancelled()),
            result = tokio::time::timeout(Duration::from_secs(90), operation) => result.map_err(|_| Error::new("timeout", "Source HTTP call timed out"))?.map_err(|_| Error::new("native_panic", "Source handler failed"))??,
        };
        self.resources.project(&mut value, 0)?;
        validation::validate(method, &request, &value)?;
        self.resources.validate_output(&value)?;
        let result = value
            .as_object_mut()
            .ok_or_else(|| invalid("Invalid source result"))?;
        result.insert("pluginId".into(), json!(self.config.plugin_id));
        result.insert("sourceName".into(), json!(self.config.source_name));
        if method == "getChapters" {
            result.entry("groups").or_insert(json!([]));
        }
        Ok(value)
    }
    fn authorized(&self, headers: &HeaderMap) -> bool {
        !headers.contains_key("origin")
            && headers.get("host").and_then(|v| v.to_str().ok())
                == Some(&format!("127.0.0.1:{}", self.resources.port))
            && headers.get("authorization").and_then(|v| v.to_str().ok())
                == Some(&format!("Bearer {}", self.config.control_token))
    }
    fn stop(&self) {
        self.resources.close();
    }
    #[cfg(test)]
    fn shutdown(&self) {
        self.stop();
        if let Some(job) = self.server.lock().unwrap().take() {
            let _ = self.executor.block_on(job);
        }
    }
}
async fn invoke(
    State(context): State<Arc<Context>>,
    Extension(cancel): Extension<CancellationToken>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    if !context.authorized(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let result = match context.invoke(input, cancel).await {
        Ok(value) => json!({"ok":true,"result":value}),
        Err(error) => error.envelope(),
    };
    let mut response = Json(result).into_response();
    // A call owns its HTTP connection, so closing it cancels only this request.
    response
        .headers_mut()
        .insert("connection", "close".parse().unwrap());
    response
}
async fn shutdown(State(context): State<Arc<Context>>, headers: HeaderMap) -> Response {
    if !context.authorized(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(30)).await;
        context.stop();
    });
    Json(json!({"ok":true,"result":{"stopping":true}})).into_response()
}
fn component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b".-".contains(&b))
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
    /// JSON input is borrowed for this call only. Nothing is allocated for the host.
    pub unsafe fn init(&self, input: *const u8, length: usize, handler: Handler) -> InitResult {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<u16> {
            let mut slot = self.context.lock().unwrap();
            if slot.is_some() || input.is_null() || length == 0 || length > MAX_MESSAGE {
                return Err(invalid("Invalid initialization"));
            }
            let config: Config =
                serde_json::from_slice(unsafe { std::slice::from_raw_parts(input, length) })?;
            if config.plugin_id != self.plugin_id {
                return Err(invalid("Plugin identity mismatch"));
            }
            let context = Context::open(config, handler)?;
            let port = context.resources.port;
            *slot = Some(context);
            Ok(port)
        }));
        match result {
            Ok(Ok(port)) => InitResult::ready(port),
            _ => InitResult::failed(),
        }
    }
}
#[cfg(test)]
mod tests;
