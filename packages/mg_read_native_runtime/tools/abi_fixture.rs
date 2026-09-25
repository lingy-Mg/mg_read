//! Test-only dynamic library for real foreign-ABI rejection and crash rollback.
//! The fixture is never included in a user source archive or application build.
#[allow(dead_code)]
#[path = "../abi/lib.rs"]
mod abi;
use abi::{Buffer, HostApi, SourceApi};

unsafe extern "C" fn invoke(_: *const HostApi, _: *const u8, _: usize) -> Buffer {
    Buffer::from_vec(br#"{"ok":true,"value":{}}"#.to_vec())
}
static VALID: SourceApi = SourceApi { version: 1, size: std::mem::size_of::<SourceApi>(), invoke, release: abi::release };
static WRONG: SourceApi = SourceApi { version: 999, size: std::mem::size_of::<SourceApi>(), invoke, release: abi::release };

#[unsafe(no_mangle)]
pub extern "C" fn mg_source_get_api_v1() -> *const SourceApi {
    match std::env::var("MGREAD_ABI_FIXTURE_MODE").as_deref() {
        Ok("abort") => std::process::abort(),
        Ok("wrong") => &WRONG,
        _ => &VALID,
    }
}
