//! Independent native worker. Owns its private authenticated loopback listener,
//! immutable catalog and lazy plugin initialization. Plugins own source HTTP,
//! caches and resource listeners; management changes retire this whole worker.
#[cfg(target_os = "android")]
mod android;
pub mod catalog;
mod dispatch;
pub mod error;
mod native;
mod transfer;

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
    collections::BTreeMap,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Instant,
};

pub struct Runtime {
    root: PathBuf,
    token: String,
    test_mode: bool,
    started: Instant,
    catalog: Mutex<catalog::Catalog>,
    loaded: Mutex<BTreeMap<String, Arc<NativePlugin>>>,
    initialization_gate: Mutex<()>,
    proxy: Mutex<Option<String>>,
    stopping: AtomicBool,
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
            initialization_gate: Mutex::new(()),
            proxy: Mutex::new(None),
            stopping: AtomicBool::new(false),
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
    fn shutdown(&self) -> Result<()> {
        self.stopping.store(true, Ordering::SeqCst);
        let _gate = self.initialization_gate.lock().unwrap();
        let plugins = self
            .loaded
            .lock()
            .unwrap()
            .values()
            .cloned()
            .collect::<Vec<_>>();
        tokio::runtime::Handle::current().block_on(async {
            let client = reqwest::Client::builder()
                .no_proxy()
                .timeout(std::time::Duration::from_secs(2))
                .build()
                .map_err(|_| invalid("Shutdown client failed"))?;
            let mut jobs = tokio::task::JoinSet::new();
            for plugin in plugins {
                let client = client.clone();
                jobs.spawn(async move { plugin.shutdown(&client).await });
            }
            let mut failed = false;
            while let Some(result) = jobs.join_next().await {
                if !matches!(result, Ok(Ok(()))) {
                    failed = true;
                }
            }
            if failed {
                Err(Error::new(
                    "shutdown_failed",
                    "Plugin did not acknowledge shutdown; worker exit is required",
                ))
            } else {
                Ok(())
            }
        })
    }
}
#[derive(Deserialize)]
struct Rpc {
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
    if !request.params.is_object() {
        return Json(invalid("Invalid control request").envelope()).into_response();
    }
    let result = tokio::task::spawn_blocking(move || {
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            dispatch::control(&runtime, &request.method, &request.params)
        }))
        .unwrap_or_else(|_| Err(Error::new("runtime_error", "Native management call failed")))
    })
    .await
    .unwrap_or_else(|_| Err(Error::new("runtime_error", "Native management task failed")));
    Json(match result {
        Ok(value) => json!({"ok":true,"result":value}),
        Err(e) => e.envelope(),
    })
    .into_response()
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
        .layer(DefaultBodyLimit::max(90 * 1024 * 1024))
        .with_state(runtime);
    ready(json!({"port":port,"token":token,"runtimeKind":"native-rust"}));
    axum::serve(listener, router).await.map_err(Into::into)
}
