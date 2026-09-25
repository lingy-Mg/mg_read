//! Native Alice routing and output projection. Continuations are private to one
//! invocation and are driven synchronously by the C ABI adapter in `lib.rs`.
use crate::parsing::*;
use serde_json::{Value, json};
use std::collections::HashSet;
use url::Url;

fn string<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value[key].as_str().ok_or("request_invalid")
}
fn result(value: Value) -> Value {
    json!({"kind":"result","value":value})
}
fn fetch(url: &str, state: Value) -> Value {
    json!({"kind":"http","requests":[http_request(url, false)],"state":state})
}
fn http_request(url: &str, optional: bool) -> Value {
    json!({"url":url,"optional":optional,"headers":{"Accept":"text/html,application/xhtml+xml", "Accept-Language":"zh-CN,zh;q=0.9", "Referer":ORIGIN}})
}
fn cursor(value: &Value, prefix: &str) -> Result<u64> {
    if value.is_null() {
        return Ok(1);
    }
    let n = value
        .as_str()
        .and_then(|v| v.strip_prefix(prefix))
        .and_then(|v| v.parse::<u64>().ok())
        .ok_or("cursor_invalid")?;
    if n == 0 || n > 10000 {
        return Err("cursor_invalid");
    }
    Ok(n)
}
fn size(request: &Value) -> Result<usize> {
    let n = request["pageSize"].as_u64().ok_or("page_size_invalid")?;
    if n == 0 {
        return Err("page_size_invalid");
    }
    Ok(n.min(50) as usize)
}

pub fn dispatch(input: Value) -> Result<Value> {
    let method = string(&input, "method")?;
    let request = &input["request"];
    let state = &input["state"];
    if state.is_null() {
        return start(method, request);
    }
    if state["stage"] == "hydrate" {
        return hydrate_response(state.clone(), &input["responses"]);
    }
    let body = input["responses"][0]["body"]
        .as_str()
        .ok_or("response_invalid")?;
    let document = page(body)?;
    match method {
        "getDetail" => Ok(result(detail(&document, string(request, "id")?)?)),
        "getContent" => Ok(result(content(&document, string(request, "chapterId")?)?)),
        "getChapters" => catalog_response(state.clone(), &document),
        "searchSuggestions" => {
            let mut seen = HashSet::new();
            let mut suggestions = Vec::new();
            for section in document.select(&selector(".innerss")) {
                if text(section, ".title").is_none_or(|s| s.trim() != "热门推荐小说") {
                    continue;
                }
                for link in section.select(&selector(".details ul.item-list > li a.titles")) {
                    let title = txt(link);
                    if !title.is_empty() && seen.insert(title.clone()) {
                        suggestions.push(json!({"query":title,"metric":null}));
                    }
                }
            }
            suggestions.truncate(size(request)?);
            Ok(result(json!({"items":suggestions,"nextCursor":null})))
        }
        "search" | "discover" => list_response(method, request, state, &document),
        _ => Err("method_unsupported"),
    }
}

