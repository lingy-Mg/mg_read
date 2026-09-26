//! Test-only initialization failure/crash fixture, never shipped to users.
#[allow(dead_code)]
#[path = "../abi/lib.rs"]
mod abi;
#[unsafe(no_mangle)]
pub extern "C" fn mg_source_init_v3(_: *const u8, _: usize) -> abi::InitResult {
    match std::env::var("MGREAD_ABI_FIXTURE_MODE").as_deref() {
        Ok("abort") => std::process::abort(),
        Ok("wrong") => abi::InitResult {version:999,status:0,port:12345,reserved:0},
        _ => abi::InitResult::failed(),
    }
}
