use super::*;
use std::collections::BTreeMap;
use std::ffi::c_void;

#[derive(Default)]
struct FixtureHost {
    cancelled: bool,
    incomplete_catalog: bool,
    long_content: bool,
    cache: BTreeMap<String, String>,
    http_calls: Vec<String>,
}

unsafe extern "C" fn fixture_call(context: *mut c_void, input: *const u8, length: usize) -> Buffer {
    let result = (|| {
        if context.is_null() || input.is_null() || length > MAX_MESSAGE {
            return json!({"ok":false,"error":{"code":"fixture_input_invalid"}});
        }
        let host = unsafe { &mut *(context as *mut FixtureHost) };
        let request: Value =
            match serde_json::from_slice(unsafe { std::slice::from_raw_parts(input, length) }) {
                Ok(request) => request,
                Err(_) => return json!({"ok":false,"error":{"code":"fixture_json_invalid"}}),
            };
        let value = match request["op"].as_str().unwrap_or("") {
            "cancelled" => json!(host.cancelled),
            "http" => {
                let url = request["url"].as_str().unwrap_or_default().to_string();
                host.http_calls.push(url.clone());
                let parsed = url::Url::parse(&url).unwrap();
                let body = if parsed.path().starts_with("/novel/") {
                    detail_html(
                        parsed
                            .path()
                            .trim_start_matches("/novel/")
                            .trim_end_matches(".html"),
                    )
                } else if parsed.path().starts_with("/other/chapters/") {
                    catalog_html(
                        host.incomplete_catalog,
                        parsed.query().unwrap_or("").contains("page=2"),
                    )
                } else if parsed.path().starts_with("/book/") && host.long_content {
                    format!(
                        "<h1>长章节</h1><div class='read-content'><p>{}</p></div>",
                        "长内容".repeat(180_000)
                    )
                } else if parsed.path().starts_with("/book/") {
                    "<h1>测试章节</h1><div class='read-content'><p>第一段。</p><script>广告脚本</script><p>第二段。</p></div>".to_string()
                } else {
                    list_html()
                };
                json!({"body":body,"status":200,"headers":{"content-type":"text/html"}})
            }
            "storage.read" => {
                let path = request["path"].as_str().unwrap_or_default();
                json!(host.cache.get(path).cloned())
            }
            "storage.write" => {
                let path = request["path"].as_str().unwrap_or_default().to_string();
                if let Some(value) = request["value"].as_str() {
                    host.cache.insert(path, value.to_string());
                }
                json!(true)
            }
            "storage.remove" => {
                let path = request["path"].as_str().unwrap_or_default();
                host.cache.remove(path);
                json!(true)
            }
            "log" => json!(true),
            _ => return json!({"ok":false,"error":{"code":"fixture_op_unsupported"}}),
        };
        json!({"ok":true,"value":value})
    })();
    Buffer::from_vec(serde_json::to_vec(&result).unwrap())
}

unsafe extern "C" fn fixture_release(buffer: Buffer) {
    unsafe { mgread_native_abi::release(buffer) }
}

fn host_api(host: &mut FixtureHost) -> HostApi {
    HostApi {
        version: ABI_VERSION,
        size: std::mem::size_of::<HostApi>(),
        context: host as *mut FixtureHost as *mut c_void,
        call: fixture_call,
        release: fixture_release,
    }
}

fn invoke_fixture(host: &HostApi, input: &[u8]) -> Value {
    let api = unsafe { &*mg_source_get_api_v1() };
    let output = unsafe { (api.invoke)(host, input.as_ptr(), input.len()) };
    assert!(!output.ptr.is_null());
    assert!(output.len <= MAX_MESSAGE);
    let value =
        serde_json::from_slice(unsafe { std::slice::from_raw_parts(output.ptr, output.len) })
            .unwrap();
    unsafe { (api.release)(output) };
    value
}

fn call(host: &HostApi, method: &str, request: Value) -> Value {
    let input = serde_json::to_vec(&json!({"method":method,"request":request})).unwrap();
    invoke_fixture(host, &input)
}

