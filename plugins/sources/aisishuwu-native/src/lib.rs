//! Native Alice source entry. This module owns the C ABI and synchronous host
//! adapter; pure parsing and route state remain in their dedicated modules.
mod parsing;
mod source;

use mgread_native_abi::{ABI_VERSION, Buffer, HostApi, MAX_MESSAGE, SourceApi};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::time::{SystemTime, UNIX_EPOCH};

const SOURCE_ID: &str = "org.mgread.aisishuwu.native";
const SOURCE_VERSION: &str = "0.1.0";
const BODY_LIMIT: usize = 4 * 1024 * 1024;
const REQUEST_LIMIT: usize = 128;
const STEPS_LIMIT: usize = 128;
const HTTP_BATCH_LIMIT: usize = 4;
const HOST_API_SIZE: usize = std::mem::size_of::<HostApi>();

#[derive(Debug)]
struct NativeError {
    code: String,
    message: String,
}

impl NativeError {
    fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    fn source(code: &'static str) -> Self {
        let message = match code {
            "source_access_blocked" => "Alice source access is blocked.",
            "catalog_incomplete" => "The chapter catalog is incomplete.",
            "catalog_empty" => "The chapter catalog is empty.",
            "cursor_invalid" => "The source cursor is invalid.",
            "id_invalid" | "chapter_invalid" => "The source identity is invalid.",
            "method_unsupported" => "The source method is unsupported.",
            _ => "The source operation failed.",
        };
        Self::new(code, message)
    }
}

fn failure(error: NativeError) -> Value {
    json!({"ok":false,"error":{"code":error.code,"message":error.message}})
}

fn success(value: Value) -> Value {
    json!({"ok":true,"value":value})
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

fn cache_ttl_ms(method: &str) -> u64 {
    match method {
        "getContent" => 6 * 60 * 60 * 1000,
        "getChapters" => 10 * 60 * 1000,
        "getDetail" => 15 * 60 * 1000,
        "discover" | "search" | "searchSuggestions" => 5 * 60 * 1000,
        _ => 0,
    }
}

struct HostBuffer<'a> {
    api: &'a HostApi,
    ptr: *mut u8,
    len: usize,
}

impl Drop for HostBuffer<'_> {
    fn drop(&mut self) {
        // The host allocated this buffer, so only HostApi.release may free it.
        unsafe {
            (self.api.release)(Buffer {
                ptr: self.ptr,
                len: self.len,
            })
        };
    }
}

fn host_call(host: &HostApi, request: &Value) -> Result<Value, NativeError> {
    let bytes = serde_json::to_vec(request)
        .map_err(|_| NativeError::new("host_request_invalid", "The host request is invalid."))?;
    if bytes.len() > MAX_MESSAGE {
        return Err(NativeError::new(
            "host_request_limit",
            "The host request is too large.",
        ));
    }
    let output = unsafe { (host.call)(host.context, bytes.as_ptr(), bytes.len()) };
    let buffer = HostBuffer {
        api: host,
        ptr: output.ptr,
        len: output.len,
    };
    if output.len > MAX_MESSAGE || (output.ptr.is_null() && output.len != 0) {
        return Err(NativeError::new(
            "host_response_limit",
            "The host response is invalid or too large.",
        ));
    }
    let bytes = if output.len == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(output.ptr, output.len) }
    };
    let envelope: Value = serde_json::from_slice(bytes).map_err(|_| {
        NativeError::new(
            "host_response_invalid",
            "The host response is not valid JSON.",
        )
    })?;
    if envelope["ok"] == false {
        let code = envelope["error"]["code"]
            .as_str()
            .filter(|code| !code.is_empty() && code.len() <= 64)
            .unwrap_or("host_call_failed");
        return Err(NativeError::new(code, "The native host operation failed."));
    }
    if envelope["ok"] != true || !envelope.get("value").is_some() {
        return Err(NativeError::new(
            "host_response_invalid",
            "The host response envelope is invalid.",
        ));
    }
    let value = envelope["value"].clone();
    drop(buffer);
    Ok(value)
}

fn cancelled(host: &HostApi) -> Result<bool, NativeError> {
    let value = host_call(host, &json!({"op":"cancelled"}))?;
    value.as_bool().ok_or_else(|| {
        NativeError::new(
            "host_response_invalid",
            "The host cancellation state is invalid.",
        )
    })
}

