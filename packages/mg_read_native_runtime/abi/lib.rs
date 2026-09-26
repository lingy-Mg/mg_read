//! Bootstrap-only native ABI. The host lends init JSON for the duration of one
//! call and receives a fixed-size value. No allocation, release function, content
//! invocation or cancellation crosses the DLL boundary. Libraries stay pinned
//! in the single worker until process exit; all later operations use HTTP.

pub const ABI_VERSION: u32 = 3;
pub const MAX_MESSAGE: usize = 8 * 1024 * 1024;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct InitResult {
    pub version: u32,
    pub status: u32,
    pub port: u16,
    pub reserved: u16,
}
impl InitResult {
    pub const fn ready(port: u16) -> Self {
        Self { version: ABI_VERSION, status: 0, port, reserved: 0 }
    }
    pub const fn failed() -> Self {
        Self { version: ABI_VERSION, status: 1, port: 0, reserved: 0 }
    }
}