fn detail_html(id: &str) -> String {
    format!("<h1 class='novel_title'>测试图书{id}</h1><div class='pic'><img src='https://img.321cdn.com/cover.jpg'></div>
      <div class='novel_info'><p>作者：<a href='/search.html?f=author'>测试作者</a></p><p>字数：1.2万 章节：3</p>
      <p>状态：连载</p><p>热度：3万 收藏：20</p><a href='/lists/71.html'>科幻</a></div><div class='jianjie'><p>测试简介</p></div>")
}

fn list_html() -> String {
    let categories = (1..=50)
        .map(|n| format!("<a href='/lists/{n}.html'>分类{n}</a>"))
        .collect::<String>();
    format!("<div class='innerss'><div class='title'>热门推荐小说</div><div class='details'><ul class='item-list'><li><a class='titles'>推荐一</a></li><li><a class='titles'>推荐二</a></li></ul></div></div>{categories}<div class='list-group-item'><a href='/novel/1.html'>测试图书1</a></div>
      <div class='list-group-item'><a href='/novel/2.html'>测试图书2</a></div><a rel='next' href='?page=2'>下一页</a>")
}

fn catalog_html(incomplete: bool, second: bool) -> String {
    if incomplete {
        return "<div class='book_newchap'><div class='tit'>全3章</div></div><div class='mulu_list'><a href='/book/1/1.html'>第一章</a></div>".to_string();
    }
    let ids: &[usize] = if second { &[2, 3] } else { &[1, 2] };
    let chapters = ids
        .iter()
        .map(|n| format!("<a href='/book/1/{n}.html'>第{n}章</a>"))
        .collect::<String>();
    let next = if second {
        ""
    } else {
        "<a rel='next' href='?page=2'>下一页</a>"
    };
    format!(
        "<div class='book_newchap'><div class='tit'>全3章</div></div><div class='mulu_list'>{chapters}</div>{next}"
    )
}

#[test]
fn exports_abi_v1_and_projects_fixture_capabilities_without_node() {
    let api = unsafe { &*mg_source_get_api_v1() };
    assert_eq!(api.version, 1);
    assert_eq!(api.size, std::mem::size_of::<SourceApi>());
    let mut fixture = FixtureHost::default();
    let host = host_api(&mut fixture);

    let detail = call(&host, "getDetail", json!({"id":"novel:1"}));
    assert_eq!(detail["ok"], true);
    assert_eq!(detail["value"]["wordCount"], 12000);
    assert_eq!(detail["value"]["chapterCount"], 3);
    assert_eq!(
        detail["value"]["coverUrl"]["$resource"]["url"],
        "https://img.321cdn.com/cover.jpg"
    );
    assert_eq!(
        fixture.http_calls.last().map(String::as_str),
        Some("https://www.alicesw.com/novel/1.html")
    );

    let search = call(
        &host,
        "search",
        json!({"query":"测试","cursor":null,"pageSize":2}),
    );
    assert_eq!(search["value"]["items"].as_array().unwrap().len(), 2);
    assert_eq!(search["value"]["nextCursor"], "search-page:2");

    let home = call(
        &host,
        "discover",
        json!({"target":null,"cursor":null,"collectionId":null,"pageSize":2}),
    );
    assert_eq!(home["value"]["kind"], "document");
    let suggestions = call(
        &host,
        "searchSuggestions",
        json!({"cursor":null,"pageSize":2}),
    );
    assert_eq!(suggestions["value"]["items"][0]["query"], "推荐一");
    let chapters = call(&host, "getChapters", json!({"id":"novel:1"}));
    assert_eq!(chapters["value"]["items"].as_array().unwrap().len(), 3);
    assert_eq!(chapters["value"]["items"][0]["order"], 0);
    let content = call(
        &host,
        "getContent",
        json!({"id":"novel:1","chapterId":crate::parsing::chapter_id(&url::Url::parse("https://www.alicesw.com/book/1/1.html").unwrap()).unwrap()}),
    );
    assert_eq!(content["value"]["text"], "第一段。\n\n第二段。");
}

#[test]
fn cache_persists_the_full_result_and_does_not_cache_host_proxy_urls() {
    let mut fixture = FixtureHost::default();
    let host = host_api(&mut fixture);
    let request = json!({"id":"novel:7"});
    let first = call(&host, "getDetail", request.clone());
    let fetches = fixture.http_calls.len();
    assert!(fixture.cache.len() == 1);
    let cached_text = fixture.cache.values().next().unwrap();
    assert!(cached_text.contains("$resource"));
    assert!(!cached_text.contains("127.0.0.1"));
    let second = call(&host, "getDetail", request);
    assert_eq!(first, second);
    assert_eq!(fixture.http_calls.len(), fetches);
}

#[test]
fn host_cancellation_stops_before_network_io_and_bad_abi_inputs_are_enveloped() {
    let mut fixture = FixtureHost {
        cancelled: true,
        ..FixtureHost::default()
    };
    let host = host_api(&mut fixture);
    let cancelled = call(&host, "getDetail", json!({"id":"novel:1"}));
    assert_eq!(cancelled["error"]["code"], "cancelled");
    assert!(fixture.http_calls.is_empty());

    let bad_json = invoke_fixture(&host, b"{");
    assert_eq!(bad_json["error"]["code"], "json_invalid");
    let api = unsafe { &*mg_source_get_api_v1() };
    let too_large = unsafe { (api.invoke)(&host, b"x".as_ptr(), MAX_MESSAGE + 1) };
    let too_large_json: Value =
        serde_json::from_slice(unsafe { std::slice::from_raw_parts(too_large.ptr, too_large.len) })
            .unwrap();
    assert_eq!(too_large_json["error"]["code"], "input_invalid");
    unsafe { (api.release)(too_large) };

    let null_input = unsafe { (api.invoke)(&host, std::ptr::null(), 0) };
    let null_input_json: Value = serde_json::from_slice(unsafe {
        std::slice::from_raw_parts(null_input.ptr, null_input.len)
    })
    .unwrap();
    assert_eq!(null_input_json["error"]["code"], "input_invalid");
    unsafe { (api.release)(null_input) };

    let mut wrong_host = host_api(&mut fixture);
    wrong_host.version = ABI_VERSION + 1;
    let wrong_host_output = unsafe { (api.invoke)(&wrong_host, b"{}".as_ptr(), 2) };
    let wrong_host_json: Value = serde_json::from_slice(unsafe {
        std::slice::from_raw_parts(wrong_host_output.ptr, wrong_host_output.len)
    })
    .unwrap();
    assert_eq!(wrong_host_json["error"]["code"], "host_abi_invalid");
    unsafe { (api.release)(wrong_host_output) };
}

#[test]
fn incomplete_catalog_fails_and_long_chapter_text_is_not_truncated() {
    let mut incomplete = FixtureHost {
        incomplete_catalog: true,
        ..FixtureHost::default()
    };
    let incomplete_host = host_api(&mut incomplete);
    let result = call(&incomplete_host, "getChapters", json!({"id":"novel:1"}));
    assert_eq!(result["error"]["code"], "catalog_incomplete");

    let mut long = FixtureHost {
        long_content: true,
        ..FixtureHost::default()
    };
    let long_host = host_api(&mut long);
    let chapter_id = crate::parsing::chapter_id(
        &url::Url::parse("https://www.alicesw.com/book/1/5.html").unwrap(),
    )
    .unwrap();
    let result = call(
        &long_host,
        "getContent",
        json!({"id":"novel:1","chapterId":chapter_id}),
    );
    let text = result["value"]["text"].as_str().unwrap();
    assert_eq!(
        text.chars().filter(|character| *character == '长').count(),
        180_000
    );
}

#[test]
fn invalid_source_identity_is_rejected_before_http() {
    let mut fixture = FixtureHost::default();
    let host = host_api(&mut fixture);
    let result = call(&host, "getDetail", json!({"id":"novel:../other"}));
    assert_eq!(result["error"]["code"], "id_invalid");
    assert!(fixture.http_calls.is_empty());
}
