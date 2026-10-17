//! AI configuration: saved provider profiles and the tasks that use them. Part of
//! `collector-config.json`.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct AiConfig {
    #[serde(default)]
    pub profiles: Vec<AiProfile>,
    #[serde(default)]
    pub tasks: Vec<AiTask>,
}

/// A saved, named connection to one AI service.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AiProfile {
    pub id: String,
    pub name: String,
    #[serde(flatten)]
    pub kind: AiProfileKind,
    /// Model name passed to the service; the service default when absent.
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default = "default_timeout_seconds")]
    pub timeout_seconds: u64,
}

fn default_timeout_seconds() -> u64 {
    240
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum AiProfileKind {
    /// An OpenAI-compatible chat completions endpoint (`DeepSeek`, `OpenRouter`, local servers). The
    /// API key is the secret `ai.<profile id>`.
    Http { base_url: String },
    /// A command-line tool.
    Cli {
        preset: CliPreset,
        /// For `custom`: the command. `{model}`, `{schema_file}` and `{output_file}` are replaced;
        /// the prompt arrives on stdin and the JSON answer is read from stdout, or from
        /// `{output_file}` when the command uses it.
        #[serde(default)]
        command: Vec<String>,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CliPreset {
    Codex,
    Claude,
    Custom,
}

/// One use of AI: instructions, the fields it fills, and which profile runs it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AiTask {
    pub id: String,
    pub name: String,
    /// Profile ID; when empty, the first configured profile.
    #[serde(default)]
    pub profile: String,
    /// Profile IDs tried in order when the main one fails.
    #[serde(default)]
    pub fallback: Vec<String>,
    /// What to do. The items follow as a JSON array of `{id, title, text, detail, url, language}`.
    pub instructions: String,
    pub outputs: Vec<AiOutput>,
    /// Most input characters per call; items are batched up to this and `batch_size`.
    #[serde(default = "default_max_input_chars")]
    pub max_input_chars: usize,
    #[serde(default = "default_batch_size")]
    pub batch_size: usize,
}

fn default_max_input_chars() -> usize {
    6_500
}

fn default_batch_size() -> usize {
    2
}

/// A string the model returns per item, and the item field it fills. An empty answer leaves the
/// field unchanged.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AiOutput {
    pub name: String,
    pub target: OutputTarget,
    pub description: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputTarget {
    TranslatedTitle,
    Summary,
    Text,
    Detail,
}

/// ID of the preset translation task, run for sources with `translate` on.
pub const TRANSLATE_TASK: &str = "translate";
/// ID of the preset summary task, run for sources with `summarize` on.
pub const SUMMARIZE_TASK: &str = "summarize";

impl AiConfig {
    /// The configured task, or a preset for `translate` and `summarize`.
    #[must_use]
    pub fn task(&self, id: &str) -> Option<AiTask> {
        self.tasks
            .iter()
            .find(|t| t.id == id)
            .cloned()
            .or_else(|| preset_task(id))
    }

    /// Profiles to try for a task, in order: its profile (or the first configured), then its
    /// fallbacks. Unknown IDs are skipped.
    #[must_use]
    pub fn profiles_for(&self, task: &AiTask) -> Vec<&AiProfile> {
        let main = if task.profile.is_empty() {
            self.profiles.first().map(|p| p.id.as_str())
        } else {
            Some(task.profile.as_str())
        };
        let mut ids: Vec<&str> = main
            .into_iter()
            .chain(task.fallback.iter().map(String::as_str))
            .collect();
        let mut seen = std::collections::HashSet::new();
        ids.retain(|id| seen.insert(*id));
        ids.into_iter()
            .filter_map(|id| self.profiles.iter().find(|p| p.id == id))
            .collect()
    }
}

fn preset_task(id: &str) -> Option<AiTask> {
    match id {
        TRANSLATE_TASK => Some(AiTask {
            id: TRANSLATE_TASK.into(),
            name: "Translate to Simplified Chinese".into(),
            profile: String::new(),
            fallback: Vec::new(),
            instructions: "Translate each item into Simplified Chinese. Keep names, numbers and links \
                           exact. If an item is already in Simplified Chinese, return its text unchanged. \
                           Translate the detail as clean Markdown and drop navigation, ads and boilerplate; \
                           return an empty string when there is no detail."
                .into(),
            outputs: vec![
                AiOutput {
                    name: "title".into(),
                    target: OutputTarget::TranslatedTitle,
                    description: "The title translated; for items without a title, the first sentence of the text translated.".into(),
                },
                AiOutput {
                    name: "detail".into(),
                    target: OutputTarget::Detail,
                    description: "The detail translated as Markdown, or an empty string.".into(),
                },
            ],
            max_input_chars: default_max_input_chars(),
            batch_size: default_batch_size(),
        }),
        SUMMARIZE_TASK => Some(AiTask {
            id: SUMMARIZE_TASK.into(),
            name: "Summarize".into(),
            profile: String::new(),
            fallback: Vec::new(),
            instructions: "Summarize what each item says in one or two factual sentences, in the same \
                           language as the item. Use the title, text and detail. Write about the content \
                           itself: never mention the item, its fields, links or missing information. No \
                           opinions or marketing words."
                .into(),
            outputs: vec![AiOutput {
                name: "summary".into(),
                target: OutputTarget::Summary,
                description: "One or two sentence factual summary.".into(),
            }],
            max_input_chars: default_max_input_chars(),
            batch_size: 4,
        }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(id: &str) -> AiProfile {
        AiProfile {
            id: id.into(),
            name: id.into(),
            kind: AiProfileKind::Http {
                base_url: "https://api.example.com".into(),
            },
            model: None,
            timeout_seconds: 60,
        }
    }

    #[test]
    fn presets_fill_in_for_missing_tasks_and_can_be_overridden() {
        let mut config = AiConfig::default();
        assert_eq!(config.task(TRANSLATE_TASK).unwrap().outputs.len(), 2);
        assert!(config.task("unknown").is_none());

        let mut custom = config.task(SUMMARIZE_TASK).unwrap();
        custom.instructions = "Mine".into();
        config.tasks.push(custom);
        assert_eq!(config.task(SUMMARIZE_TASK).unwrap().instructions, "Mine");
    }

    #[test]
    fn profiles_for_uses_main_then_fallbacks_without_duplicates() {
        let config = AiConfig {
            profiles: vec![profile("a"), profile("b"), profile("c")],
            tasks: vec![],
        };
        let mut task = config.task(SUMMARIZE_TASK).unwrap();
        let ids = |t: &AiTask| {
            config
                .profiles_for(t)
                .iter()
                .map(|p| p.id.clone())
                .collect::<Vec<_>>()
        };

        assert_eq!(ids(&task), ["a"], "empty profile means the first");
        task.profile = "c".into();
        task.fallback = vec!["missing".into(), "a".into(), "c".into()];
        assert_eq!(ids(&task), ["c", "a"]);
    }

    #[test]
    fn parses_profile_kinds() {
        let profiles: Vec<AiProfile> = serde_json::from_str(
            r#"[{"id":"d","name":"DeepSeek","kind":"http","base_url":"https://api.deepseek.com","model":"deepseek-chat"},
                {"id":"c","name":"Claude","kind":"cli","preset":"claude"}]"#,
        )
        .unwrap();
        assert!(matches!(profiles[0].kind, AiProfileKind::Http { .. }));
        assert_eq!(
            profiles[1].kind,
            AiProfileKind::Cli {
                preset: CliPreset::Claude,
                command: vec![]
            }
        );
        assert_eq!(profiles[1].timeout_seconds, 240);
    }
}
