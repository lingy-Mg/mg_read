//! Versioned Facade operations. Installation and library lifetime are independent
//! of Node; source result semantics remain compatible with typed Flutter decoders.
use crate::{
    Runtime, catalog,
    error::{Error, Result, invalid, string},
    io::{CallContext, http_client},
    native::NativePlugin,
    resource,
};
use base64::Engine;
use serde_json::{Value, json};
use std::{
    sync::{Arc, atomic::AtomicUsize},
    time::Instant,
};
use tokio_util::sync::CancellationToken;

pub fn control(
    runtime: &Arc<Runtime>,
    method: &str,
    params: &Value,
    cancel: CancellationToken,
) -> Result<Value> {
    match method {
        "runtime.ping" => Ok(
            json!({"ok":true,"nodeVersion":"","runtimeVersion":"native-0.1.0","runtimeKind":"native-rust"}),
        ),
        "runtime.status.v1" => Ok(
            json!({"ok":true,"nodeVersion":"","runtimeVersion":"native-0.1.0","runtimeKind":"native-rust",
            "platform":std::env::consts::OS,"arch":std::env::consts::ARCH,"uptimeMs":runtime.started.elapsed().as_millis() as u64,
            "plugins":runtime.catalog.lock().unwrap().list(),"memory":{"rss":rss(),"arrayBuffers":0,"external":0,"heapTotal":0,"heapUsed":0},
            "native":{"httpRequests":runtime.http_requests.load(std::sync::atomic::Ordering::Relaxed),"inflight":runtime.jobs.lock().unwrap().len()}}),
        ),
        "plugins.list.v1" => Ok(runtime.catalog.lock().unwrap().list()),
        "plugins.recovery.consume.v1" => Ok(
            json!({"quarantinedCount":runtime.recovered.swap(0,std::sync::atomic::Ordering::Relaxed)}),
        ),
        "plugins.native.import.v1" | "plugins.native.importBytes.v1" => {
            let bytes = if method.ends_with("importBytes.v1") {
                base64::engine::general_purpose::STANDARD
                    .decode(string(params, "base64")?)
                    .map_err(|_| invalid("Invalid archive encoding"))?
            } else {
                let path = std::path::Path::new(string(params, "path")?);
                if std::fs::metadata(path)?.len() > catalog::MAX_ARCHIVE as u64 {
                    return Err(invalid("Archive is too large"));
                }
                std::fs::read(path)?
            };
            let expected = if params.get("expectedPluginId").is_some()
                || params.get("expectedVersion").is_some()
            {
                Some((
                    string(params, "expectedPluginId")?,
                    string(params, "expectedVersion")?,
                ))
            } else {
                None
            };
            let m = runtime.catalog.lock().unwrap().install(&bytes, expected)?;
            Ok(json!({"pluginId":m.id,"version":m.version,"restartRequired":true}))
        }
        "runtime.native.proxy.v1" => {
            let proxy = params["url"].as_str();
            let client = http_client(proxy)?;
            *runtime.client.write().unwrap() = client;
            Ok(json!({"configured":proxy.is_some()}))
        }
        "plugins.setEnabled.v1" => {
            let id = string(params, "pluginId")?;
            let enabled = params["enabled"]
                .as_bool()
                .ok_or_else(|| invalid("Missing enabled flag"))?;
            let mut c = runtime.catalog.lock().unwrap();
            c.entry(id)?;
            c.entries.get_mut(id).unwrap().enabled = enabled;
            c.save()?;
            if !enabled {
                runtime.resources.lock().unwrap().remove_plugin(id);
                runtime.cancel_plugin(id);
            }
            Ok(c.projection(&c.entries[id]))
        }
        "plugins.uninstall.v1" | "plugins.uninstallAll.v1" => {
            let mut c = runtime.catalog.lock().unwrap();
            let ids = if method == "plugins.uninstall.v1" {
                let id = string(params, "pluginId")?;
                c.entry(id)?;
                vec![id.to_string()]
            } else {
                c.entries.keys().cloned().collect()
            };
            for id in &ids {
                c.entries.get_mut(id).unwrap().removing = true;
                runtime.resources.lock().unwrap().remove_plugin(id);
                runtime.cancel_plugin(id);
            }
            c.save()?;
            Ok(if method == "plugins.uninstall.v1" {
                json!({"pluginId":ids[0],"removed":true})
            } else {
                json!({"removedCount":ids.len()})
            })
        }
        "plugins.installation.usage.v1" => {
            let c = runtime.catalog.lock().unwrap();
            let id = string(params, "pluginId")?;
            let e = c.entry(id)?;
            let scope = string(params, "scope")?;
            let path = match scope {
                "archive" => c
                    .versions(id)
                    .join(&e.manifest.version)
                    .join("source.mgplugin"),
                "data" => c.root.join("plugins").join(id).join("data"),
                _ => return Err(invalid("Invalid usage scope")),
            };
            let (bytes, count) = catalog::usage(&path)?;
            Ok(
                json!({"pluginId":id,"version":e.manifest.version,"scope":scope,"bytes":bytes,"fileCount":count}),
            )
        }
        "plugins.cache.usage.v1" | "plugins.cache.clear.v1" | "plugins.cache.clearAll.v1" => {
            let _guard = runtime.storage_lock.lock().unwrap();
            let c = runtime.catalog.lock().unwrap();
            let ids = if let Some(id) = params["pluginId"].as_str() {
                c.entry(id)?;
                vec![id.to_string()]
            } else {
                c.entries.keys().cloned().collect()
            };
            let mut items = Vec::new();
            for id in ids {
                let path = c.root.join("plugins").join(&id).join("cache");
                let before = catalog::usage(&path)?.0;
                if method == "plugins.cache.usage.v1" {
                    items.push(json!({"pluginId":id,"bytes":before}));
                } else {
                    if path.exists() {
                        std::fs::remove_dir_all(path)?;
                    }
                    items.push(json!({"pluginId":id,"bytesBefore":before,"bytesRemaining":0,"status":"cleared"}));
                }
            }
            Ok(if method == "plugins.cache.usage.v1" {
                json!(items)
            } else {
                json!({"items":items})
            })
        }
        "runtime.sourceResource.decode.v1" => {
            let url = string(params, "url")?;
            let key = url.rsplit('/').next().unwrap_or("");
            let (id, value) = runtime
                .resources
                .lock()
                .unwrap()
                .get(key)
                .ok_or_else(|| invalid("Unknown resource"))?;
            Ok(json!({"pluginId":id,"request":value}))
        }
        "plugins.transfer.plan.v2" | "plugins.transfer.offers.plan.v1" => {
            crate::transfer::plan(&runtime.catalog.lock().unwrap(), params)
        }
        "plugins.transfer.list.v2" | "plugins.transfer.offers.v1" => {
            let c = runtime.catalog.lock().unwrap();
            let mut items = Vec::new();
            for e in c.entries.values().filter(|e| !e.removing) {
                let m = &e.manifest;
                let bytes =
                    std::fs::read(c.versions(&m.id).join(&m.version).join("source.mgplugin"))?;
                items.push(json!({"id":m.id,"version":m.version,"format":"archive","provenance":"installed","developmentFingerprint":null,"developmentRevision":null,"bytes":bytes.len(),"checksum":catalog::transfer_checksum(&bytes)}));
            }
            Ok(json!(items))
        }
        "plugins.native.export.v1" => {
            let c = runtime.catalog.lock().unwrap();
            let e = c.entry(string(params, "pluginId")?)?;
            let m = &e.manifest;
            let bytes = std::fs::read(c.versions(&m.id).join(&m.version).join("source.mgplugin"))?;
            Ok(
                json!({"base64":base64::engine::general_purpose::STANDARD.encode(&bytes),"checksum":catalog::transfer_checksum(&bytes),"bytes":bytes.len(),"version":m.version}),
            )
        }
        "runtime.native.shutdown.v1" => {
            std::thread::spawn(|| {
                std::thread::sleep(std::time::Duration::from_millis(250));
                std::process::exit(0);
            });
            Ok(json!({"stopping":true}))
        }
        "runtime.native.fault.v1" if runtime.test_mode => std::process::abort(),
        "runtime.native.probe.v1" if runtime.test_mode => {
            let id = string(params, "pluginId")?;
            runtime.catalog.lock().unwrap().entry(id)?;
            let context = CallContext {
                runtime: runtime.clone(),
                plugin_id: id.to_string(),
                cancel,
                started: Instant::now(),
                requests: AtomicUsize::new(0),
            };
            context.call(params["request"].clone())
        }
        _ => Err(Error::new(
            "unsupported",
            "Capability is not supported by the native runtime",
        )),
    }
}

