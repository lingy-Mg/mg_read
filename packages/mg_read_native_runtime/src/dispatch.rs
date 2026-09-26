//! Versioned Facade operations. Installation and library lifetime are independent
//! of Node; source result semantics remain compatible with typed Flutter decoders.
use crate::{
    Runtime, catalog,
    error::{Error, Result, invalid, string},
    native::NativePlugin,
};
use base64::Engine;
use serde_json::{Value, json};
use std::sync::{Arc, atomic::Ordering};
use tokio_util::sync::CancellationToken;

pub fn control(
    runtime: &Arc<Runtime>,
    method: &str,
    params: &Value,
    cancel: CancellationToken,
    call_id: u64,
) -> Result<Value> {
    match method {
        "runtime.ping" => Ok(
            json!({"ok":true,"nodeVersion":"","runtimeVersion":"native-0.2.0","runtimeKind":"native-rust"}),
        ),
        "runtime.status.v1" => Ok(
            json!({"ok":true,"nodeVersion":"","runtimeVersion":"native-0.2.0","runtimeKind":"native-rust",
            "platform":std::env::consts::OS,"arch":std::env::consts::ARCH,"uptimeMs":runtime.started.elapsed().as_millis() as u64,
            "plugins":runtime.catalog.lock().unwrap().list(),"memory":{"rss":rss(),"arrayBuffers":0,"external":0,"heapTotal":0,"heapUsed":0},
            "native":{"loadedPlugins":runtime.loaded.lock().unwrap().len(),"inflight":runtime.jobs.lock().unwrap().len()}}),
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
            if !runtime.loaded.lock().unwrap().is_empty() {
                return Err(Error::new(
                    "restart_required",
                    "Proxy changes require a worker restart",
                ));
            }
            if let Some(proxy) = proxy {
                let url = url::Url::parse(proxy).map_err(|_| invalid("Invalid upstream proxy"))?;
                if !["http", "https", "socks5", "socks5h"].contains(&url.scheme()) {
                    return Err(invalid("Unsupported upstream proxy"));
                }
            }
            *runtime.proxy.lock().unwrap() = proxy.map(str::to_owned);
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
            if method != "plugins.cache.usage.v1" {
                runtime.shutdown()?;
            }
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
            if runtime.stopping.load(Ordering::SeqCst) {
                return Err(Error::new("runtime_stopping", "Native worker is stopping"));
            }
            let url = string(params, "url")?;
            let _gate = runtime.source_gate.lock().unwrap();
            let plugin = runtime
                .loaded
                .lock()
                .unwrap()
                .values()
                .find(|p| p.validate_resource(url).is_ok())
                .cloned()
                .ok_or_else(|| invalid("Unknown or expired source resource"))?;
            plugin.invoke(
                call_id,
                json!({"method":"resource.inspect","request":{"url":url}}),
                &cancel,
            )
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
                items.push(json!({"id":m.id,"version":m.version,"format":"archive","engine":"native","provenance":"installed","developmentFingerprint":null,"developmentRevision":null,"bytes":bytes.len(),"checksum":catalog::transfer_checksum(&bytes)}));
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
            runtime.shutdown()?;
            std::thread::spawn(|| {
                std::thread::sleep(std::time::Duration::from_millis(250));
                std::process::exit(0);
            });
            Ok(json!({"stopping":true}))
        }
        "runtime.native.fault.v1" if runtime.test_mode => std::process::abort(),
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
    call_id: u64,
) -> Result<Value> {
    let _gate = runtime.source_gate.lock().unwrap();
    if runtime.stopping.load(Ordering::SeqCst) {
        return Err(Error::new("runtime_stopping", "Native worker is stopping"));
    }
    if cancel.is_cancelled() {
        return Err(Error::new("cancelled", "Source call cancelled"));
    }
    let id = string(&params, "pluginId")?.to_string();
    let manifest = {
        let c = runtime.catalog.lock().unwrap();
        let e = c.entry(&id)?;
        if !e.enabled {
            return Err(Error::new("plugin_disabled", "Native source is disabled"));
        }
        if e.pending.is_some() && runtime.loaded.lock().unwrap().contains_key(&id) {
            return Err(Error::new(
                "restart_required",
                "Source update requires worker restart",
            ));
        }
        e.pending.clone().unwrap_or_else(|| e.manifest.clone())
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
    if !manifest.capabilities.iter().any(|c| c == operation) {
        return Err(Error::new(
            "unsupported",
            "Source capability is not declared",
        ));
    }
    let existing = runtime.loaded.lock().unwrap().get(&id).cloned();
    let plugin = if let Some(plugin) = existing {
        plugin
    } else {
        let path = {
            let mut catalog = runtime.catalog.lock().unwrap();
            let path = catalog.library(&manifest)?;
            let entry = catalog.entries.get_mut(&id).unwrap();
            entry.pending = None;
            entry.loading = true;
            catalog.save()?;
            path
        };
        let generation = catalog::hash(
            format!(
                "{}:{}:{}:{:?}",
                runtime.token,
                id,
                std::process::id(),
                std::time::SystemTime::now()
            )
            .as_bytes(),
        );
        let loaded = crate::native::init_config(
            &runtime.root,
            &id,
            &generation,
            runtime.proxy.lock().unwrap().clone(),
            runtime.test_mode,
        )
        .and_then(|config| NativePlugin::load(&path, &manifest, config));
        let mut catalog = runtime.catalog.lock().unwrap();
        let entry = catalog.entries.get_mut(&id).unwrap();
        entry.loading = false;
        match loaded {
            Ok(plugin) => {
                entry.manifest = manifest.clone();
                catalog.save()?;
                let plugin = Arc::new(plugin);
                runtime
                    .loaded
                    .lock()
                    .unwrap()
                    .insert(id.clone(), plugin.clone());
                plugin
            }
            Err(error) => {
                entry.enabled = false;
                catalog.save()?;
                return Err(error);
            }
        }
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
    if cancel.is_cancelled() {
        return Err(Error::new("cancelled", "Source call cancelled"));
    }
    let mut value = plugin.invoke(
        call_id,
        json!({"method":operation,"request":params}),
        &cancel,
    )?;
    if cancel.is_cancelled() {
        return Err(Error::new("cancelled", "Source call cancelled"));
    }
    crate::validation::validate(operation, &params, &value)?;
    crate::native::validate_resources(&plugin, &value)?;
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
