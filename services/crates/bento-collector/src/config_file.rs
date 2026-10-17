//! `collector-config.json`, written by the Mac app. Reloaded when its modification time changes.

use std::path::PathBuf;
use std::time::SystemTime;

use anyhow::{Context, Result};
use bento_domain::CollectorConfig;

pub struct ConfigFile {
    path: PathBuf,
    loaded_mtime: Option<SystemTime>,
}

impl ConfigFile {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            loaded_mtime: None,
        }
    }

    /// Returns the config if the file changed since the last successful load, `Ok(None)` if it
    /// did not, and an error if it changed but cannot be read or parsed (the caller keeps the
    /// previous config). A missing file is an empty config.
    pub fn reload_if_changed(&mut self) -> Result<Option<CollectorConfig>> {
        let mtime = match std::fs::metadata(&self.path) {
            Ok(metadata) => Some(metadata.modified()?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(error).context("reading config metadata"),
        };
        // A missing file counts as UNIX_EPOCH, so creating it later is a change.
        let mtime = mtime.unwrap_or(SystemTime::UNIX_EPOCH);
        if self.loaded_mtime == Some(mtime) {
            return Ok(None);
        }
        let config = if mtime == SystemTime::UNIX_EPOCH {
            CollectorConfig::default()
        } else {
            let text = std::fs::read_to_string(&self.path)
                .with_context(|| format!("reading {}", self.path.display()))?;
            serde_json::from_str(&text)
                .with_context(|| format!("parsing {}", self.path.display()))?
        };
        self.loaded_mtime = Some(mtime);
        Ok(Some(config))
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    fn write(path: &std::path::Path, text: &str, mtime_offset_secs: u64) {
        std::fs::write(path, text).unwrap();
        let mtime = SystemTime::UNIX_EPOCH + Duration::from_secs(1_800_000_000 + mtime_offset_secs);
        std::fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(mtime)
            .unwrap();
    }

    #[test]
    fn missing_file_is_empty_config_once() {
        let dir = tempfile::tempdir().unwrap();
        let mut file = ConfigFile::new(dir.path().join("c.json"));
        assert_eq!(
            file.reload_if_changed().unwrap(),
            Some(CollectorConfig::default())
        );
        assert_eq!(file.reload_if_changed().unwrap(), None);
    }

    #[test]
    fn reloads_only_when_modified() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.json");
        let mut file = ConfigFile::new(path.clone());
        write(&path, r#"{"version":1,"max_item_age_hours":1}"#, 0);
        assert_eq!(
            file.reload_if_changed()
                .unwrap()
                .unwrap()
                .max_item_age_hours,
            1
        );
        assert_eq!(file.reload_if_changed().unwrap(), None);

        write(&path, r#"{"version":1,"max_item_age_hours":2}"#, 1);

        assert_eq!(
            file.reload_if_changed()
                .unwrap()
                .unwrap()
                .max_item_age_hours,
            2
        );
    }

    #[test]
    fn invalid_file_errors_and_is_retried() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.json");
        let mut file = ConfigFile::new(path.clone());
        write(&path, "{nope", 0);
        assert!(file.reload_if_changed().is_err());
        assert!(
            file.reload_if_changed().is_err(),
            "a failed load is not remembered"
        );

        write(&path, r#"{"version":1}"#, 1);

        assert!(file.reload_if_changed().unwrap().is_some());
    }

    #[test]
    fn file_created_after_missing_is_loaded() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.json");
        let mut file = ConfigFile::new(path.clone());
        file.reload_if_changed().unwrap();

        write(&path, r#"{"version":1,"max_item_age_hours":5}"#, 0);

        assert_eq!(
            file.reload_if_changed()
                .unwrap()
                .unwrap()
                .max_item_age_hours,
            5
        );
    }
}
