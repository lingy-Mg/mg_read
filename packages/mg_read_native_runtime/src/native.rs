//! ABI v2 adapter. One plugin instance per library per worker, serialized by the
//! Runtime admission gate. Libraries stay pinned even after failed init:
//! process death is the only safe unload boundary for foreign code.
use crate::{
    catalog::{Manifest, hash},
    error::{Error, Result, invalid},
};
use libloading::Library;
use mgread_native_abi::{ABI_VERSION, Buffer, MAX_MESSAGE, SourceApi};
use serde_json::{Value, json};
use std::{
    mem::ManuallyDrop,
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
};
use tokio_util::sync::CancellationToken;

pub struct NativePlugin {
    _library: ManuallyDrop<Library>,
    api: SourceApi,
    pub endpoint: Value,
    active: AtomicU64,
}
impl NativePlugin {
    pub fn load(path: &Path, manifest: &Manifest, config: Value) -> Result<Self> {
        if manifest.abi != ABI_VERSION {
            return Err(Error::new(
                "unsupported_abi",
                "Reinstall this source using an ABI v2 archive",
            ));
        }
        if hash(&std::fs::read(path)?) != manifest.targets[crate::catalog::target()].sha256 {
            return Err(invalid("Native binary integrity failed"));
        }
        unsafe {
            let library = ManuallyDrop::new(Library::new(path).map_err(|_| {
                Error::new("plugin_load_failed", "Native binary could not be loaded")
            })?);
            let get: libloading::Symbol<unsafe extern "C" fn() -> *const SourceApi> = library
                .get(b"mg_source_get_api_v2\0")
                .map_err(|_| invalid("Missing source ABI v2 entry"))?;
            let pointer = get();
            if pointer.is_null() {
                return Err(invalid("Null source ABI table"));
            }
            if std::ptr::addr_of!((*pointer).version).read() != ABI_VERSION
                || std::ptr::addr_of!((*pointer).size).read() < std::mem::size_of::<SourceApi>()
            {
                return Err(invalid("Unsupported source ABI table"));
            }
            let api = pointer.read();
            let mut plugin = Self {
                _library: library,
                api,
                endpoint: Value::Null,
                active: AtomicU64::new(0),
            };
            let input = serde_json::to_vec(&config)?;
            let result = plugin.decode((api.init)(input.as_ptr(), input.len()));
            match result {
                Ok(endpoint)
                    if endpoint["pluginId"] == config["pluginId"]
                        && endpoint["generation"] == config["generation"]
                        && endpoint["port"]
                            .as_u64()
                            .is_some_and(|p| p > 0 && p <= 65535) =>
                {
                    plugin.endpoint = endpoint
                }
                _ => {
                    let _ = plugin.shutdown();
                    return Err(Error::new(
                        "plugin_init_failed",
                        "Native source initialization failed",
                    ));
                }
            }
            Ok(plugin)
        }
    }
    pub fn invoke(&self, id: u64, input: Value, cancel: &CancellationToken) -> Result<Value> {
        let bytes = serde_json::to_vec(&input)?;
        if bytes.len() > MAX_MESSAGE {
            return Err(invalid("Invocation is too large"));
        }
        self.active.store(id, Ordering::SeqCst);
        if cancel.is_cancelled() {
            self.active.store(0, Ordering::SeqCst);
            return Err(Error::new("cancelled", "Source call cancelled"));
        }
        let raw = unsafe { (self.api.invoke)(id, bytes.as_ptr(), bytes.len()) };
        self.active.store(0, Ordering::SeqCst);
        self.decode(raw)
    }
    pub fn cancel(&self, id: u64) {
        if self.active.load(Ordering::SeqCst) == id {
            unsafe { (self.api.cancel)(id) };
        }
    }
    pub fn shutdown(&self) -> Result<Value> {
        self.decode(unsafe { (self.api.shutdown)() })
    }
    pub fn resource_prefix(&self) -> String {
        format!(
            "http://127.0.0.1:{}/v2/source-resource/native/{}/{}/",
            self.endpoint["port"],
            self.endpoint["pluginId"].as_str().unwrap(),
            self.endpoint["generation"].as_str().unwrap()
        )
    }
    pub fn validate_resource(&self, url: &str) -> Result<()> {
        let token = url
            .strip_prefix(&self.resource_prefix())
            .ok_or_else(|| invalid("Resource does not belong to the active source instance"))?;
        if token.len() != 64 || !token.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(invalid("Invalid source resource token"));
        }
        Ok(())
    }
    fn decode(&self, raw: Buffer) -> Result<Value> {
        if raw.ptr.is_null() {
            return Err(invalid("Plugin returned a null buffer"));
        }
        if raw.len > MAX_MESSAGE {
            unsafe { (self.api.release)(raw) };
            return Err(invalid("Plugin result exceeds 8 MiB"));
        }
        let parsed = unsafe {
            serde_json::from_slice::<Value>(std::slice::from_raw_parts(raw.ptr, raw.len))
        };
        unsafe { (self.api.release)(raw) };
        let response = parsed?;
        if response["ok"] == true && response.get("value").is_some() {
            Ok(response["value"].clone())
        } else {
            Err(Error::new(
                response["error"]["code"]
                    .as_str()
                    .unwrap_or("plugin_invalid_response"),
                response["error"]["message"]
                    .as_str()
                    .unwrap_or("Native source failed"),
            ))
        }
    }
}
pub fn validate_resources(plugin: &NativePlugin, value: &Value) -> Result<()> {
    match value {
        Value::Object(map) => {
            if map.contains_key("$resource") {
                return Err(invalid("Plugin did not resolve its resource descriptor"));
            }
            for (key, value) in map {
                if let Some(url) = value.as_str() {
                    if key == "coverUrl"
                        || (key == "url"
                            && (map.contains_key("resourcePolicy")
                                || map.contains_key("resourceType")
                                || map.contains_key("index")))
                        || url.contains("/v2/source-resource/")
                    {
                        plugin.validate_resource(url)?;
                    }
                }
                validate_resources(plugin, value)?;
            }
        }
        Value::Array(items) => {
            for value in items {
                validate_resources(plugin, value)?;
            }
        }
        _ => {}
    }
    Ok(())
}
pub fn init_config(
    root: &Path,
    id: &str,
    generation: &str,
    proxy: Option<String>,
    test_mode: bool,
) -> Result<Value> {
    let plugin = root.join("plugins").join(id);
    let cache = plugin.join("cache");
    for path in [&plugin, &cache] {
        std::fs::create_dir_all(path)?;
        if std::fs::symlink_metadata(path)?.file_type().is_symlink()
            || !path.canonicalize()?.starts_with(root)
        {
            return Err(invalid("Invalid plugin cache directory"));
        }
    }
    Ok(
        json!({"pluginId":id,"generation":generation,"cacheDir":cache.canonicalize()?,"upstreamProxy":proxy,"testMode":test_mode}),
    )
}
