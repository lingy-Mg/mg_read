//! Native Alice source. A bootstrap-only ABI starts its HTTP service inside the
//! shared worker. Each HTTP request owns its async source state and upstream I/O.
//! Parsing is pure; no host callback, allocator or call-id crosses the ABI.
mod parsing;
mod source;

use mgread_native_abi::{InitResult, MAX_MESSAGE};
use mgread_native_sdk::{Call, PluginInstance};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};
use std::{future::Future, pin::Pin};

const SOURCE_ID: &str = "org.mgread.aisishuwu.native";
const SOURCE_VERSION: &str = "0.3.0";
const BODY_LIMIT: usize = 4 * 1024 * 1024;
const REQUEST_LIMIT: usize = 128;
const STEPS_LIMIT: usize = 128;
const HTTP_BATCH_LIMIT: usize = 4;

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

#[cfg(test)]
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

// Source-local test seam; production uses the statically linked SDK directly.
type HttpFuture<'a> = Pin<Box<dyn Future<Output = Result<Value, NativeError>> + Send + 'a>>;
trait SourceIo: Sync {
    fn cancelled(&self) -> bool;
    fn http<'a>(&'a self, request: &'a Value) -> HttpFuture<'a>;
    fn read(&self, key: &str) -> Result<Option<String>, NativeError>;
    fn write(&self, key: &str, value: &str) -> Result<(), NativeError>;
    fn remove(&self, key: &str) -> Result<(), NativeError>;
}
fn sdk_error(error: mgread_native_sdk::error::Error) -> NativeError {
    NativeError::new(error.code, error.message)
}
impl SourceIo for Call {
    fn cancelled(&self) -> bool {
        Call::cancelled(self)
    }
    fn http<'a>(&'a self, request: &'a Value) -> HttpFuture<'a> {
        Box::pin(async move { Call::http(self, request).await.map_err(sdk_error) })
    }
    fn read(&self, key: &str) -> Result<Option<String>, NativeError> {
        self.cache().read(key).map_err(sdk_error)
    }
    fn write(&self, key: &str, value: &str) -> Result<(), NativeError> {
        self.cache().write(key, value).map_err(sdk_error)
    }
    fn remove(&self, key: &str) -> Result<(), NativeError> {
        self.cache().remove(key).map_err(sdk_error)
    }
}

fn check_cancelled(host: &dyn SourceIo) -> Result<(), NativeError> {
    if host.cancelled() {
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
    Ok(format!("aisishuwu-native/v2/{hex}.json"))
}

fn cached_result(
    host: &dyn SourceIo,
    method: &str,
    request: &Value,
) -> Result<Option<Value>, NativeError> {
    let path = cache_path(method, request)?;
    let value = match host.read(&path) {
        Ok(value) => value,
        Err(error) if error.code == "cancelled" => return Err(error),
        Err(_) => return Ok(None),
    };
    let Some(text) = value else {
        return Ok(None);
    };
    let record: Value = match serde_json::from_str(&text) {
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
        let _ = host.remove(&path);
        Ok(None)
    }
}

fn store_result(host: &dyn SourceIo, method: &str, request: &Value, value: &Value) {
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
    let _ = host.write(&path, &text);
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

async fn http_response(host: &dyn SourceIo, request: &Value) -> Result<Value, NativeError> {
    check_cancelled(host)?;
    let url = checked_http_url(request)?;
    let headers = request.get("headers").cloned().unwrap_or_else(|| json!({}));
    let value = host.http(&json!({"url":url,"headers":headers})).await;
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

async fn invoke_inner(host: &dyn SourceIo, input: Value) -> Result<Value, NativeError> {
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
                    responses.push(http_response(host, request).await?);
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

static INSTANCE: PluginInstance = PluginInstance::new(SOURCE_ID);
fn handle(call: Call, input: Value) -> mgread_native_sdk::SourceFuture {
    Box::pin(async move {
        invoke_inner(&call, input)
            .await
            .map(|result| result["value"].clone())
            .map_err(|error| mgread_native_sdk::error::Error::new(&error.code, &error.message))
    })
}
/// # Safety
/// The host lends valid UTF-8 JSON until this function returns. No host pointers
/// or allocations are retained; subsequent communication is exclusively HTTP.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mg_source_init_v3(input: *const u8, length: usize) -> InitResult {
    unsafe { INSTANCE.init(input, length, handle) }
}
#[cfg(test)]
mod tests;