pub fn source(
    runtime: Arc<Runtime>,
    method: String,
    mut params: Value,
    cancel: CancellationToken,
) -> Result<Value> {
    let id = string(&params, "pluginId")?.to_string();
    let manifest = {
        let c = runtime.catalog.lock().unwrap();
        let e = c.entry(&id)?;
        if !e.enabled {
            return Err(Error::new("plugin_disabled", "Native source is disabled"));
        }
        e.manifest.clone()
    };
    let operation = method
        .strip_prefix("source.")
        .and_then(|s| s.strip_suffix(".v1"))
        .ok_or_else(|| invalid("Invalid source operation"))?;
    if ![
        "discover",
        "search",
        "searchSuggestions",
        "getDetail",
        "getChapters",
        "getContent",
    ]
    .contains(&operation)
    {
        return Err(Error::new("unsupported", "Unknown source operation"));
    }
    let plugin = {
        let mut loaded = runtime.loaded.lock().unwrap();
        if !loaded.contains_key(&id) {
            let path = runtime.catalog.lock().unwrap().library(&manifest)?;
            loaded.insert(id.clone(), Arc::new(NativePlugin::load(&path, &manifest)?));
        }
        loaded[&id].clone()
    };
    let p = params
        .as_object_mut()
        .ok_or_else(|| invalid("Invalid source params"))?;
    p.remove("pluginId");
    if !p.contains_key("id") {
        if let Some(v) = p.remove("contentId") {
            p.insert("id".into(), v);
        }
    }
    if ["discover", "search", "searchSuggestions"].contains(&operation) {
        p.entry("pageSize").or_insert(json!(20));
        p.entry("cursor").or_insert(Value::Null);
    }
    if operation == "discover" {
        p.entry("target").or_insert(Value::Null);
        p.entry("collectionId").or_insert(Value::Null);
    }
    let mut context = CallContext {
        runtime: runtime.clone(),
        plugin_id: id.clone(),
        cancel: cancel.clone(),
        started: Instant::now(),
        requests: AtomicUsize::new(0),
    };
    if cancel.is_cancelled() {
        return Err(Error::new("cancelled", "Source call cancelled"));
    }
    let mut value = plugin.invoke(&mut context, json!({"method":operation,"request":params}))?;
    if cancel.is_cancelled() {
        return Err(Error::new("cancelled", "Source call cancelled"));
    }
    crate::validation::validate(operation, &params, &value)?;
    resource::resolve(&runtime, &id, &mut value, 0)?;
    let map = value
        .as_object_mut()
        .ok_or_else(|| invalid("Source result must be an object"))?;
    map.insert("pluginId".into(), json!(id));
    map.insert("sourceName".into(), json!(manifest.name));
    if operation == "getChapters" {
        map.entry("groups").or_insert(json!([]));
    }
    Ok(value)
}

