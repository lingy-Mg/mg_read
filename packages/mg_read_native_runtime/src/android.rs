//! APK-owned JNI bootstrap. The Android private Service owns this process, and
//! therefore owns all Rust threads and libraries; RPC payloads never cross Binder.
use jni::{
    JNIEnv,
    objects::{JClass, JString},
    sys::jstring,
};
use std::path::PathBuf;

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_mgread_mgread_1plugin_1runtime_NativeRuntime_start(
    mut env: JNIEnv,
    _class: JClass,
    root: JString,
    token: JString,
) -> jstring {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(
        || -> std::result::Result<String, String> {
            let root: String = env.get_string(&root).map_err(|_| "Invalid root")?.into();
            let token: String = env.get_string(&token).map_err(|_| "Invalid token")?.into();
            let (tx, rx) = std::sync::mpsc::sync_channel(1);
            std::thread::spawn(move || {
                let rt = match tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(4)
                    .enable_all()
                    .build()
                {
                    Ok(rt) => rt,
                    Err(_) => {
                        let _ = tx.send(Err("Native executor failed".into()));
                        return;
                    }
                };
                let ready_tx = tx.clone();
                if let Err(error) = rt.block_on(crate::serve(
                    PathBuf::from(root),
                    token,
                    false,
                    move |ready| {
                        let _ = ready_tx.send(Ok(ready.to_string()));
                    },
                )) {
                    let _ = tx.send(Err(error.to_string()));
                }
            });
            rx.recv_timeout(std::time::Duration::from_secs(25))
                .map_err(|_| "Native startup timeout".to_string())?
        },
    ))
    .unwrap_or_else(|_| Err("Native bootstrap failed".into()));
    match result {
        Ok(value) => env
            .new_string(value)
            .map(|s| s.into_raw())
            .unwrap_or(std::ptr::null_mut()),
        Err(message) => {
            let _ = env.throw_new("java/lang/IllegalStateException", message);
            std::ptr::null_mut()
        }
    }
}