fn start(method: &str, request: &Value) -> Result<Value> {
    let mut state = json!({"stage":"parse"});
    let url = match method {
        "getDetail" => format!("{ORIGIN}/novel/{}.html", novel_id(string(request, "id")?)?),
        "getContent" => {
            novel_id(string(request, "id")?)?;
            chapter_url(string(request, "chapterId")?)?.to_string()
        }
        "getChapters" => {
            let id = novel_id(string(request, "id")?)?;
            state = json!({"stage":"catalog","id":id,"page":1,"pages":1,"items":[],"total":null});
            format!("{ORIGIN}/other/chapters/id/{id}.html")
        }
        "search" => {
            size(request)?;
            let q = string(request, "query")?;
            if q.trim().is_empty() || q.len() > 512 {
                return Err("query_invalid");
            }
            let n = cursor(&request["cursor"], "search-page:")?;
            state["page"] = json!(n);
            let mut url = Url::parse(&format!("{ORIGIN}/search.html")).unwrap();
            url.query_pairs_mut()
                .append_pair("q", q)
                .append_pair("f", "_all")
                .append_pair("p", &n.to_string());
            url.to_string()
        }
        "searchSuggestions" => {
            size(request)?;
            if cursor(&request["cursor"], "search-suggestions-page:")? > 1 {
                return Ok(result(json!({"items":[],"nextCursor":null})));
            }
            format!("{ORIGIN}/")
        }
        "discover" => {
            size(request)?;
            if request["target"].is_null() {
                if !request["cursor"].is_null() || !request["collectionId"].is_null() {
                    return Err("discovery_invalid");
                }
                format!("{ORIGIN}/")
            } else {
                let target = string(request, "target")?;
                if let Some(id) = target.strip_prefix("category:") {
                    digits(id)?;
                    let n = cursor(&request["cursor"], "category-page:")?;
                    let collection = format!("category-books:{id}");
                    if !request["collectionId"].is_null()
                        && (request["collectionId"] != collection || request["cursor"].is_null())
                    {
                        return Err("discovery_invalid");
                    }
                    state["page"] = json!(n);
                    format!("{ORIGIN}/lists/{id}.html?page={n}")
                } else {
                    if !request["cursor"].is_null() || !request["collectionId"].is_null() {
                        return Err("discovery_invalid");
                    }
                    let suffix = match target {
                        "ranking:day" => "hits_day",
                        "ranking:week" => "hits_week",
                        "ranking:month" => "hits_month",
                        "ranking:total" => "hits",
                        _ => return Err("target_invalid"),
                    };
                    format!("{ORIGIN}/other/rank_hits/order/{suffix}.html")
                }
            }
        }
        _ => return Err("method_unsupported"),
    };
    state["url"] = json!(url);
    Ok(fetch(&url, state))
}

fn catalog_response(mut state: Value, document: &scraper::Html) -> Result<Value> {
    let parsed = catalog(document)?;
    let items = state["items"].as_array_mut().ok_or("state_invalid")?;
    let mut seen: HashSet<String> = items
        .iter()
        .filter_map(|v| v["id"].as_str().map(str::to_string))
        .collect();
    for mut item in parsed {
        if seen.insert(string(&item, "id")?.to_string()) {
            item["order"] = json!(items.len());
            items.push(item);
        }
    }
    if items.len() > 5000 {
        return Err("catalog_limit");
    }
    if let Some(total) = catalog_total(document) {
        state["total"] = json!(total);
    }
    let page = state["page"].as_u64().ok_or("state_invalid")?;
    if let Some(next) = next_page(document, string(&state, "url")?, page)? {
        let pages = state["pages"].as_u64().ok_or("state_invalid")? + 1;
        if pages > 64 {
            return Err("catalog_page_limit");
        }
        let url = format!(
            "{ORIGIN}/other/chapters/id/{}.html?page={next}",
            string(&state, "id")?
        );
        state["url"] = json!(url);
        state["page"] = json!(next);
        state["pages"] = json!(pages);
        return Ok(fetch(&url, state));
    }
    if let Some(total) = state["total"].as_u64() {
        if total as usize != state["items"].as_array().ok_or("state_invalid")?.len() {
            return Err("catalog_incomplete");
        }
    }
    Ok(result(json!({"items":state["items"]})))
}

