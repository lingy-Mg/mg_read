//! Metadata-only transfer planning. Installation verifies the actual archive
//! identity separately before publication; offers never authorize a downgrade.
use crate::{
    catalog::{Catalog, safe_name},
    error::{Result, invalid, string},
};
use serde_json::{Value, json};
use std::{cmp::Ordering, collections::HashSet};

fn action(current: Option<&str>, proposed: &str, force: bool) -> Result<&'static str> {
    let incoming =
        semver::Version::parse(proposed).map_err(|_| invalid("Invalid source version"))?;
    let Some(current) = current else {
        return Ok("missing");
    };
    let installed =
        semver::Version::parse(current).map_err(|_| invalid("Invalid installed version"))?;
    Ok(match installed.cmp_precedence(&incoming) {
        Ordering::Equal if !force => "same",
        Ordering::Greater if !force => "receiverNewer",
        _ => "upgrade",
    })
}

pub fn plan(catalog: &Catalog, params: &Value) -> Result<Value> {
    let items = params
        .get("artifacts")
        .or_else(|| params.get("offers"))
        .and_then(Value::as_array)
        .ok_or_else(|| invalid("Missing transfer items"))?;
    if items.len() > 1024 {
        return Err(invalid("Transfer batch is too large"));
    }
    let force = params.get("forceUpgradeIds").and_then(Value::as_array);
    let mut seen = HashSet::new();
    let mut result = Vec::with_capacity(items.len());
    for item in items {
        let id = string(item, "id")?;
        let version = string(item, "version")?;
        if !safe_name(id) || !seen.insert(id) {
            return Err(invalid("Invalid transfer source ID"));
        }
        let current = catalog
            .entries
            .get(id)
            .filter(|e| !e.removing)
            .map(|e| e.manifest.version.as_str());
        let supported = item["format"] == "archive" && item["provenance"] == "installed";
        let force = force.is_some_and(|ids| ids.iter().any(|v| v.as_str() == Some(id)));
        let decision = if supported {
            action(current, version, force)?
        } else {
            "unavailable"
        };
        result.push(json!({"id":id,"version":version,"receiverVersion":current,"action":decision}));
    }
    Ok(json!(result))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn compares_numeric_and_prerelease_versions() {
        assert_eq!(action(None, "0.1.0", false).unwrap(), "missing");
        assert_eq!(action(Some("0.9.0"), "0.10.0", false).unwrap(), "upgrade");
        assert_eq!(
            action(Some("1.0.0"), "1.0.0-beta.1", false).unwrap(),
            "receiverNewer"
        );
        assert_eq!(
            action(Some("1.0.0+build1"), "1.0.0+build2", false).unwrap(),
            "same"
        );
        assert_eq!(action(Some("2.0.0"), "1.0.0", true).unwrap(), "upgrade");
        assert!(action(None, "invalid", false).is_err());
    }
}