fn check_cancelled(host: &HostApi) -> Result<(), NativeError> {
    if cancelled(host)? {
        Err(NativeError::new(
            "cancelled",
            "The source call was cancelled.",
        ))
    } else {
        Ok(())
    }
}

fn cache_path(method: &str, request: &Value) -> Result<String, NativeError> {
    let key = serde_json::to_vec(
        &json!({"id":SOURCE_ID,"version":SOURCE_VERSION,"method":method,"request":request}),
    )
    .map_err(|_| NativeError::new("cache_key_invalid", "The source cache key is invalid."))?;
    let digest = Sha256::digest(key);
    let mut hex = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write;
        let _ = write!(hex, "{byte:02x}");
    }
    Ok(format!("aisishuwu-native/v1/{hex}.json"))
}

fn cached_result(
    host: &HostApi,
    method: &str,
    request: &Value,
) -> Result<Option<Value>, NativeError> {
    let path = cache_path(method, request)?;
    let value = match host_call(
        host,
        &json!({"op":"storage.read","area":"cache","path":path}),
    ) {
        Ok(value) => value,
        Err(error) if error.code == "cancelled" => return Err(error),
        Err(_) => return Ok(None),
    };
    let Some(text) = value.as_str() else {
        return Ok(None);
    };
    let record: Value = match serde_json::from_str(text) {
        Ok(record) => record,
        Err(_) => return Ok(None),
    };
    if record["expiresAtMs"]
        .as_u64()
        .is_some_and(|expires| expires > now_ms())
        && record.get("value").is_some()
    {
        Ok(Some(record["value"].clone()))
    } else {
        let _ = host_call(
            host,
            &json!({"op":"storage.remove","area":"cache","path":path}),
        );
        Ok(None)
    }
}

fn store_result(host: &HostApi, method: &str, request: &Value, value: &Value) {
    let ttl = cache_ttl_ms(method);
    if ttl == 0 {
        return;
    }
    let Ok(path) = cache_path(method, request) else {
        return;
    };
    let record = json!({"expiresAtMs":now_ms().saturating_add(ttl),"value":value});
    let Ok(text) = serde_json::to_string(&record) else {
        return;
    };
    if text.len() > MAX_MESSAGE {
        return;
    }
    let _ = host_call(
        host,
        &json!({"op":"storage.write","area":"cache","path":path,"value":text}),
    );
}

fn checked_http_url(value: &Value) -> Result<&str, NativeError> {
    let url = value["url"].as_str().ok_or_else(|| {
        NativeError::new("native_http_url_invalid", "The source HTTP URL is invalid.")
    })?;
    let parsed = url::Url::parse(url).map_err(|_| {
        NativeError::new("native_http_url_invalid", "The source HTTP URL is invalid.")
    })?;
    if parsed.scheme() != "https"
        || parsed.origin().ascii_serialization() != parsing::ORIGIN
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        return Err(NativeError::new(
            "native_http_url_invalid",
            "The source HTTP URL is outside the Alice origin.",
        ));
    }
    Ok(url)
}

fn http_response(host: &HostApi, request: &Value) -> Result<Value, NativeError> {
    check_cancelled(host)?;
    let url = checked_http_url(request)?;
    let headers = request.get("headers").cloned().unwrap_or_else(|| json!({}));
    let value = host_call(host, &json!({"op":"http","url":url,"headers":headers}));
    match value {
        Ok(response) => {
            let status = response["status"].as_u64().unwrap_or(0);
            let body = response["body"].as_str();
            if !(200..300).contains(&status) || body.is_none() {
                if request["optional"] == true {
                    return Ok(json!({"error":"http_failed"}));
                }
                return Err(NativeError::new(
                    "source_http_failed",
                    "Alice returned an unsuccessful response.",
                ));
            }
            let body = body.unwrap();
            if body.len() > BODY_LIMIT {
                return Err(NativeError::new(
                    "source_http_body_limit",
                    "Alice returned a response that is too large.",
                ));
            }
            Ok(json!({"body":body}))
        }
        Err(error) if request["optional"] == true && error.code != "cancelled" => {
            Ok(json!({"error":"http_failed"}))
        }
        Err(error) => Err(error),
    }
}

