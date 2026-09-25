//! Native source ABI v1. Buffers are freed only by their allocating side. Calls
//! borrow their input and host context until return; plugins must not retain them.
use std::ffi::c_void;

pub const ABI_VERSION: u32 = 1;
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
        Self { ptr: Box::into_raw(bytes) as *mut u8, len }
    }
}

/// # Safety
/// Buffer must have been allocated by this library's Buffer::from_vec once.
pub unsafe extern "C" fn release(buffer: Buffer) {
    if !buffer.ptr.is_null() {
        unsafe { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(buffer.ptr, buffer.len))) };
    }
}

#[repr(C)]
pub struct HostApi {
    pub version: u32,
    pub size: usize,
    pub context: *mut c_void,
    pub call: unsafe extern "C" fn(*mut c_void, *const u8, usize) -> Buffer,
    pub release: unsafe extern "C" fn(Buffer),
}

#[repr(C)]
pub struct SourceApi {
    pub version: u32,
    pub size: usize,
    pub invoke: unsafe extern "C" fn(*const HostApi, *const u8, usize) -> Buffer,
    pub release: unsafe extern "C" fn(Buffer),
}
