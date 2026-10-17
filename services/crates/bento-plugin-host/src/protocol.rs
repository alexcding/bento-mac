//! Protocol plugins: an executable that answers one JSON-RPC 2.0 request per run. The request is
//! written to stdin; the response is read from stdout. See `plugins/PROTOCOL.md`.
//!
//! Methods: `source/fetch` → `{"items": [raw item…]}`; `auth/begin` and `auth/step` → [`AuthStep`];
//! `publish/send` → `{}`.
//! Secrets travel in `params.secrets`; a plugin asks the host to store new ones with
//! `save_secrets`. A plugin never touches the Keychain itself.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use bento_app::{PortError, SecretStore, SourceFetcher};
use bento_domain::{RawItem, SourceConfig};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;

use crate::manifest::{Auth, Manifest};

/// Largest response read from a plugin.
const MAX_RESPONSE_BYTES: u64 = 24 * 1024 * 1024;
/// JSON-RPC error code a plugin returns when it needs the user to log in.
pub const AUTH_REQUIRED: i64 = -32001;
/// The service asks to wait `data.retry_after` seconds.
pub const RATE_LIMITED: i64 = -32002;
/// Refused for good; the same request will not succeed later.
pub const REJECTED: i64 = -32003;
/// The request may or may not have taken effect (a connection lost mid-send).
pub const UNCERTAIN: i64 = -32004;

