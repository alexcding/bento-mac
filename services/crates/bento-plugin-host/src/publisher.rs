//! Posts as the user by running a plugin's publish command (`plugin.json` → `publish.cli`).

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use bento_app::{PublishError, SecretStore};
use bento_domain::Message;

use crate::fetcher::{FetchError, environment, run_command};
use crate::manifest::{CliPublish, Manifest};

/// Wait used when a command reports a rate limit without saying how long.
const RATE_LIMIT_WAIT: Duration = Duration::from_mins(15);

pub struct CliPublisher {
    plugin_id: String,
    spec: CliPublish,
    secrets: Arc<dyn SecretStore>,
}

impl CliPublisher {
    pub(crate) fn new(
        manifest: &Manifest,
        spec: CliPublish,
        secrets: Arc<dyn SecretStore>,
    ) -> Self {
        Self {
            plugin_id: manifest.id.clone(),
            spec,
            secrets,
        }
    }

    /// The argv for a post, with `image` (a local file) attached when given.
    #[must_use]
    pub fn command_for(&self, message: &Message, image: Option<&Path>) -> Vec<String> {
        let text = message.short_text(&self.spec.text);
        let mut argv: Vec<String> = self
            .spec
            .args
            .iter()
            .map(|arg| arg.replace("{text}", &text))
            .collect();
        if let Some(image) = image {
            let image = image.to_string_lossy();
            let at = argv
                .iter()
                .position(|arg| arg == "--")
                .unwrap_or(argv.len());
            let extra = self
                .spec
                .image_args
                .iter()
                .map(|arg| arg.replace("{image}", &image));
            argv.splice(at..at, extra);
        }
        argv
    }

    /// Runs the publish command. Its error output decides what happens next: a rate limit waits,
    /// an expired login or invalid post is refused for good, a duplicate means it was already
    /// posted, and a timeout is never retried.
    pub async fn publish(
        &self,
        message: &Message,
        image: Option<&Path>,
    ) -> Result<(), PublishError> {
        let env = environment(&self.plugin_id, &self.spec.env, &*self.secrets)
            .map_err(|e| PublishError::Failed(format!("reading the Keychain failed: {e}")))?;
        match run_command(
            &self.command_for(message, image),
            env,
            self.spec.timeout_seconds,
            false,
        )
        .await
        {
            Ok(_) => Ok(()),
            Err(error) => classify(&error),
        }
    }
}

fn classify(error: &FetchError) -> Result<(), PublishError> {
    match error {
        FetchError::Timeout { .. } => Err(PublishError::TimedOut(error.to_string())),
        FetchError::NotInstalled { .. } | FetchError::NoCommand(_) => {
            Err(PublishError::Rejected(error.to_string()))
        }
        FetchError::Failed { stderr, stdout, .. } => {
            // `--json` commands print `{"ok": false, "error": {"code", "message"}}` on stdout.
            let json: serde_json::Value = serde_json::from_str(stdout.trim()).unwrap_or_default();
            let code = json
                .pointer("/error/code")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("");
            let message = json
                .pointer("/error/message")
                .and_then(serde_json::Value::as_str)
                .map_or_else(|| stderr.trim().to_owned(), str::to_owned);
            let lower = format!("{message} {stderr}").to_lowercase();
            let has = |words: &[&str]| words.iter().any(|word| lower.contains(word));
            // X's numbered errors: 187 duplicate; 88, 344, 348, 349 limits; 186 too long.
            if has(&["duplicate", "(187)"]) {
                Ok(()) // the same post is already there: an earlier attempt went out
            } else if code == "rate_limited"
                || has(&[
                    "rate_limited",
                    "rate limit",
                    "429",
                    "(88)",
                    "(344)",
                    "(348)",
                    "(349)",
                    "daily limit",
                ])
            {
                Err(PublishError::RateLimited(RATE_LIMIT_WAIT))
            } else if code == "not_authenticated"
                || has(&[
                    "not_authenticated",
                    "401",
                    "403",
                    "unauthorized",
                    "forbidden",
                ])
            {
                Err(PublishError::Rejected(format!(
                    "sign-in expired; update it in Settings → Plugins ({message})"
                )))
            } else if code == "invalid_input" || has(&["invalid_input", "(186)", "too long"]) {
                Err(PublishError::Rejected(message))
            } else {
                Err(PublishError::Failed(if message.is_empty() {
                    error.to_string()
                } else {
                    message
                }))
            }
        }
        FetchError::Spawn { .. } | FetchError::TooLarge { .. } => {
            Err(PublishError::Failed(error.to_string()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn failed_with(stdout: &str, stderr: &str) -> FetchError {
        FetchError::Failed {
            program: "twitter".into(),
            status: "exit status: 1".into(),
            stderr: stderr.into(),
            stdout: stdout.into(),
        }
    }

    fn failed(stderr: &str) -> FetchError {
        failed_with("", stderr)
    }

    #[test]
    fn reads_the_structured_error_on_stdout() {
        let json = |code: &str, message: &str| {
            format!(
                r#"{{"ok": false, "schema_version": "1", "error": {{"code": "{code}", "message": "{message}"}}}}"#
            )
        };
        let duplicate = json(
            "api_error",
            "Twitter API returned errors: Status is a duplicate. (187)",
        );
        assert!(classify(&failed_with(&duplicate, "")).is_ok());
        let expired = json("not_authenticated", "Cookie expired");
        assert!(matches!(
            classify(&failed_with(&expired, "")),
            Err(PublishError::Rejected(_))
        ));
        let daily = json(
            "api_error",
            "You are over the daily limit for sending posts. (344)",
        );
        assert!(matches!(
            classify(&failed_with(&daily, "")),
            Err(PublishError::RateLimited(_))
        ));
        let other = json("api_error", "Something broke");
        assert!(
            matches!(classify(&failed_with(&other, "")), Err(PublishError::Failed(m)) if m == "Something broke")
        );
    }

    #[test]
    fn classifies_command_failures() {
        assert!(classify(&failed("Error: Status is a duplicate. (187)")).is_ok());
        assert!(matches!(
            classify(&failed("{\"code\": \"rate_limited\"}")),
            Err(PublishError::RateLimited(_))
        ));
        assert!(matches!(
            classify(&failed("not_authenticated: login required")),
            Err(PublishError::Rejected(_))
        ));
        assert!(matches!(
            classify(&failed("api_error: something")),
            Err(PublishError::Failed(_))
        ));
        let timeout = FetchError::Timeout {
            program: "twitter".into(),
            seconds: 60,
        };
        assert!(matches!(classify(&timeout), Err(PublishError::TimedOut(_))));
    }
}
