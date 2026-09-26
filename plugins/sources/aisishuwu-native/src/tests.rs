use super::*;
use std::cell::RefCell;
use std::collections::BTreeMap;

#[derive(Default)]
struct FixtureHost {
    cancelled: bool,
    incomplete_catalog: bool,
    long_content: bool,
    cache: RefCell<BTreeMap<String, String>>,
    http_calls: RefCell<Vec<String>>,
}

impl SourceIo for FixtureHost {
    fn cancelled(&self) -> bool {
        self.cancelled
    }
    fn http(&self, request: &Value) -> Result<Value, NativeError> {
        let url = request["url"].as_str().unwrap_or_default().to_string();
        self.http_calls.borrow_mut().push(url.clone());
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
                self.incomplete_catalog,
                parsed.query().unwrap_or("").contains("page=2"),
            )
        } else if parsed.path().starts_with("/book/") && self.long_content {
            format!(
                "<h1>长章节</h1><div class='read-content'><p>{}</p></div>",
                "长内容".repeat(180_000)
            )
        } else if parsed.path().starts_with("/book/") {
            "<h1>测试章节</h1><div class='read-content'><p>第一段。</p><script>广告脚本</script><p>第二段。</p></div>".to_string()
        } else {
            list_html()
        };
        Ok(json!({"body":body,"status":200,"headers":{"content-type":"text/html"}}))
    }
    fn read(&self, path: &str) -> Result<Option<String>, NativeError> {
        Ok(self.cache.borrow().get(path).cloned())
    }
    fn write(&self, path: &str, value: &str) -> Result<(), NativeError> {
        self.cache
            .borrow_mut()
            .insert(path.to_owned(), value.to_owned());
        Ok(())
    }
    fn remove(&self, path: &str) -> Result<(), NativeError> {
        self.cache.borrow_mut().remove(path);
        Ok(())
    }
}
fn host_api(host: &FixtureHost) -> &FixtureHost {
    host
}
fn call(host: &FixtureHost, method: &str, request: Value) -> Value {
    invoke_inner(host, json!({"method":method,"request":request})).unwrap_or_else(failure)
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
fn exports_abi_v2_and_projects_fixture_capabilities_without_node() {
    let api = unsafe { &*mg_source_get_api_v2() };
    assert_eq!(api.version, 2);
    assert_eq!(api.size, std::mem::size_of::<SourceApi>());
    let fixture = FixtureHost::default();
    let host = host_api(&fixture);

    let detail = call(&host, "getDetail", json!({"id":"novel:1"}));
    assert_eq!(detail["ok"], true);
    assert_eq!(detail["value"]["wordCount"], 12000);
    assert_eq!(detail["value"]["chapterCount"], 3);
    assert_eq!(
        detail["value"]["coverUrl"]["$resource"]["url"],
        "https://img.321cdn.com/cover.jpg"
    );
    assert_eq!(
        fixture.http_calls.borrow().last().map(String::as_str),
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
    let fixture = FixtureHost::default();
    let host = host_api(&fixture);
    let request = json!({"id":"novel:7"});
    let first = call(&host, "getDetail", request.clone());
    let fetches = fixture.http_calls.borrow().len();
    assert!(fixture.cache.borrow().len() == 1);
    let cache = fixture.cache.borrow();
    let cached_text = cache.values().next().unwrap();
    assert!(cached_text.contains("$resource"));
    assert!(!cached_text.contains("127.0.0.1"));
    let second = call(&host, "getDetail", request);
    assert_eq!(first, second);
    assert_eq!(fixture.http_calls.borrow().len(), fetches);
}

#[test]
fn cancellation_stops_before_network_io() {
    let fixture = FixtureHost {
        cancelled: true,
        ..FixtureHost::default()
    };
    let host = host_api(&fixture);
    let cancelled = call(&host, "getDetail", json!({"id":"novel:1"}));
    assert_eq!(cancelled["error"]["code"], "cancelled");
    assert!(fixture.http_calls.borrow().is_empty());
}

#[test]
fn incomplete_catalog_fails_and_long_chapter_text_is_not_truncated() {
    let incomplete = FixtureHost {
        incomplete_catalog: true,
        ..FixtureHost::default()
    };
    let incomplete_host = host_api(&incomplete);
    let result = call(&incomplete_host, "getChapters", json!({"id":"novel:1"}));
    assert_eq!(result["error"]["code"], "catalog_incomplete");

    let long = FixtureHost {
        long_content: true,
        ..FixtureHost::default()
    };
    let long_host = host_api(&long);
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
    let fixture = FixtureHost::default();
    let host = host_api(&fixture);
    let result = call(&host, "getDetail", json!({"id":"novel:../other"}));
    assert_eq!(result["error"]["code"], "id_invalid");
    assert!(fixture.http_calls.borrow().is_empty());
}
