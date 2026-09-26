//! Test-only dynamic library for real foreign-ABI rejection and crash rollback.
//! The fixture is never included in a user source archive or application build.
#[allow(dead_code)]
#[path = "../abi/lib.rs"]
mod abi;
use abi::{Buffer, SourceApi};

unsafe extern "C" fn init(input: *const u8, length: usize) -> Buffer {
    if std::env::var("MGREAD_ABI_FIXTURE_MODE").as_deref() == Ok("init-fail") {
        return Buffer::from_vec(br#"{"ok":false,"error":{"code":"fixture_init_failed","message":"Fixture initialization failed"}}"#.to_vec());
    }
    let input = unsafe { std::str::from_utf8(std::slice::from_raw_parts(input, length)).unwrap() };
    fn field<'a>(text: &'a str, key: &str) -> &'a str { text.split(&format!("\"{key}\":\"")).nth(1).unwrap().split('"').next().unwrap() }
    Buffer::from_vec(format!("{{\"ok\":true,\"value\":{{\"pluginId\":\"{}\",\"generation\":\"{}\",\"port\":12345}}}}", field(input,"pluginId"), field(input,"generation")).into_bytes())
}
unsafe extern "C" fn invoke(_: u64, _: *const u8, _: usize) -> Buffer {
    Buffer::from_vec(br#"{"ok":true,"value":{"items":[],"nextCursor":null}}"#.to_vec())
}
unsafe extern "C" fn cancel(_: u64) {}
unsafe extern "C" fn shutdown() -> Buffer {
    Buffer::from_vec(br#"{"ok":true,"value":{"stopped":true}}"#.to_vec())
}
static VALID: SourceApi = SourceApi { version: 2, size: std::mem::size_of::<SourceApi>(), init, invoke, cancel, shutdown, release: abi::release };
static WRONG: SourceApi = SourceApi { version: 999, size: std::mem::size_of::<SourceApi>(), ..VALID };

#[unsafe(no_mangle)]
pub extern "C" fn mg_source_get_api_v2() -> *const SourceApi {
    match std::env::var("MGREAD_ABI_FIXTURE_MODE").as_deref() {
        Ok("abort") => std::process::abort(),
        Ok("wrong") => &WRONG,
        _ => &VALID,
    }
}