#[derive(Debug, thiserror::Error)]
pub enum ProtocolError {
    #[error("plugin executable `{0}` not found")]
    NotFound(String),
    #[error("could not run the plugin: {0}")]
    Io(#[from] std::io::Error),
    #[error("plugin timed out after {0} s")]
    Timeout(u64),
    #[error("plugin returned an invalid response: {0}")]
    Invalid(String),
    #[error("login required: sign in to this plugin in Settings")]
    AuthRequired,
    #[error("rate limited for {0} s")]
    RateLimited(u64),
    #[error("{message}")]
    Plugin { code: i64, message: String },
}

/// One step of an interactive login, returned by `auth/begin` and `auth/step`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthStep {
    pub status: AuthStatus,
    /// Opaque; sent back with the next `auth/step`.
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub prompt: Option<AuthPrompt>,
    /// When to call `auth/step` again without user input (polling a QR scan).
    #[serde(default)]
    pub poll_after_ms: Option<u64>,
    /// Secrets the host stores in the Keychain for this plugin.
    #[serde(default)]
    pub save_secrets: BTreeMap<String, String>,
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AuthStatus {
    Pending,
    Done,
    Failed,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthPrompt {
    pub kind: PromptKind,
    pub message: String,
    /// For `qr`: the text to encode.
    #[serde(default)]
    pub qr: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PromptKind {
    /// Show a QR code and poll.
    Qr,
    /// Ask for text (phone number, code).
    Text,
    /// Ask for a secret (2FA password).
    Password,
}

pub struct ProtocolPlugin {
    plugin_id: String,
    directory: PathBuf,
    executable: String,
    timeout_seconds: u64,
    secret_keys: Vec<String>,
    secrets: Arc<dyn SecretStore>,
}

impl ProtocolPlugin {
    pub(crate) fn new(
        manifest: &Manifest,
        directory: &Path,
        executable: &str,
        timeout_seconds: u64,
        secrets: Arc<dyn SecretStore>,
    ) -> Self {
        let secret_keys = match &manifest.auth {
            Auth::Interactive { secrets, .. } => secrets.clone(),
            Auth::Secrets { fields, .. } => fields.iter().map(|f| f.key.clone()).collect(),
            Auth::None => Vec::new(),
        };
        Self {
            plugin_id: manifest.id.clone(),
            directory: directory.to_owned(),
            executable: executable.to_owned(),
            timeout_seconds,
            secret_keys,
            secrets,
        }
    }

    pub async fn auth_begin(&self) -> Result<AuthStep, ProtocolError> {
        let params = json!({"secrets": self.current_secrets()?});
        decode(self.call("auth/begin", params).await?)
    }

    pub async fn auth_step(
        &self,
        state: &str,
        input: Option<&str>,
    ) -> Result<AuthStep, ProtocolError> {
        let params = json!({"state": state, "input": input, "secrets": self.current_secrets()?});
        decode(self.call("auth/step", params).await?)
    }

    fn current_secrets(&self) -> Result<BTreeMap<String, String>, ProtocolError> {
        let mut values = BTreeMap::new();
        for key in &self.secret_keys {
            let value = self
                .secrets
                .secret(&self.plugin_id, key)
                .map_err(|e| ProtocolError::Invalid(e.to_string()))?;
            if let Some(value) = value {
                values.insert(key.clone(), value);
            }
        }
        Ok(values)
    }

    /// Sends a post to `chat`: Telegram-style HTML, or a photo with `caption` when `image_url` is
    /// set.
    pub async fn publish(
        &self,
        chat: &str,
        html: &str,
        caption: &str,
        image_url: Option<&str>,
    ) -> Result<(), ProtocolError> {
        let params = json!({
            "chat": chat,
            "html": html,
            "caption": caption,
            "image_url": image_url,
            "secrets": self.current_secrets()?,
        });
        self.call("publish/send", params).await.map(drop)
    }

    #[must_use]
    pub fn plugin_id(&self) -> &str {
        &self.plugin_id
    }

    /// Runs one request and returns its `result`.
    async fn call(&self, method: &str, params: Value) -> Result<Value, ProtocolError> {
        let request = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
        // Resolved per call, so installing the executable later needs no restart.
        let executable = resolve_executable(&self.directory, &self.executable)?;
        let mut child = Command::new(executable)
            .env("PATH", crate::search_path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()?;
        let mut stdin = child.stdin.take().expect("piped");
        let mut stdout = child.stdout.take().expect("piped");
        let body = request.to_string();
        let exchange = async {
            stdin.write_all(body.as_bytes()).await?;
            drop(stdin);
            let mut out = Vec::new();
            (&mut stdout)
                .take(MAX_RESPONSE_BYTES + 1)
                .read_to_end(&mut out)
                .await?;
            if out.len() as u64 > MAX_RESPONSE_BYTES {
                return Ok(None); // too large; the child is killed when dropped
            }
            child.wait().await?;
            Ok::<_, std::io::Error>(Some(out))
        };
        let out = tokio::time::timeout(Duration::from_secs(self.timeout_seconds), exchange)
            .await
            .map_err(|_| ProtocolError::Timeout(self.timeout_seconds))??
            .ok_or_else(|| {
                ProtocolError::Invalid(format!("response larger than {MAX_RESPONSE_BYTES} bytes"))
            })?;
        let response: Value =
            serde_json::from_slice(&out).map_err(|e| ProtocolError::Invalid(e.to_string()))?;
        if let Some(error) = response.get("error") {
            let code = error.get("code").and_then(Value::as_i64).unwrap_or(0);
            if code == AUTH_REQUIRED {
                return Err(ProtocolError::AuthRequired);
            }
            if code == RATE_LIMITED {
                let seconds = error.pointer("/data/retry_after").and_then(Value::as_u64);
                return Err(ProtocolError::RateLimited(seconds.unwrap_or(60)));
            }
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("plugin error")
                .to_owned();
            return Err(ProtocolError::Plugin { code, message });
        }
        response
            .get("result")
            .cloned()
            .ok_or_else(|| ProtocolError::Invalid("no result".into()))
    }
}

#[async_trait]
impl SourceFetcher for ProtocolPlugin {
    async fn fetch(&self, source: &SourceConfig) -> Result<Vec<RawItem>, PortError> {
        let params = json!({
            "query": source.query,
            "settings": source.settings,
            "secrets": self.current_secrets().map_err(PortError::new)?,
        });
        let result = self
            .call("source/fetch", params)
            .await
            .map_err(PortError::new)?;
        let items = result
            .get("items")
            .cloned()
            .unwrap_or(Value::Array(Vec::new()));
        serde_json::from_value(items)
            .map_err(|e| PortError::new(ProtocolError::Invalid(e.to_string())))
    }
}

fn decode<T: serde::de::DeserializeOwned>(value: Value) -> Result<T, ProtocolError> {
    serde_json::from_value(value).map_err(|e| ProtocolError::Invalid(e.to_string()))
}

/// `<plugin>/bin/<name>`, then next to the running daemon (bundled plugins are built into
/// `Bento.app/Contents/MacOS`), then PATH.
fn resolve_executable(directory: &Path, name: &str) -> Result<PathBuf, ProtocolError> {
    let mut candidates = vec![directory.join("bin").join(name)];
    if let Some(dir) = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(Path::to_path_buf))
    {
        candidates.push(dir.join(name));
    }
    candidates.extend(
        crate::search_path()
            .split(':')
            .map(|dir| Path::new(dir).join(name)),
    );
    candidates
        .into_iter()
        .find(|path| path.is_file())
        .ok_or_else(|| ProtocolError::NotFound(name.into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_step_parses_with_defaults() {
        let step: AuthStep = serde_json::from_value(json!({
            "status": "pending", "state": "s1",
            "prompt": {"kind": "qr", "message": "Scan with the Bilibili app", "qr": "https://qr"},
            "poll_after_ms": 2000
        }))
        .unwrap();
        assert_eq!(step.prompt.unwrap().kind, PromptKind::Qr);
        assert!(step.save_secrets.is_empty());
    }
}
