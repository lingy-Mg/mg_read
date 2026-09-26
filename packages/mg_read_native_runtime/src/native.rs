//! One initialization ABI call per DLL in the shared worker. All later traffic
//! uses the plugin HTTP listener. Libraries remain pinned until process exit.
use crate::{
    catalog::{Manifest, hash},
    error::{Error, Result, invalid},
};
use libloading::Library;
use mgread_native_abi::{ABI_VERSION, InitResult};
use serde_json::{Value, json};
use std::{mem::ManuallyDrop, path::Path};

pub struct NativePlugin {
    _library: ManuallyDrop<Library>,
    pub endpoint: Value,
}
impl NativePlugin {
    pub fn load(path: &Path, manifest: &Manifest, config: Value) -> Result<Self> {
        if manifest.abi != ABI_VERSION {
            return Err(Error::new(
                "unsupported_abi",
                "Reinstall this source using an ABI v3 archive",
            ));
        }
        if hash(&std::fs::read(path)?) != manifest.targets[crate::catalog::target()].sha256 {
            return Err(invalid("Native binary integrity failed"));
        }
        unsafe {
            let library = ManuallyDrop::new(Library::new(path).map_err(|_| {
                Error::new("plugin_load_failed", "Native binary could not be loaded")
            })?);
            let init: libloading::Symbol<unsafe extern "C" fn(*const u8, usize) -> InitResult> =
                library
                    .get(b"mg_source_init_v3\0")
                    .map_err(|_| invalid("Missing source initialization entry"))?;
            let input = serde_json::to_vec(&config)?;
            let ready = init(input.as_ptr(), input.len());
            if ready.version != ABI_VERSION
                || ready.status != 0
                || ready.port == 0
                || ready.reserved != 0
            {
                return Err(Error::new(
                    "plugin_init_failed",
                    "Native source initialization failed",
                ));
            }
            Ok(Self {
                _library: library,
                endpoint: json!({"pluginId":manifest.id,"generation":config["generation"],"port":ready.port,"controlToken":config["controlToken"]}),
            })
        }
    }
    pub async fn shutdown(&self, client: &reqwest::Client) -> Result<()> {
        let port = self.endpoint["port"].as_u64().unwrap() as u16;
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            client
                .post(format!("http://127.0.0.1:{port}/shutdown"))
                .bearer_auth(self.endpoint["controlToken"].as_str().unwrap())
                .send()
                .await
                .map_err(|_| Error::new("shutdown_failed", "Plugin HTTP shutdown failed"))?
                .error_for_status()
                .map_err(|_| Error::new("shutdown_failed", "Plugin HTTP shutdown rejected"))?;
            // The HTTP response only acknowledges stop intent. Wait for the
            // listener to close before reporting cooperative service shutdown.
            while tokio::net::TcpStream::connect(("127.0.0.1", port))
                .await
                .is_ok()
            {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
            Ok(())
        })
        .await
        .map_err(|_| Error::new("shutdown_failed", "Plugin listener did not stop"))?
    }
}
pub fn init_config(
    root: &Path,
    manifest: &Manifest,
    generation: &str,
    control_token: &str,
    proxy: Option<String>,
    test_mode: bool,
) -> Result<Value> {
    let plugin = root.join("plugins").join(&manifest.id);
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
        json!({"pluginId":manifest.id,"sourceName":manifest.name,"capabilities":manifest.capabilities,"generation":generation,"controlToken":control_token,"cacheDir":cache.canonicalize()?,"upstreamProxy":proxy,"testMode":test_mode}),
    )
}
