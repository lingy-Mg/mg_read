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
        source_name: "Fixture".into(),
        generation: "a".repeat(64),
        control_token: "b".repeat(64),
        capabilities: vec!["searchSuggestions".into()],
        cache_dir: path,
        upstream_proxy: None,
        test_mode: true,
    }
}
pub(crate) fn echo(_: Call, _: Value) -> SourceFuture {
    Box::pin(async { Ok(json!({"items":[],"nextCursor":null})) })
}
fn fetch(call: Call, input: Value) -> SourceFuture {
    Box::pin(async move {
        if input["request"]["url"].is_string() {
            call.http(&input["request"]).await?;
        }
        Ok(json!({"items":[],"nextCursor":null}))
    })
}
#[test]
fn initialization_cache_isolation_and_shutdown() {
    let path = directory();
    let other = directory();
    let plugin = PluginInstance::new("fixture");
    assert_eq!(unsafe { plugin.init(std::ptr::null(), 0, echo) }.status, 1);
    let input=serde_json::to_vec(&json!({"pluginId":"fixture","sourceName":"Fixture","capabilities":["searchSuggestions"],"generation":"a".repeat(64),"controlToken":"b".repeat(64),"cacheDir":path,"testMode":true})).unwrap();
    let mut invalid_config: Value = serde_json::from_slice(&input).unwrap();
    invalid_config["upstreamProxy"] = json!("invalid proxy");
    let bad = serde_json::to_vec(&invalid_config).unwrap();
    assert_eq!(
        unsafe { plugin.init(bad.as_ptr(), bad.len(), echo) }.status,
        1
    );
    assert!(plugin.context.lock().unwrap().is_none());
    let ready = unsafe { plugin.init(input.as_ptr(), input.len(), echo) };
    assert_eq!(ready.status, 0);
    assert_eq!(
        unsafe { plugin.init(input.as_ptr(), input.len(), echo) }.status,
        1
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
    assert!(
        cache::Cache::open(&other)
            .unwrap()
            .read("../secret")
            .unwrap()
            .is_none()
    );
    assert_eq!(std::fs::read_dir(&path).unwrap().count(), 1);
    context.executor.block_on(async {
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        let response = client
            .post(format!("http://127.0.0.1:{}/shutdown", ready.port))
            .bearer_auth("b".repeat(64))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        tokio::time::timeout(Duration::from_secs(2), context.stop.cancelled())
            .await
            .unwrap();
    });
    context.shutdown();
    context.shutdown();
    assert!(std::net::TcpStream::connect(("127.0.0.1", ready.port)).is_err());
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
fn real_resource_http_supports_head_ranges_hls_and_payloads() {
    let path = directory();
    let context = Context::open(config(path.clone()), echo).unwrap();
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
    context.shutdown();
    drop(context);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn concurrent_http_calls_and_disconnect_cancel_upstream_without_cancel_rpc() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let path = directory();
    let context = Context::open(config(path.clone()), fetch).unwrap();
    let accepted = Arc::new(AtomicUsize::new(0));
    let disconnected = Arc::new(AtomicUsize::new(0));
    context.executor.block_on(async {
        let listener=tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap(); let upstream=listener.local_addr().unwrap();
        let received=accepted.clone(); let closed=disconnected.clone();
        let server=tokio::spawn(async move { loop {
            let (mut socket,_)=listener.accept().await.unwrap(); let received=received.clone(); let closed=closed.clone();
            tokio::spawn(async move { let mut bytes=[0;8192]; let n=socket.read(&mut bytes).await.unwrap(); assert!(n>0); received.fetch_add(1,Ordering::SeqCst);
                loop { match socket.read(&mut bytes).await { Ok(0)|Err(_) => {closed.fetch_add(1,Ordering::SeqCst);break}, _=>{} } }
            });
        }});
        async fn wait(counter:&AtomicUsize,value:usize) { tokio::time::timeout(Duration::from_secs(3),async {while counter.load(Ordering::SeqCst)<value {tokio::time::sleep(Duration::from_millis(5)).await;}}).await.unwrap(); }
        let port=context.resources.port;
        let body=json!({"method":"source.searchSuggestions.v1","params":{"pluginId":"fixture","url":format!("http://{upstream}/slow")}}).to_string();
        let wire=format!("POST /invoke HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}","b".repeat(64),body.len());
        let mut first=tokio::net::TcpStream::connect(("127.0.0.1",port)).await.unwrap(); first.write_all(wire.as_bytes()).await.unwrap();
        let mut second=tokio::net::TcpStream::connect(("127.0.0.1",port)).await.unwrap(); second.write_all(wire.as_bytes()).await.unwrap();
        wait(&accepted,2).await; // Both upstream requests are alive at the same time.
        drop(first); wait(&disconnected,1).await;
        assert_eq!(disconnected.load(Ordering::SeqCst),1); // Other call was not killed.
        let client=reqwest::Client::builder().no_proxy().build().unwrap();
        let response=client.post(format!("http://127.0.0.1:{port}/invoke")).bearer_auth("b".repeat(64)).header("content-type","application/json")
            .body(json!({"method":"source.searchSuggestions.v1","params":{"pluginId":"fixture"}}).to_string()).send().await.unwrap();
        let result:Value=serde_json::from_str(&response.text().await.unwrap()).unwrap(); assert_eq!(result["ok"],true);
        drop(second); wait(&disconnected,2).await; server.abort();
    });
    context.shutdown();
    drop(context);
    std::fs::remove_dir_all(path).unwrap();
}
