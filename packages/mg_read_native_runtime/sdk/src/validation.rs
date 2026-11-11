//! Bounded public source contract checks after plugin-owned resource projection. Flutter
//! performs the same final typed decode for Node and native content. Novel text
//! permits 10 MiB before JSON escaping; other content results permit 10 MiB JSON.
use crate::error::{Result, invalid};
use serde_json::Value;
use std::collections::HashSet;

pub(crate) const MAX_NOVEL_TEXT_BYTES: usize = 10 * 1024 * 1024;
const MAX_CONTENT_RESULT_BYTES: usize = 10 * 1024 * 1024;
const MAX_NOVEL_RESULT_BYTES: usize = 6 * MAX_NOVEL_TEXT_BYTES + 64 * 1024;

pub fn validate(method: &str, request: &Value, result: &Value) -> Result<()> {
    if !result.is_object() {
        return Err(invalid("Source result must be an object"));
    }
    let maximum = if method == "getContent" && result["contentKind"] == "novel" {
        MAX_NOVEL_RESULT_BYTES
    } else {
        MAX_CONTENT_RESULT_BYTES
    };
    let bytes = serde_json::to_vec(result)?.len();
    if bytes > maximum {
        return Err(invalid(&format!(
            "Source result exceeds its budget: {bytes} bytes exceeds the {maximum}-byte limit"
        )));
    }
    tree(result, 0)?;
    match method {
        "getDetail" => {
            summary(result)?;
            if result["id"] != request["id"] {
                return Err(invalid("Detail identity mismatch"));
            }
            array(result, "aliases", 64)?;
        }
        "getChapters" => {
            let items = array(result, "items", 5000)?;
            unique(items, "id")?;
            for item in items {
                required(item, "id")?;
                required(item, "title")?;
                if !item["order"].is_u64() {
                    return Err(invalid("Invalid chapter order"));
                }
            }
        }
        "getContent" => {
            if result["chapterId"] != request["chapterId"] {
                return Err(invalid("Content identity mismatch"));
            }
            let pages = array(result, "pages", 5000)?;
            match result["contentKind"].as_str() {
                Some("novel")
                    if result["text"].is_string()
                        && pages.is_empty()
                        && result["media"].is_null() =>
                {
                    let bytes = result["text"].as_str().unwrap().len();
                    if bytes > MAX_NOVEL_TEXT_BYTES {
                        return Err(invalid(&format!(
                            "Novel text exceeds its budget: {bytes} bytes exceeds the {MAX_NOVEL_TEXT_BYTES}-byte limit"
                        )));
                    }
                }
                Some("manga")
                    if result["text"].is_null()
                        && !pages.is_empty()
                        && result["media"].is_null() =>
                {
                    unique(pages, "id")?;
                    for (index, page) in pages.iter().enumerate() {
                        required(page, "url")?;
                        if page["index"].as_u64() != Some(index as u64)
                            || page["resourcePolicy"] == "durable"
                        {
                            return Err(invalid("Invalid native manga page"));
                        }
                    }
                }
                Some("audio" | "video") if result["text"].is_null() && pages.is_empty() => {
                    let media = &result["media"];
                    required(media, "url")?;
                    if !["audio", "video", "hls"]
                        .contains(&media["resourceType"].as_str().unwrap_or(""))
                        || !["sessionOnly", "refreshable"]
                            .contains(&media["resourcePolicy"].as_str().unwrap_or(""))
                        || !media["headers"].as_object().is_some_and(|h| h.is_empty())
                    {
                        return Err(invalid("Invalid native media resource"));
                    }
                }
                _ => return Err(invalid("Inconsistent native content fields")),
            }
        }

        "search" => {
            let items = array(result, "items", 1000)?;
            unique(items, "id")?;
            for item in items {
                summary(item)?;
            }
            nullable(result, "nextCursor")?;
        }
        "searchSuggestions" => {
            let items = array(result, "items", 50)?;
            unique(items, "query")?;
            for i in items {
                required(i, "query")?;
            }
            nullable(result, "nextCursor")?;
        }
        "discover" => match result["kind"].as_str() {
            Some("document") => {
                array(&result["document"], "components", 128)?;
            }
            Some("append") => {
                array(result, "items", 1000)?;
                if result["collectionId"] != request["collectionId"] {
                    return Err(invalid("Discovery continuation identity mismatch"));
                }
            }
            _ => return Err(invalid("Invalid discovery document")),
        },
        _ => return Err(invalid("Unknown source contract")),
    }
    Ok(())
}
fn required<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str()
        .filter(|s| !s.trim().is_empty() && s.len() <= 8192)
        .ok_or_else(|| invalid("Missing source text field"))
}
fn nullable(v: &Value, k: &str) -> Result<()> {
    if !v.get(k).is_some_and(|v| v.is_null() || v.is_string()) {
        return Err(invalid("Invalid nullable source text"));
    }
    Ok(())
}
fn array<'a>(v: &'a Value, k: &str, max: usize) -> Result<&'a Vec<Value>> {
    v[k].as_array()
        .filter(|a| a.len() <= max)
        .ok_or_else(|| invalid("Source array limit or shape invalid"))
}
fn unique(items: &[Value], k: &str) -> Result<()> {
    let mut seen = HashSet::new();
    for item in items {
        if !seen.insert(required(item, k)?) {
            return Err(invalid("Duplicate source identity"));
        }
    }
    Ok(())
}
fn summary(v: &Value) -> Result<()> {
    required(v, "id")?;
    required(v, "title")?;
    if !["novel", "manga", "audio", "video"].contains(&v["contentKind"].as_str().unwrap_or("")) {
        return Err(invalid("Unsupported native content kind"));
    }
    Ok(())
}
fn tree(v: &Value, depth: usize) -> Result<()> {
    if depth > 48 {
        return Err(invalid("Source tree depth exceeded"));
    }
    match v {
        Value::Array(a) => {
            if a.len() > 5000 {
                return Err(invalid("Source array exceeded"));
            }
            for v in a {
                tree(v, depth + 1)?;
            }
        }
        Value::Object(o) => {
            if v["type"] == "contentCollection" {
                array(v, "items", 1000)?;
            }
            if o.len() > 128 {
                return Err(invalid("Source object exceeded"));
            }
            for v in o.values() {
                tree(v, depth + 1)?;
            }
        }
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn full_ten_mib_novel_allows_json_escaping_and_reports_overflow() {
        for text in [
            "x".repeat(MAX_NOVEL_TEXT_BYTES),
            "\0".repeat(MAX_NOVEL_TEXT_BYTES),
        ] {
            let mut result = json!({"chapterId":"x","contentKind":"novel","text":text,"pages":[]});
            assert!(validate("getContent", &json!({"chapterId":"x"}), &result).is_ok());
            result["text"] = json!("x".repeat(MAX_NOVEL_TEXT_BYTES + 1));
            let error = validate("getContent", &json!({"chapterId":"x"}), &result).unwrap_err();
            assert!(
                error
                    .message
                    .contains("10485761 bytes exceeds the 10485760-byte limit")
            );
        }
    }
    #[test]
    fn catalogs_and_manga_manifests_accept_results_above_the_old_budgets() {
        let items: Vec<Value> = (0..3000)
            .map(|i| json!({"id":format!("{i}-{}", "x".repeat(3000)),"title":"A","order":i}))
            .collect();
        assert!(validate("getChapters", &json!({}), &json!({"items":items})).is_ok());
        let pages: Vec<Value> = (0..5000).map(|i| json!({"id":format!("{i}"),"index":i,"url":format!("https://example.com/{}", "x".repeat(1800))})).collect();
        assert!(
            validate(
                "getContent",
                &json!({"chapterId":"x"}),
                &json!({"chapterId":"x","contentKind":"manga","text":null,"pages":pages})
            )
            .is_ok()
        );
    }
    #[test]
    fn search_accepts_one_thousand_items_and_rejects_more() {
        let mut items: Vec<Value> = (0..1000)
            .map(|i| json!({"id":format!("b{i}"),"title":"A","contentKind":"novel"}))
            .collect();
        assert!(
            validate(
                "search",
                &json!({}),
                &json!({"items":items,"nextCursor":null})
            )
            .is_ok()
        );
        items.push(json!({"id":"extra","title":"A","contentKind":"novel"}));
        assert!(
            validate(
                "search",
                &json!({}),
                &json!({"items":items,"nextCursor":null})
            )
            .is_err()
        );
    }
    #[test]
    fn discovery_collections_accept_one_thousand_items_and_reject_more() {
        let mut items = vec![json!({}); 1000];
        let document = |items: &Vec<Value>| json!({"kind":"document","document":{"components":[{"type":"contentCollection","items":items}]}});
        assert!(validate("discover", &json!({}), &document(&items)).is_ok());
        items.push(json!({}));
        assert!(validate("discover", &json!({}), &document(&items)).is_err());
    }
    #[test]
    fn long_novel_is_bounded_without_legacy_48k_truncation() {
        let r = json!({"chapterId":"x","contentKind":"novel","text":"文".repeat(30000),"pages":[]});
        assert!(validate("getContent", &json!({"chapterId":"x"}), &r).is_ok());
        assert!(validate("getContent", &json!({"chapterId":"y"}), &r).is_err());
    }
    #[test]
    fn duplicate_catalog_ids_rejected() {
        let c =
            json!({"items":[{"id":"x","title":"A","order":0},{"id":"x","title":"B","order":1}]});
        assert!(validate("getChapters", &json!({}), &c).is_err());
    }
}
