//! Plugin-owned disposable cache. The host creates the root; only hash-named
//! files are used here. Writes are atomic, quota-bounded, and serialized only for cache mutations.
use crate::error::{Result, invalid};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

pub struct Cache {
    root: PathBuf,
    mutation: std::sync::Mutex<()>,
    max_entry_bytes: usize,
    max_total_bytes: u64,
}
impl Cache {
    pub fn open(root: &Path) -> Result<Self> {
        if !root.is_absolute()
            || !root.is_dir()
            || fs::symlink_metadata(root)?.file_type().is_symlink()
        {
            return Err(invalid(
                "Cache directory must be an existing private directory",
            ));
        }
        Ok(Self {
            root: root.canonicalize()?,
            mutation: std::sync::Mutex::new(()),
            max_entry_bytes: crate::limits::CACHE_ENTRY_BYTES,
            max_total_bytes: crate::limits::CACHE_TOTAL_BYTES as u64,
        })
    }
    fn path(&self, key: &str) -> PathBuf {
        self.root
            .join(format!("{:x}.json", Sha256::digest(key.as_bytes())))
    }
    pub fn read(&self, key: &str) -> Result<Option<String>> {
        let path = self.path(key);
        match fs::symlink_metadata(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
            Ok(m)
                if !m.is_file()
                    || m.file_type().is_symlink()
                    || m.len() > self.max_entry_bytes as u64 =>
            {
                return Ok(None);
            }
            _ => {}
        }
        let value = fs::read_to_string(&path).ok();
        if value.is_some() {
            let _ = fs::OpenOptions::new()
                .write(true)
                .open(path)
                .and_then(|file| file.set_modified(std::time::SystemTime::now()));
        }
        Ok(value)
    }
    pub fn write(&self, key: &str, value: &str) -> Result<()> {
        let _guard = self.mutation.lock().unwrap();
        if value.len() > self.max_entry_bytes {
            return Err(invalid(&format!(
                "Cache entry is {} bytes; the limit is {} bytes",
                value.len(),
                self.max_entry_bytes
            )));
        }
        let path = self.path(key);
        let mut used = 0;
        let mut entries = Vec::new();
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            let metadata = fs::symlink_metadata(entry.path())?;
            if entry.path() != path
                && entry.file_type()?.is_file()
                && entry.path().extension().is_some_and(|ext| ext == "json")
            {
                used += metadata.len();
                entries.push((
                    metadata.modified().unwrap_or(std::time::UNIX_EPOCH),
                    entry.path(),
                    metadata.len(),
                ));
            }
        }
        entries.sort_by_key(|entry| entry.0);
        for (_, old_path, bytes) in entries {
            if used + value.len() as u64 <= self.max_total_bytes {
                break;
            }
            fs::remove_file(old_path)?;
            used = used.saturating_sub(bytes);
        }
        let temporary = path.with_extension("tmp");
        // A previous worker may have died between sync and rename. Never follow
        // this disposable entry; remove the entry itself before create_new.
        if std::fs::symlink_metadata(&temporary).is_ok() {
            std::fs::remove_file(&temporary)?;
        }
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        let result = (|| -> std::io::Result<()> {
            file.write_all(value.as_bytes())?;
            file.sync_all()?;
            drop(file);
            fs::rename(&temporary, &path)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result.map_err(Into::into)
    }
    pub fn remove(&self, key: &str) -> Result<()> {
        let _guard = self.mutation.lock().unwrap();
        match fs::remove_file(self.path(key)) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            other => other.map_err(Into::into),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn large_results_cache_and_quota_evicts_old_entries() {
        let root = std::env::temp_dir().join(format!("mgread-cache-policy-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let mut cache = Cache::open(&root).unwrap();
        let large = "x".repeat(10 * 1024 * 1024 + 100);
        cache.write("large", &large).unwrap();
        assert_eq!(
            cache.read("large").unwrap().as_deref(),
            Some(large.as_str())
        );
        cache.remove("large").unwrap();
        cache.max_entry_bytes = 8;
        cache.max_total_bytes = 8;
        cache.write("a", "aaaa").unwrap();
        cache.write("b", "bbbb").unwrap();
        fs::OpenOptions::new()
            .write(true)
            .open(cache.path("b"))
            .unwrap()
            .set_modified(std::time::UNIX_EPOCH)
            .unwrap();
        cache.read("a").unwrap();
        cache.write("c", "cccc").unwrap();
        assert!(cache.read("a").unwrap().is_some());
        assert!(cache.read("b").unwrap().is_none());
        assert_eq!(cache.read("c").unwrap().as_deref(), Some("cccc"));
        fs::remove_dir_all(root).unwrap();
    }
}