fn list_response(
    method: &str,
    request: &Value,
    state: &Value,
    document: &scraper::Html,
) -> Result<Value> {
    let home = method == "discover" && request["target"].is_null();
    let ranking = request["target"]
        .as_str()
        .is_some_and(|s| s.starts_with("ranking:"));
    let items = books(
        document,
        string(state, "url")?,
        if home {
            12
        } else if ranking {
            50
        } else {
            size(request)?
        },
    );
    let next = if home || ranking {
        None
    } else {
        next_page(
            document,
            string(state, "url")?,
            state["page"].as_u64().unwrap_or(1),
        )?
    };
    let mut categories = Vec::new();
    let mut seen = HashSet::new();
    if home {
        for link in document.select(&selector("a[href*='/lists/']")) {
            let Some(url) = link
                .value()
                .attr("href")
                .and_then(|v| source_url(v, ORIGIN).ok())
            else {
                continue;
            };
            let Some(id) = url
                .path()
                .strip_prefix("/lists/")
                .and_then(|v| v.strip_suffix(".html"))
                .and_then(|v| digits(v).ok())
            else {
                continue;
            };
            let title = txt(link);
            if title.is_empty() || !seen.insert(id.to_string()) {
                continue;
            }
            categories.push(json!({"id":format!("category:{id}"),"target":format!("category:{id}"),"title":title,"count":null,"url":null,"icon":"category"}));
            if categories.len() == 96 {
                break;
            }
        }
    }
    hydrate(
        json!({"stage":"hydrate","method":method,"request":request,"items":items,"offset":0,"next":next,"categories":categories}),
    )
}
fn hydrate(mut state: Value) -> Result<Value> {
    let offset = state["offset"].as_u64().ok_or("state_invalid")? as usize;
    let items = state["items"].as_array().ok_or("state_invalid")?;
    if offset >= items.len() {
        return finish(state);
    }
    let requests: Vec<_> = items
        .iter()
        .skip(offset)
        .take(4)
        .map(|item| http_request(item["url"].as_str().unwrap(), true))
        .collect();
    state["batch"] = json!(requests.len());
    Ok(json!({"kind":"http","requests":requests,"state":state}))
}
fn hydrate_response(mut state: Value, responses: &Value) -> Result<Value> {
    let offset = state["offset"].as_u64().ok_or("state_invalid")? as usize;
    let batch = state["batch"].as_u64().ok_or("state_invalid")? as usize;
    if responses.as_array().is_none_or(|r| r.len() != batch) {
        return Err("response_invalid");
    }
    for index in 0..batch {
        if let Some(body) = responses[index]["body"].as_str() {
            if let Ok(parsed) = page(body).and_then(|doc| {
                detail(&doc, state["items"][offset + index]["id"].as_str().unwrap())
            }) {
                let mut parsed = parsed;
                parsed.as_object_mut().unwrap().remove("aliases");
                parsed.as_object_mut().unwrap().remove("catalogUrl");
                if let Some(description) = parsed["description"].as_str() {
                    parsed["description"] =
                        json!(description.chars().take(120).collect::<String>());
                }
                state["items"][offset + index] = parsed;
            }
        }
    }
    state["offset"] = json!(offset + batch);
    hydrate(state)
}
fn collection(id: &str, items: &Value, continuation: Value) -> Value {
    json!({"type":"contentCollection","id":id,"layout":"list","items":discovery_items(items),"continuation":continuation})
}
fn discovery_items(items: &Value) -> Vec<Value> {
    items
        .as_array()
        .unwrap()
        .iter()
        .map(|content| json!({"content":content,"rank":null,"metric":null,"recommendation":null}))
        .collect()
}
fn finish(state: Value) -> Result<Value> {
    let request = &state["request"];
    if state["method"] == "search" {
        return Ok(result(
            json!({"items":state["items"],"totalCount":null,"nextCursor":state["next"].as_u64().map(|n| format!("search-page:{n}"))}),
        ));
    }
    if request["target"].is_null() {
        let mut components = vec![collection("home-books", &state["items"], Value::Null)];
        for (index, categories) in state["categories"]
            .as_array()
            .unwrap()
            .chunks(32)
            .enumerate()
        {
            components.push(json!({"type":"categoryCollection","id":format!("source-categories-{index}"),"layout":"chips","categories":categories}));
        }
        let rankings = [("day","本日排行"),("week","本周排行"),("month","本月排行"),("total","总排行")].iter().map(|(id,title)|
            json!({"id":format!("ranking:{id}"),"title":title,"target":format!("ranking:{id}"),"count":null,"url":null,"icon":"ranking"})).collect::<Vec<_>>();
        components.push(json!({"type":"categoryCollection","id":"source-rankings","layout":"grid","categories":rankings}));
        return Ok(result(
            json!({"kind":"document","document":{"components":components}}),
        ));
    }
    let target = string(request, "target")?;
    let id = if let Some(category) = target.strip_prefix("category:") {
        format!("category-books:{category}")
    } else {
        format!(
            "ranking-books:{}",
            target.strip_prefix("ranking:").ok_or("target_invalid")?
        )
    };
    let continuation = state["next"]
        .as_u64()
        .map(|n| json!({"target":target,"cursor":format!("category-page:{n}")}));
    if !request["collectionId"].is_null() {
        return Ok(result(
            json!({"kind":"append","collectionId":id,"items":discovery_items(&state["items"]),"continuation":continuation}),
        ));
    }
    Ok(result(
        json!({"kind":"document","document":{"components":[collection(&id,&state["items"],json!(continuation))]}}),
    ))
}
