//! Trusted native libraries stay loaded until the worker exits. C ABI calls run
//! off the async executor; no Rust allocations cross allocator ownership.
use crate::{
    catalog::{Manifest, hash},
    error::{Error, Result, invalid},
    io::CallContext,
};
use libloading::Library;
use mgread_native_abi::{ABI_VERSION, Buffer, HostApi, MAX_MESSAGE, SourceApi};
use serde_json::{Value, json};
use std::{ffi::c_void, path::Path};

pub struct NativePlugin {
    _library: Library,
    invoke: unsafe extern "C" fn(*const HostApi, *const u8, usize) -> Buffer,
    release: unsafe extern "C" fn(Buffer),
}
impl NativePlugin {
    pub fn load(path: &Path, manifest: &Manifest) -> Result<Self> {
        let expected = &manifest.targets[crate::catalog::target()].sha256;
        if &hash(&std::fs::read(path)?) != expected {
            return Err(invalid("Installed native binary integrity failed"));
        }
        unsafe {
            let library = Library::new(path).map_err(|e| {
                eprintln!("native_library_load_failed: {e}");
                Error::new("plugin_load_failed", "Native binary could not be loaded")
            })?;
            let get: libloading::Symbol<unsafe extern "C" fn() -> *const SourceApi> = library
                .get(b"mg_source_get_api_v1\0")
                .map_err(|_| invalid("Missing source ABI entry point"))?;
            let ptr = get();
            if ptr.is_null() {
                return Err(invalid("Null source ABI table"));
            }
            let api = &*ptr;
            if api.version != ABI_VERSION || api.size < std::mem::size_of::<SourceApi>() {
                return Err(invalid("Unsupported source ABI version"));
            }
            let invoke = api.invoke;
            let release = api.release;
            Ok(Self {
                _library: library,
                invoke,
                release,
            })
        }
    }
    pub fn invoke(&self, context: &mut CallContext, input: Value) -> Result<Value> {
        let bytes = serde_json::to_vec(&input)?;
        if bytes.len() > MAX_MESSAGE {
            return Err(invalid("Invocation is too large"));
        }
        let host = HostApi {
            version: ABI_VERSION,
            size: std::mem::size_of::<HostApi>(),
            context: context as *mut _ as *mut c_void,
            call: host_call,
            release: mgread_native_abi::release,
        };
        let raw = unsafe { (self.invoke)(&host, bytes.as_ptr(), bytes.len()) };
        if raw.ptr.is_null() {
            return Err(invalid("Plugin returned a null buffer"));
        }
        if raw.len > MAX_MESSAGE {
            unsafe { (self.release)(raw) };
            return Err(invalid("Plugin result exceeds 8 MiB"));
        }
        let parsed = unsafe {
            serde_json::from_slice::<Value>(std::slice::from_raw_parts(raw.ptr, raw.len))
        };
        unsafe { (self.release)(raw) };
        let response = parsed?;
        if response["ok"] == true {
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
unsafe extern "C" fn host_call(context: *mut c_void, ptr: *const u8, len: usize) -> Buffer {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<Value> {
        if context.is_null() || ptr.is_null() || len > MAX_MESSAGE {
            return Err(invalid("Invalid host call buffer"));
        }
        let ctx = unsafe { &*(context as *const CallContext) };
        let request = unsafe { serde_json::from_slice(std::slice::from_raw_parts(ptr, len)) }?;
        ctx.call(request)
    }))
    .unwrap_or_else(|_| Err(Error::new("runtime_error", "Native host call failed")));
    let response = match result {
        Ok(value) => json!({"ok":true,"value":value}),
        Err(e) => e.envelope(),
    };
    Buffer::from_vec(serde_json::to_vec(&response).unwrap_or_default())
}
