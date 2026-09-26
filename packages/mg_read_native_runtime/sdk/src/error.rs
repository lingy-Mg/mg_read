//! Bounded source errors. Never include upstream credentials, URLs or local paths.
use serde_json::{Value, json};

#[derive(Debug)]
pub struct Error {
    pub code: String,
    pub message: String,
}
pub type Result<T> = std::result::Result<T, Error>;
impl Error {
    pub fn new(code: &str, message: &str) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
    pub fn envelope(&self) -> Value {
        json!({"ok":false,"error":{"code":self.code,"message":self.message}})
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}
impl std::error::Error for Error {}
impl From<std::io::Error> for Error {
    fn from(_: std::io::Error) -> Self {
        Self::new("storage_error", "Plugin storage operation failed")
    }
}
impl From<serde_json::Error> for Error {
    fn from(_: serde_json::Error) -> Self {
        Self::new("invalid_format", "Invalid source JSON")
    }
}
pub fn invalid(message: &str) -> Error {
    Error::new("invalid_format", message)
}
pub fn cancelled() -> Error {
    Error::new("cancelled", "Source call cancelled")
}
