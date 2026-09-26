//! SDK integration tests use real ephemeral TCP listeners and synthetic upstream
//! media, without internet, Flutter, or claims about a particular player backend.
use super::*;
use axum::{
    Router,
    body::Body,
    http::{HeaderMap, Method, StatusCode},
    response::Response,
    routing::get,
};

fn directory() -> PathBuf {
    let mut bytes = [0; 16];
    getrandom::fill(&mut bytes).unwrap();
    let path = std::env::temp_dir().join(format!("mgread-sdk-{:x}", u128::from_ne_bytes(bytes)));
    std::fs::create_dir(&path).unwrap();
    path
}
fn config(path: PathBuf) -> Config {
    Config {
        plugin_id: "fixture".into(),
        generation: "a".repeat(64),
        cache_dir: path,
        upstream_proxy: None,
        test_mode: true,
    }
}
fn echo(_: &Call<'_>, input: Value) -> Result<Value> {
    Ok(input)
}
fn fetch(call: &Call<'_>, input: Value) -> Result<Value> {
    call.http(&input)
}
fn unpack(buffer: Buffer) -> Value {
    let result = unsafe {
        serde_json::from_slice(std::slice::from_raw_parts(buffer.ptr, buffer.len)).unwrap()
    };
    unsafe {
        mgread_native_abi::release(buffer);
    }
    result
}

#[test]
fn initialization_buffers_cache_isolation_and_shutdown() {
    let path = directory();
    let other = directory();
    let plugin = PluginInstance::new("fixture");
    let wrong = serde_json::to_vec(
        &json!({"pluginId":"wrong","generation":"a".repeat(64),"cacheDir":path}),
    )
    .unwrap();
    assert_eq!(
        unpack(unsafe { plugin.init(wrong.as_ptr(), wrong.len()) })["ok"],
        false
    );
    assert_eq!(
        unpack(unsafe { plugin.init(std::ptr::null(), 0) })["ok"],
        false
    );
    let input = serde_json::to_vec(
        &json!({"pluginId":"fixture","generation":"a".repeat(64),"cacheDir":path}),
    )
    .unwrap();
    let ready = unpack(unsafe { plugin.init(input.as_ptr(), input.len()) });
    assert_eq!(ready["ok"], true);
    assert_eq!(
        unpack(unsafe { plugin.init(input.as_ptr(), input.len()) })["ok"],
        false
    );
    let context = plugin.context.lock().unwrap().clone().unwrap();
    context.cache.write("../secret", "first").unwrap();
    context.cache.write("../secret", "second").unwrap();
    assert_eq!(
        cache::Cache::open(&path)
            .unwrap()
            .read("../secret")
            .unwrap()
            .as_deref(),
        Some("second")
    );
    assert_eq!(
        cache::Cache::open(&other)
            .unwrap()
            .read("../secret")
            .unwrap(),
        None
    );
    assert_eq!(std::fs::read_dir(&path).unwrap().count(), 1);
    assert_eq!(
        unpack(unsafe { plugin.invoke(1, input.as_ptr(), MAX_MESSAGE + 1, echo) })["ok"],
        false
    );
    let port = ready["value"]["port"].as_u64().unwrap() as u16;
    assert_eq!(unpack(plugin.shutdown())["ok"], true);
    assert_eq!(unpack(plugin.shutdown())["ok"], true);
    assert!(std::net::TcpStream::connect(("127.0.0.1", port)).is_err());
    assert_eq!(
        context.invoke(1, json!({}), echo).unwrap_err().code,
        "plugin_closed"
    );
    drop(context);
    drop(plugin);
    std::fs::remove_dir_all(path).unwrap();
    std::fs::remove_dir_all(other).unwrap();
}

async fn upstream(method: Method, headers: HeaderMap, uri: axum::http::Uri) -> Response {
    if uri.path() == "/slow" {
        tokio::time::sleep(Duration::from_secs(10)).await;
    }
    if uri.path() == "/redirect" {
        return Response::builder()
            .status(302)
            .header("location", "/master.m3u8")
            .body(Body::empty())
            .unwrap();
    }
    let (content, mime) = match uri.path() {
        "/master.m3u8" => (
            "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nchild.m3u8\n",
            "application/vnd.apple.mpegurl",
        ),
        "/child.m3u8" | "/audio.m3u8" => (
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n",
            "application/vnd.apple.mpegurl",
        ),
        "/image" => ("0123456789", "image/png"),
        _ => ("0123456789", "video/mp4"),
    };
    let mut response = Response::builder()
        .header("content-type", mime)
        .header("accept-ranges", "bytes")
        .header("etag", "\"fixture\"");
    let mut body = content.to_string();
    let range_allowed = headers.get("if-range").is_none_or(|v| v == "\"fixture\"");
    if range_allowed {
        match headers.get("range").and_then(|v| v.to_str().ok()) {
            Some("bytes=2-5") => {
                response = response.status(206).header("content-range", "bytes 2-5/10");
                body = "2345".into();
            }
            Some("bytes=99-") => {
                response = response.status(416).header("content-range", "bytes */10");
                body.clear();
            }
            _ => {}
        }
    }
    response
        .header("content-length", body.len())
        .body(if method == Method::HEAD {
            Body::empty()
        } else {
            Body::from(body)
        })
        .unwrap()
}
fn start_upstream(context: &Context) -> (String, tokio::task::JoinHandle<()>) {
    let listener = context
        .executor
        .block_on(tokio::net::TcpListener::bind("127.0.0.1:0"))
        .unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let job = context.executor.spawn(async move {
        axum::serve(
            listener,
            Router::new().route("/{*path}", get(upstream).head(upstream)),
        )
        .await
        .unwrap();
    });
    (base, job)
}

