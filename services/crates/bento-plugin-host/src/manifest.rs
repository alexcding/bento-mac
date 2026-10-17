//! `plugin.json`. Its JSON Schema is `plugins/plugin.schema.json`.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Plugin protocol version this host speaks.
pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub id: String,
    pub name: String,
    pub version: String,
    pub protocol: u32,
    pub capabilities: Vec<Capability>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub requires: Vec<Requirement>,
    #[serde(default)]
    pub auth: Auth,
    #[serde(default)]
    pub source: Option<SourceSpec>,
    /// How the plugin posts as the user (the `publisher` capability).
    #[serde(default)]
    pub publish: Option<PublishSpec>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PublishSpec {
    pub cli: CliPublish,
}

/// Posts by running a command: `args` may use `{text}`; with an image, `image_args` (using
/// `{image}`, a local file) are added before the `--` argument, or at the end without one.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CliPublish {
    pub args: Vec<String>,
    #[serde(default)]
    pub image_args: Vec<String>,
    /// As for sources: values may use `{secret.<key>}`.
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    pub text: bento_domain::TextLimits,
    #[serde(default = "default_publish_timeout_seconds")]
    pub timeout_seconds: u64,
}

fn default_publish_timeout_seconds() -> u64 {
    60
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Capability {
    Source,
    Publisher,
    Auth,
}

/// An external program the plugin needs, shown on the app's Dependencies screen.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Requirement {
    pub name: String,
    /// Command that exits 0 when the program is installed, e.g. `["yt-dlp", "--version"]`.
    pub check: Vec<String>,
    /// Human-readable install instruction.
    pub install: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum Auth {
    #[default]
    None,
    /// Values the user enters in Settings; stored in the Keychain.
    Secrets {
        fields: Vec<SecretField>,
        /// Whether the plugin needs them to fetch anything. The app offers a plugin as a source
        /// only once what it needs is set.
        #[serde(default = "required_by_default")]
        required: bool,
    },
    /// A login the plugin drives step by step (`auth/begin`, `auth/step`): QR codes, phone codes.
    /// `secrets` lists the Keychain keys it saves and receives back.
    Interactive {
        secrets: Vec<String>,
        #[serde(default = "required_by_default")]
        required: bool,
    },
}

fn required_by_default() -> bool {
    true
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SecretField {
    pub key: String,
    pub label: String,
    #[serde(default)]
    pub help: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceSpec {
    pub default_interval_minutes: u32,
    /// Placeholder shown in the query field, e.g. `@handle, x.com URL or search terms`.
    #[serde(default)]
    pub query_hint: Option<String>,
    /// Exactly one of `cli` and `protocol`.
    #[serde(default)]
    pub cli: Option<CliSource>,
    #[serde(default)]
    pub protocol: Option<ProtocolSource>,
}

/// A source backed by a plugin executable speaking the Bento plugin protocol.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProtocolSource {
    /// File name, found in the plugin's `bin/`, next to the daemon, or on PATH.
    pub executable: String,
    #[serde(default = "default_protocol_timeout_seconds")]
    pub timeout_seconds: u64,
}

fn default_protocol_timeout_seconds() -> u64 {
    60
}

/// A source backed by an external command: pick a command by matching the query, run it, map its
/// output with `mapping.json`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CliSource {
    /// Tried in order; the first whose `match` regex matches the trimmed query runs.
    pub commands: Vec<CommandSpec>,
    /// Extra environment. Values may use `{secret.<key>}`; a variable whose secret is not set is
    /// left out, so the program can fall back to its own configuration.
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    pub output: OutputFormat,
    #[serde(default = "default_timeout_seconds")]
    pub timeout_seconds: u64,
    /// Items requested when the source sets no `limit`.
    #[serde(default = "default_limit")]
    pub default_limit: u32,
    /// Keep the output of a command that exits non-zero but printed something, for programs that
    /// fail the whole run over one bad item (yt-dlp on a playlist).
    #[serde(default)]
    pub partial_output_ok: bool,
}

fn default_timeout_seconds() -> u64 {
    45
}

fn default_limit() -> u32 {
    20
}

/// `args` may use `{query}`, `{limit}` and the regex's named groups, optionally with the
/// `urldecode` filter: `{q|urldecode}`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommandSpec {
    #[serde(rename = "match")]
    pub pattern: String,
    pub args: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum OutputFormat {
    /// One JSON document; falls back to JSON Lines if the whole output is not valid JSON.
    Json,
    /// One JSON value per line; other lines are ignored.
    JsonLines,
    /// Plain text: each line containing a URL becomes `{"text": <line without URL>, "url": <url>}`.
    TextLines,
}
