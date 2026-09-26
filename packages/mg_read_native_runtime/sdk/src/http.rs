//! Plugin-owned upstream HTTP. One bounded async client serves source calls and
//! resources. Redirect destinations are checked before following; credentials
//! are stripped on cross-origin redirects. Loopback fixtures require testMode.
use crate::error::{Error, Result, invalid};
use reqwest::{
    Client, Method, Response, Url,
    header::{HeaderMap, HeaderName, HeaderValue},
};
use serde_json::Value;
use std::time::Duration;

pub fn client(proxy: Option<&str>) -> Result<Client> {
    let mut builder = Client::builder().connect_timeout(Duration::from_secs(10))
        .read_timeout(Duration::from_secs(20)).pool_max_idle_per_host(4)
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")
        .redirect(reqwest::redirect::Policy::none());
    if let Some(proxy) = proxy {
        let url = Url::parse(proxy).map_err(|_| invalid("Invalid upstream proxy"))?;
        if !["http", "https", "socks5", "socks5h"].contains(&url.scheme()) {
            return Err(invalid("Unsupported upstream proxy"));
        }
        builder = builder
            .proxy(reqwest::Proxy::all(proxy).map_err(|_| invalid("Invalid upstream proxy"))?);
    }
    builder
        .build()
        .map_err(|_| Error::new("init_failed", "Plugin HTTP client could not start"))
}
pub fn check_url(value: &str, test_mode: bool) -> Result<Url> {
    let url = Url::parse(value).map_err(|_| invalid("Invalid upstream URL"))?;
    let host = url
        .host_str()
        .ok_or_else(|| invalid("Missing upstream host"))?;
    if !["http", "https"].contains(&url.scheme())
        || !url.username().is_empty()
        || url.password().is_some()
        || (!test_mode
            && (host == "localhost"
                || host == "[::1]"
                || host
                    .parse::<std::net::Ipv4Addr>()
                    .is_ok_and(|a| a.is_loopback() || a.is_unspecified())))
    {
        return Err(invalid("Unsupported upstream URL"));
    }
    Ok(url)
}
pub fn headers(value: &Value) -> Result<HeaderMap> {
    let mut headers = HeaderMap::new();
    if value.is_null() {
        return Ok(headers);
    }
    let values = value
        .as_object()
        .filter(|v| v.len() <= 32)
        .ok_or_else(|| invalid("Invalid upstream headers"))?;
    for (key, value) in values {
        let name = HeaderName::try_from(key).map_err(|_| invalid("Invalid header name"))?;
        if ["host", "connection", "content-length", "transfer-encoding"].contains(&name.as_str()) {
            return Err(invalid("Restricted header"));
        }
        let value = value
            .as_str()
            .filter(|s| s.len() <= 8192)
            .ok_or_else(|| invalid("Invalid header value"))?;
        headers.insert(
            name,
            HeaderValue::try_from(value).map_err(|_| invalid("Invalid header value"))?,
        );
    }
    Ok(headers)
}
pub async fn open(
    client: &Client,
    method: Method,
    mut url: Url,
    mut headers: HeaderMap,
    test_mode: bool,
) -> Result<Response> {
    for redirect in 0..=5 {
        let response = client
            .request(method.clone(), url.clone())
            .headers(headers.clone())
            .send()
            .await
            .map_err(|_| Error::new("network_error", "Plugin upstream request failed"))?;
        if !response.status().is_redirection() || response.status().as_u16() == 304 {
            return Ok(response);
        }
        if redirect == 5 {
            return Err(invalid("Too many upstream redirects"));
        }
        let location = response
            .headers()
            .get("location")
            .and_then(|v| v.to_str().ok())
            .ok_or_else(|| invalid("Missing redirect location"))?;
        let next = check_url(
            url.join(location)
                .map_err(|_| invalid("Invalid redirect"))?
                .as_str(),
            test_mode,
        )?;
        if next.origin() != url.origin() {
            for name in ["authorization", "cookie", "proxy-authorization"] {
                headers.remove(name);
            }
        }
        url = next;
    }
    unreachable!()
}
pub async fn bounded_body(mut response: Response, limit: usize) -> Result<Vec<u8>> {
    if response
        .content_length()
        .is_some_and(|len| len > limit as u64)
    {
        return Err(invalid("Upstream body exceeds its limit"));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| Error::new("network_error", "Upstream body failed"))?
    {
        if bytes.len() + chunk.len() > limit {
            return Err(invalid("Upstream body exceeds its limit"));
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}