fn invoke_inner(host: &HostApi, input: Value) -> Result<Value, NativeError> {
    let method = input["method"]
        .as_str()
        .ok_or_else(|| NativeError::source("request_invalid"))?;
    if !matches!(
        method,
        "discover" | "search" | "searchSuggestions" | "getDetail" | "getChapters" | "getContent"
    ) {
        return Err(NativeError::source("method_unsupported"));
    }
    let request = input.get("request").cloned().unwrap_or(Value::Null);
    check_cancelled(host)?;
    if let Some(value) = cached_result(host, method, &request)? {
        return Ok(success(value));
    }

    let mut source_input = json!({"method":method,"request":request,"state":null});
    let mut request_count = 0usize;
    for _ in 0..STEPS_LIMIT {
        check_cancelled(host)?;
        let output = source::dispatch(source_input.clone()).map_err(NativeError::source)?;
        match output["kind"].as_str() {
            Some("result") => {
                let value = output
                    .get("value")
                    .cloned()
                    .ok_or_else(|| NativeError::source("result_invalid"))?;
                let bytes = serde_json::to_vec(&value).map_err(|_| {
                    NativeError::new("result_invalid", "The source result could not be encoded.")
                })?;
                if bytes.len() > MAX_MESSAGE {
                    return Err(NativeError::new(
                        "source_result_limit",
                        "The source result is too large.",
                    ));
                }
                check_cancelled(host)?;
                store_result(host, method, &request, &value);
                return Ok(success(value));
            }
            Some("http") => {
                let requests = output["requests"]
                    .as_array()
                    .filter(|requests| !requests.is_empty() && requests.len() <= HTTP_BATCH_LIMIT)
                    .ok_or_else(|| {
                        NativeError::new(
                            "native_step_invalid",
                            "The source requested an invalid HTTP batch.",
                        )
                    })?;
                request_count += requests.len();
                if request_count > REQUEST_LIMIT {
                    return Err(NativeError::new(
                        "native_request_limit",
                        "The source made too many HTTP requests.",
                    ));
                }
                let mut responses = Vec::with_capacity(requests.len());
                for request in requests {
                    responses.push(http_response(host, request)?);
                }
                source_input = json!({
                    "method":method,
                    "request":request,
                    "state":output.get("state").cloned().unwrap_or(Value::Null),
                    "responses":responses
                });
            }
            _ => {
                return Err(NativeError::new(
                    "native_step_invalid",
                    "The source returned an invalid continuation.",
                ));
            }
        }
    }
    Err(NativeError::new(
        "native_step_limit",
        "The source used too many continuation steps.",
    ))
}

unsafe extern "C" fn invoke(host: *const HostApi, input: *const u8, length: usize) -> Buffer {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if host.is_null() || input.is_null() || length == 0 || length > MAX_MESSAGE {
            return Err(NativeError::new(
                "input_invalid",
                "The source input or host API is invalid.",
            ));
        }
        let host = unsafe { &*host };
        if host.version != ABI_VERSION || host.size < HOST_API_SIZE {
            return Err(NativeError::new(
                "host_abi_invalid",
                "The native host ABI version is unsupported.",
            ));
        }
        let bytes = unsafe { std::slice::from_raw_parts(input, length) };
        let input: Value = serde_json::from_slice(bytes)
            .map_err(|_| NativeError::new("json_invalid", "The source input is not valid JSON."))?;
        invoke_inner(host, input)
    }));
    let output = match result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => failure(error),
        Err(_) => failure(NativeError::new(
            "native_panic",
            "The source stopped after an internal error.",
        )),
    };
    let mut bytes = serde_json::to_vec(&output).unwrap_or_else(|_| br#"{"ok":false,"error":{"code":"result_invalid","message":"The source result could not be encoded."}}"#.to_vec());
    if bytes.len() > MAX_MESSAGE {
        bytes = serde_json::to_vec(&failure(NativeError::new(
            "source_result_limit",
            "The source result is too large.",
        )))
        .unwrap();
    }
    Buffer::from_vec(bytes)
}

unsafe extern "C" fn release(buffer: Buffer) {
    unsafe { mgread_native_abi::release(buffer) }
}

static SOURCE_API: SourceApi = SourceApi {
    version: ABI_VERSION,
    size: std::mem::size_of::<SourceApi>(),
    invoke,
    release,
};

/// Returns the immutable C ABI v1 table. The table contains only function pointers.
#[unsafe(no_mangle)]
pub extern "C" fn mg_source_get_api_v1() -> *const SourceApi {
    &SOURCE_API
}

#[cfg(test)]
mod tests;
