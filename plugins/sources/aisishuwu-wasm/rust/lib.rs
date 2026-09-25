//! Stateless source binary. ABI allocations belong to the caller until release;
//! invoke never retains input pointers. All IO is expressed as JSON continuations.
mod parsing;
mod source;

use std::sync::atomic::{AtomicU32, Ordering};
static RESULT_LEN: AtomicU32 = AtomicU32::new(0);

#[unsafe(no_mangle)]
pub extern "C" fn abi_version() -> u32 {
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn alloc(length: u32) -> *mut u8 {
    if length == 0 || length > 8 * 1024 * 1024 {
        return std::ptr::null_mut();
    }
    Box::into_raw(vec![0u8; length as usize].into_boxed_slice()) as *mut u8
}

/// # Safety
/// ptr/length must describe a live allocation returned by this ABI, exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn release(ptr: *mut u8, length: u32) {
    if !ptr.is_null() && length != 0 {
        unsafe {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
                ptr,
                length as usize,
            )));
        }
    }
}

/// # Safety
/// input must refer to length initialized bytes allocated by alloc.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn invoke(input: *const u8, length: u32) -> *mut u8 {
    let result = if input.is_null() || length > 8 * 1024 * 1024 {
        Err("input_invalid")
    } else {
        let bytes = unsafe { std::slice::from_raw_parts(input, length as usize) };
        serde_json::from_slice(bytes)
            .map_err(|_| "json_invalid")
            .and_then(source::dispatch)
    };
    let value = result.unwrap_or_else(|code| serde_json::json!({"kind":"error", "code":code}));
    let output = serde_json::to_vec(&value)
        .expect("JSON value")
        .into_boxed_slice();
    RESULT_LEN.store(output.len() as u32, Ordering::Relaxed);
    Box::into_raw(output) as *mut u8
}

#[unsafe(no_mangle)]
pub extern "C" fn result_len() -> u32 {
    RESULT_LEN.load(Ordering::Relaxed)
}
