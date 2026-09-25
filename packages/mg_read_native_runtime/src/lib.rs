//! Independent native worker. Owns its private authenticated loopback listener,
//! immutable catalog, source libraries, network/storage and resource lifetimes.
#[cfg(target_os = "android")]
mod android;
pub mod catalog;
mod dispatch;
pub mod error;
mod io;
mod native;
mod resource;
mod transfer;
mod validation;

use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use error::{Error, Result, invalid};
use native::NativePlugin;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    sync::{
        Arc, Mutex, RwLock,
        atomic::{AtomicU64, AtomicUsize},
    },
    time::Instant,
};
use tokio_util::sync::CancellationToken;

pub struct Runtime {
    root: PathBuf,
    token: String,
    port: u16,
    test_mode: bool,
    started: Instant,
    catalog: Mutex<catalog::Catalog>,
    loaded: Mutex<BTreeMap<String, Arc<NativePlugin>>>,
    client: RwLock<reqwest::Client>,
    storage_lock: Mutex<()>,
    resources: Mutex<resource::Resources>,
    handle: tokio::runtime::Handle,
    http_slots: tokio::sync::Semaphore,
    jobs: Mutex<HashMap<String, (String, CancellationToken)>>,
    http_requests: AtomicU64,
    recovered: AtomicUsize,
}
impl Runtime {
    fn open(root: PathBuf, token: String, port: u16, test_mode: bool) -> Result<Arc<Self>> {
        if token.len() < 32 || token.len() > 256 {
            return Err(invalid("Control token must contain at least 32 characters"));
        }
        let mut catalog = catalog::Catalog::open(root)?;
        let mut loaded = BTreeMap::new();
        let mut recovered = 0;
        let ids = catalog.entries.keys().cloned().collect::<Vec<_>>();
        for id in ids {
            if let Some(pending) = catalog.entries[&id].pending.clone() {
                // Persist the last confirmed version before entering foreign
                // code. An abort during activation must not repeat that load
                // forever on the next worker start.
                catalog.entries.get_mut(&id).unwrap().pending = None;
                catalog.save()?;
                match catalog
                    .library(&pending)
                    .and_then(|p| NativePlugin::load(&p, &pending))
                {
                    Ok(plugin) => {
                        let e = catalog.entries.get_mut(&id).unwrap();
                        e.manifest = pending;
                        e.pending = None;
                        loaded.insert(id, Arc::new(plugin));
                    }
                    Err(_) => {
                        catalog.entries.get_mut(&id).unwrap().pending = None;
                        recovered += 1;
                    }
                }
            }
        }
        catalog.save()?;
        Ok(Arc::new(Self {
            root: catalog.root.clone(),
            token,
            port,
            test_mode,
            started: Instant::now(),
            catalog: Mutex::new(catalog),
            loaded: Mutex::new(loaded),
            client: RwLock::new(io::http_client(None)?),
            storage_lock: Mutex::new(()),
            resources: Mutex::new(resource::Resources::default()),
            handle: tokio::runtime::Handle::current(),
            http_slots: tokio::sync::Semaphore::new(16),
            jobs: Mutex::new(HashMap::new()),
            http_requests: AtomicU64::new(0),
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
        for (plugin, token) in self.jobs.lock().unwrap().values() {
            if plugin == id {
                token.cancel();
            }
        }
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
            ),
        );
    }
    let rt = runtime.clone();
    let id = request.id.clone();
    let completion = runtime.clone();
    let result = tokio::task::spawn_blocking(move || {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            if request.method.starts_with("source.") {
                dispatch::source(rt, request.method, request.params, cancel)
            } else {
                dispatch::control(&rt, &request.method, &request.params, cancel)
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
        Ok(value) => json!({"ok":true,"result":value}),
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
        {
            if let Some((_, token)) = runtime.jobs.lock().unwrap().get(id) {
                token.cancel();
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
        .route("/resource/{key}", get(resource::serve))
        .layer(DefaultBodyLimit::max(90 * 1024 * 1024))
        .with_state(runtime);
    ready(json!({"port":port,"token":token,"runtimeKind":"native-rust"}));
    axum::serve(listener, router).await.map_err(Into::into)
}
