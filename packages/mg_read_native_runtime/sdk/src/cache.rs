//! Plugin-owned disposable cache. The host creates the root; only hash-named
//! files are used here. Writes are atomic, quota-bounded, and serialized by calls.
use crate::error::{Result, invalid};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

pub struct Cache {
    root: PathBuf,
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
            Ok(m) if !m.is_file() || m.file_type().is_symlink() || m.len() > 8 * 1024 * 1024 => {
                return Ok(None);
            }
            _ => {}
        }
        Ok(fs::read_to_string(path).ok())
    }
    pub fn write(&self, key: &str, value: &str) -> Result<()> {
        if value.len() > 8 * 1024 * 1024 {
            return Err(invalid("Cache entry exceeds its limit"));
        }
        let path = self.path(key);
        let mut used = 0;
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            if entry.path() != path {
                used += entry.metadata()?.len();
            }
        }
        if used + value.len() as u64 > 64 * 1024 * 1024 {
            return Err(invalid("Plugin cache quota exceeded"));
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
        match fs::remove_file(self.path(key)) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            other => other.map_err(Into::into),
        }
    }
}
