//! Collector configuration, written by the Mac app as `collector-config.json` and reloaded by the
//! daemon when it changes. Contract fixture: `services/testdata/collector-config.json`.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CollectorConfig {
    pub version: u32,
    /// Items published longer ago than this are skipped. Items without a date always pass.
    #[serde(default = "default_max_item_age_hours")]
    pub max_item_age_hours: u32,
    #[serde(default)]
    pub sources: Vec<SourceConfig>,
}

impl Default for CollectorConfig {
    fn default() -> Self {
        Self {
            version: 1,
            max_item_age_hours: default_max_item_age_hours(),
            sources: Vec::new(),
        }
    }
}

fn default_max_item_age_hours() -> u32 {
    72
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[allow(clippy::struct_excessive_bools)] // wire format: independent per-source switches
pub struct SourceConfig {
    pub id: Uuid,
    pub plugin_id: String,
    pub name: String,
    /// Plugin-specific target: a feed URL, a handle, a search query.
    pub query: String,
    #[serde(default)]
    pub settings: serde_json::Map<String, serde_json::Value>,
    pub interval_minutes: u32,
    /// False when the source or every channel containing it is paused.
    pub enabled: bool,
    #[serde(default)]
    pub translate: bool,
    #[serde(default)]
    pub summarize: bool,
    #[serde(default)]
    pub fetch_detail: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_shared_fixture() {
        let config: CollectorConfig =
            serde_json::from_str(include_str!("../../../testdata/collector-config.json")).unwrap();
        assert_eq!(config.version, 1);
        assert_eq!(config.max_item_age_hours, 48);
        assert_eq!(config.sources.len(), 2);
        assert_eq!(config.sources[0].plugin_id, "rss");
        assert!(!config.sources[1].enabled);
    }

    #[test]
    fn missing_optional_fields_use_defaults() {
        let config: CollectorConfig = serde_json::from_str(r#"{"version":1}"#).unwrap();
        assert_eq!(config, CollectorConfig::default());
    }
}