fn rss() -> u64 {
    #[cfg(target_os = "android")]
    {
        return std::fs::read_to_string("/proc/self/status")
            .ok()
            .and_then(|s| {
                s.lines()
                    .find(|l| l.starts_with("VmRSS:"))
                    .and_then(|l| l.split_whitespace().nth(1))
                    .and_then(|v| v.parse::<u64>().ok())
            })
            .unwrap_or(0)
            * 1024;
    }
    #[cfg(target_os = "windows")]
    unsafe {
        #[repr(C)]
        struct Counters {
            cb: u32,
            faults: u32,
            peak: usize,
            working: usize,
            paged_peak: usize,
            paged: usize,
            nonpaged_peak: usize,
            nonpaged: usize,
            pagefile: usize,
            pagefile_peak: usize,
        }
        #[link(name = "psapi")]
        unsafe extern "system" {
            fn GetProcessMemoryInfo(
                process: *mut std::ffi::c_void,
                counters: *mut Counters,
                size: u32,
            ) -> i32;
        }
        let mut c: Counters = std::mem::zeroed();
        c.cb = std::mem::size_of::<Counters>() as u32;
        if GetProcessMemoryInfo(
            -1isize as *mut _,
            &mut c,
            std::mem::size_of::<Counters>() as u32,
        ) != 0
        {
            return c.working as u64;
        }
    }
    #[cfg(not(target_os = "android"))]
    {
        0
    }
}
