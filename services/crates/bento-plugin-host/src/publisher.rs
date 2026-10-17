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
        FetchError::Failed { stderr, .. } => {
            let lower = stderr.to_lowercase();
            let has = |words: &[&str]| words.iter().any(|word| lower.contains(word));
            if has(&["duplicate"]) {
                Ok(()) // the same post is already there: an earlier attempt went out
            } else if has(&["rate_limited", "rate limit", "429"]) {
                Err(PublishError::RateLimited(RATE_LIMIT_WAIT))
            } else if has(&[
                "not_authenticated",
                "401",
                "403",
                "unauthorized",
                "forbidden",
            ]) {
                Err(PublishError::Rejected(format!(
                    "sign-in expired; update it in Settings → Plugins ({stderr})"
                )))
            } else if has(&["invalid_input"]) {
                Err(PublishError::Rejected(stderr.clone()))
            } else {
                Err(PublishError::Failed(error.to_string()))
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

    fn failed(stderr: &str) -> FetchError {
        FetchError::Failed {
            program: "twitter".into(),
            status: "exit status: 1".into(),
            stderr: stderr.into(),
        }
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
