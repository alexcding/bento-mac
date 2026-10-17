//! Collector configuration, written by the Mac app as `collector-config.json` and reloaded by the
//! daemon when it changes. Contract fixture: `services/testdata/collector-config.json`.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ai::{AiConfig, SUMMARIZE_TASK, TRANSLATE_TASK};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CollectorConfig {
    pub version: u32,
    /// Items published longer ago than this are skipped. Items without a date always pass.
    #[serde(default = "default_max_item_age_hours")]
    pub max_item_age_hours: u32,
    #[serde(default)]
    pub sources: Vec<SourceConfig>,
    #[serde(default)]
    pub ai: AiConfig,
    /// No source runs on Saturdays and Sundays (in the app's time zone).
    #[serde(default)]
    pub skip_weekends: bool,
    /// The app's UTC offset, for `skip_weekends`.
    #[serde(default)]
    pub utc_offset_minutes: i32,
}

impl Default for CollectorConfig {
    fn default() -> Self {
        Self {
            version: 1,
            max_item_age_hours: default_max_item_age_hours(),
            sources: Vec::new(),
            ai: AiConfig::default(),
            skip_weekends: false,
            utc_offset_minutes: 0,
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
    /// AI task IDs run on this source's new items, in order, after `translate` and `summarize`.
    #[serde(default)]
    pub ai_tasks: Vec<String>,
    /// On the first fetch, mark what the source already has as seen instead of storing it.
    #[serde(default)]
    pub skip_initial_backlog: bool,
}

impl SourceConfig {
    /// Every AI task to run, in order and without repeats: the presets switched on by `translate`
    /// and `summarize`, then `ai_tasks`.
    #[must_use]
    pub fn task_ids(&self) -> Vec<&str> {
        let presets = [
            (self.translate, TRANSLATE_TASK),
            (self.summarize, SUMMARIZE_TASK),
        ];
        let mut ids: Vec<&str> = presets
            .iter()
            .filter(|(on, _)| *on)
            .map(|(_, id)| *id)
            .collect();
        for id in &self.ai_tasks {
            if !ids.contains(&id.as_str()) {
                ids.push(id);
            }
        }
        ids
    }
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
    fn task_ids_combine_switches_and_list_without_repeats() {
        let mut config: CollectorConfig =
            serde_json::from_str(include_str!("../../../testdata/collector-config.json")).unwrap();
        let source = &mut config.sources[0];
        assert_eq!(source.task_ids(), ["translate"]);
        source.summarize = true;
        source.ai_tasks = vec!["summarize".into(), "keywords".into()];
        assert_eq!(source.task_ids(), ["translate", "summarize", "keywords"]);
    }

    #[test]
    fn missing_optional_fields_use_defaults() {
        let config: CollectorConfig = serde_json::from_str(r#"{"version":1}"#).unwrap();
        assert_eq!(config, CollectorConfig::default());
    }
}