#[test]
fn real_resource_http_supports_head_ranges_hls_and_private_tokens() {
    let path = directory();
    let context = Context::open(config(path.clone())).unwrap();
    let (base, upstream) = start_upstream(&context);
    let resources = &context.resources;
    let video = resources.register(json!({"kind":"video","url":format!("{base}/movie"),"headers":{"Authorization":"Bearer upstream-secret"}})).unwrap();
    assert!(!video.contains("secret"));
    assert!(!video.contains("movie"));
    let hls = resources
        .register(json!({"kind":"hls","url":format!("{base}/redirect")}))
        .unwrap();
    let image = resources
        .register(json!({"kind":"image","url":format!("{base}/image")}))
        .unwrap();
    context.executor.block_on(async {
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        let head = client.head(&video).send().await.unwrap();
        assert_eq!(head.headers()["content-length"], "10");
        assert!(head.bytes().await.unwrap().is_empty());
        let partial = client
            .get(&video)
            .header("range", "bytes=2-5")
            .header("if-range", "\"fixture\"")
            .send()
            .await
            .unwrap();
        assert_eq!(partial.status(), 206);
        assert_eq!(partial.headers()["content-range"], "bytes 2-5/10");
        assert_eq!(partial.text().await.unwrap(), "2345");
        let changed = client
            .get(&video)
            .header("range", "bytes=2-5")
            .header("if-range", "\"stale\"")
            .send()
            .await
            .unwrap();
        assert_eq!(changed.status(), 200);
        assert_eq!(changed.bytes().await.unwrap().len(), 10);
        let invalid = client
            .get(&video)
            .header("range", "bytes=99-")
            .send()
            .await
            .unwrap();
        assert_eq!(invalid.status(), 416);
        assert_eq!(invalid.headers()["content-range"], "bytes */10");
        let image = client.get(&image).send().await.unwrap();
        assert_eq!(image.headers()["content-type"], "image/png");
        assert_eq!(
            client
                .get(&video)
                .header("origin", "https://other.example")
                .send()
                .await
                .unwrap()
                .status(),
            403
        );
        assert_eq!(
            client
                .get(video.replace("/fixture/", "/wrong/"))
                .send()
                .await
                .unwrap()
                .status(),
            404
        );
        let master = client.get(&hls).send().await.unwrap().text().await.unwrap();
        assert!(!master.contains(&base));
        assert!(!master.contains("child.m3u8"));
        let child_url = master.lines().find(|l| l.starts_with("http:")).unwrap();
        let child = client
            .get(child_url)
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        assert!(child.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"http://127.0.0.1:"));
        assert!(child.contains("#EXT-X-MAP:URI=\"http://127.0.0.1:"));
        for line in child.lines() {
            let uri = if line.starts_with("http:") {
                Some(line)
            } else {
                line.split("URI=\"")
                    .nth(1)
                    .map(|s| s.split('"').next().unwrap())
            };
            if let Some(uri) = uri {
                assert_eq!(
                    client
                        .get(uri)
                        .send()
                        .await
                        .unwrap()
                        .bytes()
                        .await
                        .unwrap()
                        .len(),
                    10
                );
            }
        }
        assert_eq!(
            client.post(&video).send().await.unwrap().status(),
            StatusCode::METHOD_NOT_ALLOWED
        );
    });
    assert!(
        resources
            .register(json!({"kind":"video","url":"file:///private"}))
            .is_err()
    );
    upstream.abort();
    context.shutdown().unwrap();
    drop(context);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn cancellation_is_concurrent_but_source_invocation_is_serialized() {
    let path = directory();
    let context = Context::open(config(path.clone())).unwrap();
    let (base, upstream) = start_upstream(&context);
    context.cancel(1);
    assert_eq!(
        context.invoke(1, json!({}), echo).unwrap_err().code,
        "cancelled"
    );
    let worker = context.clone();
    let job =
        std::thread::spawn(move || worker.invoke(2, json!({"url":format!("{base}/slow")}), fetch));
    for _ in 0..100 {
        if context.calls.lock().unwrap().active.is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        context.invoke(3, json!({}), echo).unwrap_err().code,
        "runtime_busy"
    );
    context.cancel(2);
    assert_eq!(job.join().unwrap().unwrap_err().code, "cancelled");
    assert!(context.invoke(4, json!({}), echo).is_ok());
    upstream.abort();
    context.shutdown().unwrap();
    drop(context);
    std::fs::remove_dir_all(path).unwrap();
}
