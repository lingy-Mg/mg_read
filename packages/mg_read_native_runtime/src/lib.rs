//! Independent native worker. Owns its private authenticated loopback listener,
//! immutable catalog and serialized source calls. Plugins own upstream HTTP,
//! caches and resource listeners; management changes retire this whole worker.
#[cfg(target_os = "android")]
mod android;
pub mod catalog;
mod dispatch;
pub mod error;
mod native;
mod transfer;
mod validation;

use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::post,
};
use error::{Error, Result, invalid};
use native::NativePlugin;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
    time::Instant,
};
use tokio_util::sync::CancellationToken;

pub struct Runtime {
    root: PathBuf,
    token: String,
    test_mode: bool,
    started: Instant,
    catalog: Mutex<catalog::Catalog>,
    loaded: Mutex<BTreeMap<String, Arc<NativePlugin>>>,
    source_gate: Mutex<()>,
    proxy: Mutex<Option<String>>,
    stopping: AtomicBool,
    sequence: AtomicU64,
    jobs: Mutex<HashMap<String, (String, CancellationToken, u64)>>,
    recovered: AtomicUsize,
}
impl Runtime {
    fn open(root: PathBuf, token: String, _port: u16, test_mode: bool) -> Result<Arc<Self>> {
        if token.len() < 32 || token.len() > 256 {
            return Err(invalid("Control token must contain at least 32 characters"));
        }
        let catalog = catalog::Catalog::open(root)?;
        let recovered = catalog.recovered;
        Ok(Arc::new(Self {
            root: catalog.root.clone(),
            token,
            test_mode,
            started: Instant::now(),
            catalog: Mutex::new(catalog),
            loaded: Mutex::new(BTreeMap::new()),
            source_gate: Mutex::new(()),
            proxy: Mutex::new(None),
            stopping: AtomicBool::new(false),
            sequence: AtomicU64::new(0),
            jobs: Mutex::new(HashMap::new()),
            recovered: AtomicUsize::new(recovered),
        }))
    }
    fn authorized(&self, headers: &HeaderMap) -> bool {
        !headers.contains_key("origin")
            && headers
                .get("authorization")
                .and_then(|v| v.to_str().ok())
                .is_some_and(|v| v == format!("Bearer {}", self.token))
    }
    fn cancel_plugin(&self, id: &str) {
        let calls = self
            .jobs
            .lock()
            .unwrap()
            .values()
            .filter(|(plugin, _, _)| plugin == id)
            .cloned()
            .collect::<Vec<_>>();
        for (_, token, call_id) in calls {
            token.cancel();
            if let Some(plugin) = self.loaded.lock().unwrap().get(id) {
                plugin.cancel(call_id);
            }
        }
    }
    fn shutdown(&self) -> Result<()> {
        self.stopping.store(true, Ordering::SeqCst);
        let ids = self
            .loaded
            .lock()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        for id in &ids {
            self.cancel_plugin(id);
        }
        let _gate = self.source_gate.lock().unwrap();
        // An init already holding the gate may have completed during drain.
        let plugins = self
            .loaded
            .lock()
            .unwrap()
            .values()
            .cloned()
            .collect::<Vec<_>>();
        for plugin in plugins {
            plugin.shutdown()?;
        }
        Ok(())
    }
}
#[derive(Deserialize)]
struct Rpc {
    id: String,
    method: String,
    #[serde(default)]
    params: Value,
}
async fn rpc(
    State(runtime): State<Arc<Runtime>>,
    headers: HeaderMap,
    Json(request): Json<Rpc>,
) -> Response {
    if !runtime.authorized(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if request.id.is_empty() || request.id.len() > 160 || !request.params.is_object() {
        return Json(invalid("Invalid control request").envelope()).into_response();
    }
    let cancel = CancellationToken::new();
    let call_id = runtime.sequence.fetch_add(1, Ordering::Relaxed) + 1;
    {
        let mut jobs = runtime.jobs.lock().unwrap();
        if jobs.len() >= 64 || jobs.contains_key(&request.id) {
            return Json(
                Error::new("runtime_busy", "Too many requests or duplicate request ID").envelope(),
            )
            .into_response();
        }
        jobs.insert(
            request.id.clone(),
            (
                request.params["pluginId"].as_str().unwrap_or("").into(),
                cancel.clone(),
                call_id,
            ),
        );
    }
    let rt = runtime.clone();
    let id = request.id.clone();
    let completion = runtime.clone();
    let result = tokio::task::spawn_blocking(move || {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            if request.method.starts_with("source.") {
                dispatch::source(rt, request.method, request.params, cancel, call_id)
            } else {
                dispatch::control(&rt, &request.method, &request.params, cancel, call_id)
            }
        }))
        .unwrap_or_else(|_| Err(Error::new("runtime_error", "Native control call failed")));
        // Completion belongs to the native task, even when the HTTP caller
        // disconnects and drops the response future before the C call returns.
        completion.jobs.lock().unwrap().remove(&id);
        result
    })
    .await
    .unwrap_or_else(|_| Err(Error::new("runtime_error", "Native worker task failed")));
    Json(match result {
        Ok(value) => json!({"ok":true,"result":value,"resourceEndpoints":runtime.loaded.lock().unwrap().values().map(|p|p.endpoint.clone()).collect::<Vec<_>>()}),
        Err(e) => e.envelope(),
    })
    .into_response()
}
async fn cancel(
    State(runtime): State<Arc<Runtime>>,
    headers: HeaderMap,
    Json(value): Json<Value>,
) -> Response {
    if !runtime.authorized(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if let Some(id) = value["id"].as_str() {
        let job = runtime.jobs.lock().unwrap().get(id).cloned();
        if let Some((plugin_id, token, call_id)) = job {
            token.cancel();
            if let Some(plugin) = runtime.loaded.lock().unwrap().get(&plugin_id) {
                plugin.cancel(call_id);
            }
        }
        // A cancellation acknowledgement is distinct from a finished native
        // call. The Supervisor kills a non-cooperating worker after this grace.
        for _ in 0..50 {
            if !runtime.jobs.lock().unwrap().contains_key(id) {
                return Json(json!({"ok":true,"settled":true})).into_response();
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        return Json(json!({"ok":true,"settled":false})).into_response();
    }
    Json(json!({"ok":false,"settled":false})).into_response()
}
pub async fn serve(
    root: PathBuf,
    token: String,
    test_mode: bool,
    ready: impl FnOnce(Value),
) -> Result<()> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    let runtime = Runtime::open(root, token.clone(), port, test_mode)?;
    let router = Router::new()
        .route("/rpc", post(rpc))
        .route("/cancel", post(cancel))
        .layer(DefaultBodyLimit::max(90 * 1024 * 1024))
        .with_state(runtime);
    ready(json!({"port":port,"token":token,"runtimeKind":"native-rust"}));
    axum::serve(listener, router).await.map_err(Into::into)
}
