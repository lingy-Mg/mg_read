//! Native source ABI v2: one instance per library per worker, with serialized
//! init/invoke/shutdown. Only cancel may run concurrently with invoke. Inputs are
//! borrowed until return; output buffers are released by their allocating library.
//! Initialization performs local setup only. A stuck init/shutdown retires the
//! worker; libraries are never unloaded while that worker is alive.

pub const ABI_VERSION: u32 = 2;
pub const MAX_MESSAGE: usize = 8 * 1024 * 1024;

#[repr(C)]
pub struct Buffer {
    pub ptr: *mut u8,
    pub len: usize,
}

impl Buffer {
    pub fn from_vec(bytes: Vec<u8>) -> Self {
        let bytes = bytes.into_boxed_slice();
        let len = bytes.len();
        Self {
            ptr: Box::into_raw(bytes) as *mut u8,
            len,
        }
    }
}

/// # Safety
/// Buffer must have been allocated by this library's Buffer::from_vec once.
pub unsafe extern "C" fn release(buffer: Buffer) {
    if !buffer.ptr.is_null() {
        unsafe {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
                buffer.ptr, buffer.len,
            )))
        };
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SourceApi {
    pub version: u32,
    pub size: usize,
    pub init: unsafe extern "C" fn(*const u8, usize) -> Buffer,
    pub invoke: unsafe extern "C" fn(u64, *const u8, usize) -> Buffer,
    pub cancel: unsafe extern "C" fn(u64),
    pub shutdown: unsafe extern "C" fn() -> Buffer,
    pub release: unsafe extern "C" fn(Buffer),
}
