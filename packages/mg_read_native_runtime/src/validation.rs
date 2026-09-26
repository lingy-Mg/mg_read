//! Bounded public source contract checks after plugin-owned resource projection. Flutter
//! performs the same final typed decode for Node and native content.
use crate::error::{Result, invalid};
use serde_json::Value;
use std::collections::HashSet;

pub fn validate(method: &str, request: &Value, result: &Value) -> Result<()> {
    if !result.is_object() || serde_json::to_vec(result)?.len() > 8 * 1024 * 1024 {
        return Err(invalid("Invalid source result size"));
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
                    if result["text"].as_str().unwrap().len() > 1024 * 1024 {
                        return Err(invalid("Novel chapter exceeds 1 MiB"));
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
            let items = array(result, "items", 100)?;
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
