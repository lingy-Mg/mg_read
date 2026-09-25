//! Site-owned HTML projection and URL validation. No host IO or persistent state.
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use scraper::{ElementRef, Html, Node, Selector};
use serde_json::{Value, json};
use std::collections::HashSet;
use url::Url;

pub const ORIGIN: &str = "https://www.alicesw.com";
pub type Result<T> = std::result::Result<T, &'static str>;
pub fn selector(css: &str) -> Selector {
    Selector::parse(css).expect("static CSS selector")
}
pub fn txt(element: ElementRef<'_>) -> String {
    element.text().collect::<String>().trim().to_string()
}
pub fn text(root: ElementRef<'_>, css: &str) -> Option<String> {
    root.select(&selector(css)).map(txt).find(|s| !s.is_empty())
}
fn attr(root: ElementRef<'_>, css: &str, name: &str) -> Option<String> {
    root.select(&selector(css))
        .find_map(|e| e.value().attr(name).map(str::to_string))
}
pub fn page(body: &str) -> Result<Html> {
    if body.contains("访问异常，请稍后再试") {
        return Err("source_access_blocked");
    }
    if body.len() > 4 * 1024 * 1024 {
        return Err("html_limit");
    }
    Ok(Html::parse_document(body))
}
pub fn source_url(value: &str, base: &str) -> Result<Url> {
    let url = Url::parse(base)
        .and_then(|b| b.join(value))
        .map_err(|_| "url_invalid")?;
    if url.origin().ascii_serialization() != ORIGIN
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err("url_origin_invalid");
    }
    Ok(url)
}
pub fn digits(value: &str) -> Result<&str> {
    if value.is_empty() || value.len() > 20 || !value.bytes().all(|c| c.is_ascii_digit()) {
        return Err("id_invalid");
    }
    Ok(value)
}
pub fn novel_id(value: &str) -> Result<&str> {
    digits(value.strip_prefix("novel:").ok_or("id_invalid")?)
}
pub fn novel_url_id(url: &Url) -> Option<&str> {
    digits(url.path().strip_prefix("/novel/")?.strip_suffix(".html")?).ok()
}
pub fn chapter_id(url: &Url) -> Result<String> {
    let parts: Vec<_> = url.path().split('/').collect();
    if parts.len() != 4
        || parts[1] != "book"
        || parts[2].is_empty()
        || !parts[3].ends_with(".html")
        || parts[3].len() <= 5
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("chapter_invalid");
    }
    Ok(format!("chapter:{}", URL_SAFE_NO_PAD.encode(url.path())))
}
pub fn chapter_url(id: &str) -> Result<Url> {
    let bytes = URL_SAFE_NO_PAD
        .decode(id.strip_prefix("chapter:").ok_or("chapter_invalid")?)
        .map_err(|_| "chapter_invalid")?;
    let path = String::from_utf8(bytes).map_err(|_| "chapter_invalid")?;
    if !path.starts_with("/book/") {
        return Err("chapter_invalid");
    }
    let url = source_url(&path, ORIGIN)?;
    if chapter_id(&url)? != id {
        return Err("chapter_invalid");
    }
    Ok(url)
}
fn cover(root: ElementRef<'_>, base: &str) -> Value {
    let candidate = attr(root, "meta[property='og:image']", "content").or_else(|| {
        root.select(&selector(".pic img, img.fengmian2, img"))
            .next()
            .and_then(|img| {
                ["data-src", "data-original", "data-lazy-src", "src"]
                    .iter()
                    .find_map(|key| img.value().attr(key).map(str::to_string))
            })
    });
    let Some(url) = candidate.and_then(|v| Url::parse(base).ok()?.join(&v).ok()) else {
        return Value::Null;
    };
    if ![ORIGIN, "https://img.321cdn.com"].contains(&url.origin().ascii_serialization().as_str())
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Value::Null;
    }
    json!({"$resource":{"kind":"image", "url":url.as_str(), "headers":{"Accept":"image/*"}}})
}
fn summary(id: &str, title: &str) -> Value {
    json!({"id":format!("novel:{id}"), "title":title, "contentKind":"novel", "coverOrientation":"portrait",
        "author":null, "url":format!("{ORIGIN}/novel/{id}.html"), "coverUrl":null, "description":null,
        "language":"zh-CN", "status":"unknown", "access":"unknown", "wordCount":null, "chapterCount":null,
        "publishedAt":null, "updatedAt":null, "latestChapter":null, "categories":[], "tags":[], "attributes":[]})
}
pub fn books(document: &Html, base: &str, limit: usize) -> Vec<Value> {
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    // Parse rows first so author/cover/intro survive. Link fallback covers home cards.
    for root in document.select(&selector(
        ".list-group-item, .rec_rullist > ul, .hot-data, .details li, a[href*='/novel/']",
    )) {
        let link = if root.value().name() == "a" {
            Some(root)
        } else {
            root.select(&selector("a[href*='/novel/']"))
                .find(|e| !txt(*e).is_empty())
        };
        let Some(link) = link else {
            continue;
        };
        let Some(url) = link
            .value()
            .attr("href")
            .and_then(|v| source_url(v, base).ok())
        else {
            continue;
        };
        let Some(id) = novel_url_id(&url) else {
            continue;
        };
        let title = txt(link);
        if title.is_empty() || !seen.insert(id.to_string()) {
            continue;
        }
        let mut item = summary(id, &title);
        item["author"] = json!(text(root, "a[href*='f=author'], li.four"));
        item["description"] = json!(text(root, ".content-txt"));
        item["coverUrl"] = cover(root, base);
        if let Some(category) = text(root, ".sev a, a[href*='/lists/']") {
            item["categories"] = json!([category]);
        }
        result.push(item);
        if result.len() == limit {
            break;
        }
    }
    result
}
fn labeled_count(value: &str, label: &str) -> Option<u64> {
    let compact: String = value
        .chars()
        .filter(|c| !c.is_whitespace() && *c != ',')
        .collect();
    let rest = compact.split_once(label)?.1.trim_start_matches(['：', ':']);
    let n: String = rest
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '.')
        .collect();
    let number: f64 = n.parse().ok()?;
    let multiplier = if rest[n.len()..].starts_with('万') {
        10000.0
    } else if rest[n.len()..].starts_with('亿') {
        100000000.0
    } else {
        1.0
    };
    let count = (number * multiplier).round();
    if !count.is_finite() || !(0.0..=9007199254740991.0).contains(&count) {
        return None;
    }
    Some(count as u64)
}
pub fn detail(document: &Html, id: &str) -> Result<Value> {
    let number = novel_id(id)?;
    let root = document.root_element();
    let title = text(root, ".novel_title").ok_or("detail_title_missing")?;
    let mut value = summary(number, &title);
    let info = root
        .select(&selector(".novel_info"))
        .next()
        .ok_or("detail_info_missing")?;
    let stats = txt(info);
    value["author"] = json!(text(info, "a[href*='f=author']"));
    value["description"] = json!(text(root, ".jianjie p").or_else(|| attr(
        root,
        "meta[name='description']",
        "content"
    )));
    value["coverUrl"] = cover(root, ORIGIN);
    value["wordCount"] = json!(labeled_count(&stats, "字数"));
    value["chapterCount"] = json!(labeled_count(&stats, "章节"));
    let status = text(info, "p").unwrap_or_default();
    let status = info
        .select(&selector("p"))
        .map(txt)
        .find(|s| s.contains("状态"))
        .unwrap_or(status);
    value["status"] = json!(if status.contains("连载") || status.contains("更新中") {
        "ongoing"
    } else if status.contains("完结") {
        "completed"
    } else if status.contains("停更") || status.contains("暂停") {
        "hiatus"
    } else {
        "unknown"
    });
    if let Some(category) = text(
        root,
        ".novel_info a[href*='/lists/'], .bread-crumbs a[href*='/lists/']",
    ) {
        value["categories"] = json!([category]);
    }
    let tags: Vec<_> = root
        .select(&selector(".tags_list a[href*='f=tag']"))
        .filter_map(|e| {
            let direct: String = e
                .children()
                .filter_map(|n| n.value().as_text().map(|s| s.text.as_ref()))
                .collect();
            let tag = direct.trim().to_string();
            if tag.is_empty() { None } else { Some(tag) }
        })
        .take(20)
        .collect();
    value["tags"] = json!(tags);
    let attributes = [("heat", "热度"), ("favorites", "收藏")]
        .iter()
        .filter_map(|(key, label)| {
            labeled_count(&stats, label)
                .map(|n| json!({"key":key,"label":label,"value":n.to_string()}))
        })
        .collect::<Vec<_>>();
    value["attributes"] = json!(attributes);
    if let Some(link) = info.select(&selector("a[href*='/book/']")).next() {
        if let Some(url) = link
            .value()
            .attr("href")
            .and_then(|v| source_url(v, ORIGIN).ok())
        {
            if let Ok(chapter) = chapter_id(&url) {
                let title = txt(link);
                if !title.is_empty() {
                    value["latestChapter"] =
                        json!({"id":chapter,"title":title,"url":url.as_str(),"updatedAt":null});
                }
            }
        }
    }
    value["aliases"] = json!([]);
    value["catalogUrl"] = json!(format!("{ORIGIN}/other/chapters/id/{number}.html"));
    Ok(value)
}
pub fn catalog(document: &Html) -> Result<Vec<Value>> {
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    for link in document.select(&selector(".mulu_list a[href*='/book/'], a[href*='/book/']")) {
        let Some(url) = link
            .value()
            .attr("href")
            .and_then(|v| source_url(v, ORIGIN).ok())
        else {
            continue;
        };
        let Ok(id) = chapter_id(&url) else {
            continue;
        };
        let title = txt(link);
        if title.is_empty() || !seen.insert(id.clone()) {
            continue;
        }
        result.push(
            json!({"id":id,"title":title,"order":result.len(),"url":url.as_str(),"volumeTitle":null,
            "wordCount":null,"updatedAt":null,"isLocked":null,"attributes":[]}),
        );
    }
    if result.is_empty() {
        return Err("catalog_empty");
    }
    Ok(result)
}
pub fn catalog_total(document: &Html) -> Option<usize> {
    let title = text(
        document.root_element(),
        ".book_newchap .tit, .mulu_title, .catalog_title",
    )?;
    let after = title.split_once('全')?.1;
    after
        .chars()
        .filter(|c| !c.is_whitespace())
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .parse()
        .ok()
}
pub fn next_page(document: &Html, base: &str, current: u64) -> Result<Option<u64>> {
    for link in document.select(&selector(
        ".pagination a[href], .page a[href], .pages a[href], a[rel='next']",
    )) {
        if link.value().attr("rel") != Some("next")
            && !["下一页", "下页", "next", "›", "»", ">"].contains(&txt(link).as_str())
        {
            continue;
        }
        let url = source_url(link.value().attr("href").ok_or("page_invalid")?, base)?;
        if url.path() != Url::parse(base).map_err(|_| "page_invalid")?.path() {
            return Err("page_path_invalid");
        }
        let page = url
            .query_pairs()
            .find(|(k, _)| k == "page" || k == "p")
            .and_then(|(_, v)| v.parse::<u64>().ok())
            .ok_or("page_invalid")?;
        if page <= current || page > 10000 {
            return Err("page_loop");
        }
        return Ok(Some(page));
    }
    Ok(None)
}
pub fn content(document: &Html, chapter: &str) -> Result<Value> {
    let root = document.root_element();
    let content = root
        .select(&selector(".read-content, .j_readContent, #j_chapterBox"))
        .next()
        .ok_or("content_missing")?;
    let mut output = String::new();
    collect_text(content, &mut output, 0);
    if let Some(start) = output.find("爱丽丝书屋") {
        if let Some(end) = output[start..].find("Copyright") {
            output.replace_range(start..start + end + "Copyright".len(), "");
        }
    }
    let paragraphs: Vec<_> = output
        .lines()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect();
    let text = paragraphs.join("\n\n");
    if text.is_empty() {
        return Err("content_empty");
    }
    Ok(
        json!({"chapterId":chapter,"contentKind":"novel","title":text_or_null(root),"updatedAt":null,"text":text,"pages":[]}),
    )
}
fn text_or_null(root: ElementRef<'_>) -> Option<String> {
    text(root, "h1, .read-title, .book-title")
}
fn collect_text(element: ElementRef<'_>, output: &mut String, depth: usize) {
    if depth > 128 {
        return;
    }
    let name = element.value().name();
    if ["script", "style", "iframe"].contains(&name)
        || element.value().id() == Some("user_ad")
        || element.value().classes().any(|c| {
            [
                "chapter-control",
                "text-head",
                "right-bar-list",
                "left-bar-list",
            ]
            .contains(&c)
        })
    {
        return;
    }
    if name == "br" {
        output.push('\n');
    }
    for child in element.children() {
        if let Node::Text(t) = child.value() {
            output.push_str(t);
        }
        if let Some(child) = ElementRef::wrap(child) {
            collect_text(child, output, depth + 1);
        }
    }
    if ["p", "div"].contains(&name) {
        output.push('\n');
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chapter_ids_roundtrip_and_reject_foreign_paths() {
        let url = source_url("/book/1/2.html", ORIGIN).unwrap();
        assert_eq!(chapter_url(&chapter_id(&url).unwrap()).unwrap(), url);
        assert!(source_url("https://elsewhere.invalid/novel/1.html", ORIGIN).is_err());
        assert!(
            chapter_url(&format!(
                "chapter:{}",
                URL_SAFE_NO_PAD.encode("/search.html")
            ))
            .is_err()
        );
    }
    #[test]
    fn text_removes_ad_elements_and_preserves_paragraphs() {
        let doc = page("<h1>测试</h1><div class='read-content'><p>甲 &amp; 乙</p><script>bad</script><div id='user_ad'>ad</div>丙<br>丁</div>").unwrap();
        assert_eq!(
            content(&doc, "chapter:test").unwrap()["text"],
            "甲 & 乙\n\n丙\n\n丁"
        );
    }
    #[test]
    fn blocked_success_page_is_an_error() {
        assert!(page("访问异常，请稍后再试").is_err());
    }
}
