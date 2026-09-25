//! Native-only immutable installations and atomic catalog. The catalog owns state;
//! pending removal/version changes are committed only before libraries are loaded.
use crate::error::{Error, Result, invalid};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    io::{Cursor, Read},
    path::{Component, Path, PathBuf},
};

pub const MAX_ARCHIVE: usize = 64 * 1024 * 1024;
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Target {
    pub path: String,
    pub sha256: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub format: String,
    pub engine: String,
    pub abi: u32,
    pub id: String,
    pub name: String,
    pub version: String,
    pub description: String,
    pub content_kinds: Vec<String>,
    pub capabilities: Vec<String>,
    pub targets: BTreeMap<String, Target>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub manifest: Manifest,
    pub enabled: bool,
    #[serde(default)]
    pub pending: Option<Manifest>,
    #[serde(default)]
    pub removing: bool,
}
pub struct Catalog {
    pub root: PathBuf,
    pub entries: BTreeMap<String, Entry>,
}
pub fn target() -> &'static str {
    if cfg!(target_os = "android") {
        if cfg!(target_arch = "aarch64") {
            "android-arm64-v8a"
        } else {
            "android-x86_64"
        }
    } else {
        "windows-x86_64"
    }
}
pub fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
/// Existing public transfer envelopes use IEEE CRC32; binary manifests use SHA256.
pub fn transfer_checksum(bytes: &[u8]) -> String {
    let mut crc = !0u32;
    for &byte in bytes {
        crc ^= byte as u32;
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb88320 & 0u32.wrapping_sub(crc & 1));
        }
    }
    format!("{:08x}", !crc)
}
pub fn safe_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 160
        && s != "."
        && s != ".."
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
}
pub fn safe_relative(s: &str) -> bool {
    !s.is_empty()
        && !s.contains('\\')
        && !s.contains(':')
        && Path::new(s)
            .components()
            .all(|c| matches!(c, Component::Normal(_)))
}
pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| invalid("Missing parent directory"))?;
    fs::create_dir_all(parent)?;
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    {
        use std::io::Write;
        let mut f = fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    fs::rename(tmp, path)?;
    Ok(())
}
impl Catalog {
    pub fn open(root: PathBuf) -> Result<Self> {
        fs::create_dir_all(&root)?;
        let root = root.canonicalize()?;
        let entries = match fs::read(root.join("catalog.json")) {
            Ok(bytes) => serde_json::from_slice(&bytes)?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => BTreeMap::new(),
            Err(e) => return Err(e.into()),
        };
        let mut c = Self { root, entries };
        let removing = c
            .entries
            .iter()
            .filter(|(_, e)| e.removing)
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        for id in removing {
            c.remove_files(&id)?;
            c.entries.remove(&id);
        }
        // Only immutable files are inspected here. A pending invalid ABI is rejected
        // by the first explicit load, while the prior version remains installed.
        c.save()?;
        Ok(c)
    }
    pub fn save(&self) -> Result<()> {
        atomic_write(
            &self.root.join("catalog.json"),
            &serde_json::to_vec(&self.entries)?,
        )
    }
    pub fn versions(&self, id: &str) -> PathBuf {
        self.root.join("plugins").join(id).join("versions")
    }
    pub fn library(&self, m: &Manifest) -> Result<PathBuf> {
        let t = m
            .targets
            .get(target())
            .ok_or_else(|| Error::new("unsupported", "Plugin has no binary for this platform"))?;
        let version = self.versions(&m.id).join(&m.version);
        let library = version.join(&t.path);
        if !library.is_file() {
            // Android can select another ABI after an APK update. The immutable
            // package contains every supported target; recover only the missing
            // current target, preserving the catalog, version and private data.
            let mut archive_bytes = Vec::new();
            fs::File::open(version.join("source.mgplugin"))?
                .take(MAX_ARCHIVE as u64 + 1)
                .read_to_end(&mut archive_bytes)?;
            if archive_bytes.len() > MAX_ARCHIVE {
                return Err(invalid("Stored plugin archive is too large"));
            }
            let mut archive = zip::ZipArchive::new(Cursor::new(archive_bytes))
                .map_err(|_| invalid("Invalid stored plugin ZIP"))?;
            let mut bytes = Vec::new();
            archive
                .by_name(&t.path)
                .map_err(|_| invalid("Stored package has no target binary"))?
                .take(32 * 1024 * 1024 + 1)
                .read_to_end(&mut bytes)?;
            if bytes.len() > 32 * 1024 * 1024 || hash(&bytes) != t.sha256.to_lowercase() {
                return Err(invalid("Stored target checksum mismatch"));
            }
            atomic_write(&library, &bytes)?;
        }
        Ok(library)
    }
    pub fn validate_manifest(m: &Manifest) -> Result<()> {
        if m.format != "mgread-native"
            || m.engine != "native"
            || m.abi != 1
            || !safe_name(&m.id)
            || !safe_name(&m.version)
            || semver::Version::parse(&m.version).is_err()
            || m.name.is_empty()
            || m.name.len() > 256
            || m.description.len() > 960
            || m.content_kinds != ["novel"]
            || m.targets.is_empty()
            || m.targets.len() > 3
        {
            return Err(invalid("Unsupported native manifest"));
        }
        for (name, t) in &m.targets {
            if !["windows-x86_64", "android-arm64-v8a", "android-x86_64"].contains(&name.as_str())
                || !safe_relative(&t.path)
                || t.sha256.len() != 64
                || !t.sha256.bytes().all(|c| c.is_ascii_hexdigit())
            {
                return Err(invalid("Invalid native target"));
            }
        }
        if !m.targets.contains_key(target()) {
            return Err(Error::new("unsupported", "Plugin target is unavailable"));
        }
        Ok(())
    }
    pub fn install(&mut self, bytes: &[u8], expected: Option<(&str, &str)>) -> Result<Manifest> {
        if bytes.len() > MAX_ARCHIVE {
            return Err(invalid("Plugin archive is too large"));
        }
        let mut archive =
            zip::ZipArchive::new(Cursor::new(bytes)).map_err(|_| invalid("Invalid plugin ZIP"))?;
        if archive.len() > 16 {
            return Err(invalid("Too many archive entries"));
        }
        let mut seen = HashSet::new();
        let mut expanded = 0u64;
        for i in 0..archive.len() {
            let f = archive
                .by_index(i)
                .map_err(|_| invalid("Invalid archive entry"))?;
            if !safe_relative(f.name())
                || !seen.insert(f.name().to_string())
                || f.is_dir()
                || f.unix_mode().is_some_and(|m| m & 0o170000 == 0o120000)
            {
                return Err(invalid("Unsafe archive entry"));
            }
            expanded = expanded
                .checked_add(f.size())
                .ok_or_else(|| invalid("Archive size overflow"))?;
            if expanded > MAX_ARCHIVE as u64 {
                return Err(invalid("Expanded archive is too large"));
            }
        }
        let mut raw = Vec::new();
        archive
            .by_name("manifest.json")
            .map_err(|_| invalid("Missing native manifest"))?
            .take(65537)
            .read_to_end(&mut raw)?;
        if raw.len() > 65536 {
            return Err(invalid("Manifest is too large"));
        }
        let manifest: Manifest = serde_json::from_slice(&raw)?;
        Self::validate_manifest(&manifest)?;
        if expected.is_some_and(|(id, version)| manifest.id != id || manifest.version != version) {
            return Err(invalid(
                "Transfer metadata does not match the native manifest",
            ));
        }
        let selected = manifest.targets.get(target()).unwrap();
        let mut binary = Vec::new();
        for t in manifest.targets.values() {
            let mut data = Vec::new();
            archive
                .by_name(&t.path)
                .map_err(|_| invalid("Missing target binary"))?
                .take(32 * 1024 * 1024 + 1)
                .read_to_end(&mut data)?;
            if data.len() > 32 * 1024 * 1024 || hash(&data) != t.sha256.to_lowercase() {
                return Err(invalid("Native binary checksum mismatch"));
            }
            if t.path == selected.path {
                binary = data;
            }
        }
        let version_dir = self.versions(&manifest.id).join(&manifest.version);
        if version_dir.exists() {
            if fs::read(version_dir.join("manifest.json"))? != raw {
                return Err(invalid("Installed versions are immutable"));
            }
        } else {
            let stage = self.versions(&manifest.id).join(format!(
                ".stage-{}-{}",
                std::process::id(),
                manifest.version
            ));
            if stage.exists() {
                fs::remove_dir_all(&stage)?;
            }
            fs::create_dir_all(&stage)?;
            atomic_write(&stage.join(&selected.path), &binary)?;
            atomic_write(&stage.join("manifest.json"), &raw)?;
            atomic_write(&stage.join("source.mgplugin"), bytes)?;
            fs::rename(&stage, &version_dir)?;
        }
        // A malformed ABI never changes the confirmed catalog. No invocations
        // exist on this short-lived validation handle; active libraries stay held.
        crate::native::NativePlugin::load(&self.library(&manifest)?, &manifest)?;
        if let Some(e) = self.entries.get_mut(&manifest.id) {
            if e.manifest.version != manifest.version {
                e.pending = Some(manifest.clone());
            }
            e.removing = false;
        } else {
            self.entries.insert(
                manifest.id.clone(),
                Entry {
                    manifest: manifest.clone(),
                    enabled: true,
                    pending: None,
                    removing: false,
                },
            );
        }
        self.save()?;
        Ok(manifest)
    }
    pub fn projection(&self, e: &Entry) -> Value {
        let m = &e.manifest;
        json!({"id":m.id,"name":m.name,"displayName":m.name,"description":m.description,"iconUrl":null,
               "activeVersion":m.version,"pendingVersion":e.pending.as_ref().map(|p|&p.version),"enabled":e.enabled,
               "status":if e.enabled {"active"}else{"disabled"},"contentKinds":m.content_kinds,"engine":"native"})
    }
    pub fn list(&self) -> Value {
        Value::Array(
            self.entries
                .values()
                .filter(|e| !e.removing)
                .map(|e| self.projection(e))
                .collect(),
        )
    }
    pub fn entry(&self, id: &str) -> Result<&Entry> {
        self.entries
            .get(id)
            .filter(|e| !e.removing)
            .ok_or_else(|| Error::new("plugin_not_found", "Native plugin is not installed"))
    }
    fn remove_files(&self, id: &str) -> Result<()> {
        if !safe_name(id) {
            return Err(invalid("Invalid plugin identifier"));
        }
        let p = self.root.join("plugins").join(id);
        if p.exists() {
            fs::remove_dir_all(p)?;
        }
        Ok(())
    }
}
pub fn usage(path: &Path) -> Result<(u64, u64)> {
    if !path.exists() {
        return Ok((0, 0));
    }
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() {
        return Err(invalid("Symlink in native storage"));
    }
    if metadata.is_file() {
        return Ok((metadata.len(), 1));
    }
    let (mut bytes, mut files) = (0, 0);
    for item in fs::read_dir(path)? {
        let (b, f) = usage(&item?.path())?;
        bytes += b;
        files += f;
    }
    Ok((bytes, files))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_path_escapes() {
        for p in ["../x", "/x", "C:/x", "x\\y", "."] {
            assert!(!safe_relative(p), "{p}");
        }
        assert!(safe_relative("android-x86_64/libsource.so"));
    }
    #[test]
    fn identifiers_are_components() {
        for p in ["..", ".", "a/b", "", "a:b"] {
            assert!(!safe_name(p));
        }
        assert!(safe_name("org.mgread.alice"));
    }
}
