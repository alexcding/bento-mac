//! AI providers: OpenAI-compatible HTTP endpoints and command-line tools (Codex, Claude, custom).
//! Each returns the model's JSON answer for an `AiRequest`.

use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use bento_app::{AiError, AiProvider, AiRequest, SecretStore};
use bento_domain::{AiProfile, AiProfileKind, CliPreset};
use nix::sys::signal::{Signal, killpg};
use nix::unistd::Pid;
use regex::Regex;
use serde_json::{Value, json};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

/// Secret namespace for API keys: the key for profile `p` is secret `ai.p`.
pub const SECRET_NAMESPACE: &str = "ai";

pub struct AiProviders {
    http: reqwest::Client,
    secrets: Arc<dyn SecretStore>,
}

impl AiProviders {
    pub fn new(secrets: Arc<dyn SecretStore>) -> Result<Self, reqwest::Error> {
        Ok(Self {
            http: reqwest::Client::builder().build()?,
            secrets,
        })
    }

    async fn http(
        &self,
        profile: &AiProfile,
        base_url: &str,
        request: &AiRequest,
    ) -> Result<Value, AiError> {
        let key = self
            .secrets
            .secret(SECRET_NAMESPACE, &profile.id)
            .map_err(|e| AiError::Failed(e.to_string()))?
            .ok_or_else(|| AiError::Auth(format!("no API key set for {}", profile.name)))?;
        let mut body = json!({
            "messages": [
                {"role": "system", "content": format!("{}\n\nJSON Schema for the answer:\n{}", request.instructions, request.schema)},
                {"role": "user", "content": request.input},
            ],
            "response_format": {"type": "json_object"},
            "temperature": 0.2,
        });
        if let Some(model) = &profile.model {
            body["model"] = json!(model);
        }
        let response = self
            .http
            .post(format!(
                "{}/chat/completions",
                base_url.trim_end_matches('/')
            ))
            .bearer_auth(key)
            .timeout(Duration::from_secs(profile.timeout_seconds))
            .json(&body)
            .send()
            .await
            .map_err(|e| AiError::Failed(e.to_string()))?;
        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|e| AiError::Failed(e.to_string()))?;
        if status.as_u16() == 401 || status.as_u16() == 403 {
            return Err(AiError::Auth(format!("HTTP {status}: {}", snippet(&text))));
        }
        if !status.is_success() {
            return Err(AiError::Failed(format!(
                "HTTP {status}: {}",
                snippet(&text)
            )));
        }
        let reply: Value = serde_json::from_str(&text)
            .map_err(|e| AiError::Failed(format!("invalid response: {e}")))?;
        let content = reply
            .pointer("/choices/0/message/content")
            .and_then(Value::as_str)
            .ok_or_else(|| AiError::Failed("response has no message content".into()))?;
        parse_json_text(content)
    }
}

#[async_trait]
impl AiProvider for AiProviders {
    async fn complete(&self, profile: &AiProfile, request: &AiRequest) -> Result<Value, AiError> {
        match &profile.kind {
            AiProfileKind::Http { base_url } => self.http(profile, base_url, request).await,
            AiProfileKind::Cli { preset, command } => cli(profile, *preset, command, request).await,
        }
    }
}

/// Where a CLI's answer is found.
#[derive(Debug, PartialEq, Eq)]
enum Answer {
    /// JSON (or text containing JSON) on stdout.
    Stdout,
    /// Claude Code's `--output-format json` envelope: `structured_output`, else `result`.
    ClaudeEnvelope,
    /// The file passed as `{output_file}`.
    OutputFile,
}

/// The argv for a CLI profile and where its answer appears.
fn cli_command(
    preset: CliPreset,
    custom: &[String],
    model: Option<&str>,
    schema_file: &str,
    output_file: &str,
    schema: &str,
    workdir: &str,
) -> (Vec<String>, Answer) {
    let s = |v: &str| v.to_owned();
    match preset {
        CliPreset::Codex => {
            let mut argv = vec![s("codex"), s("exec")];
            if let Some(model) = model {
                argv.extend([s("-m"), s(model)]);
            }
            argv.extend([
                s("-s"),
                s("read-only"),
                s("-C"),
                s(workdir),
                s("--skip-git-repo-check"),
                s("--ephemeral"),
                s("--output-schema"),
                s(schema_file),
                s("-o"),
                s(output_file),
                s("-"),
            ]);
            (argv, Answer::OutputFile)
        }
        CliPreset::Claude => {
            let mut argv = vec![
                s("claude"),
                s("-p"),
                s("--output-format"),
                s("json"),
                s("--json-schema"),
                s(schema),
                s("--tools"),
                s(""),
                s("--no-session-persistence"),
            ];
            if let Some(model) = model {
                argv.extend([s("--model"), s(model)]);
            }
            (argv, Answer::ClaudeEnvelope)
        }
        CliPreset::Custom => {
            let uses_file = custom.iter().any(|a| a.contains("{output_file}"));
            let argv = custom
                .iter()
                .map(|a| {
                    a.replace("{model}", model.unwrap_or_default())
                        .replace("{schema_file}", schema_file)
                        .replace("{output_file}", output_file)
                })
                .collect();
            (
                argv,
                if uses_file {
                    Answer::OutputFile
                } else {
                    Answer::Stdout
                },
            )
        }
    }
}

async fn cli(
    profile: &AiProfile,
    preset: CliPreset,
    custom: &[String],
    request: &AiRequest,
) -> Result<Value, AiError> {
    let failed = |e: std::io::Error| AiError::Failed(e.to_string());
    let workdir = tempfile::tempdir().map_err(failed)?;
    let schema_file = workdir.path().join("schema.json");
    let output_file = workdir.path().join("answer.json");
    let schema = request.schema.to_string();
    std::fs::write(&schema_file, &schema).map_err(failed)?;
    let (argv, answer) = cli_command(
        preset,
        custom,
        profile.model.as_deref(),
        &schema_file.display().to_string(),
        &output_file.display().to_string(),
        &schema,
        &workdir.path().display().to_string(),
    );
    let Some((program, arguments)) = argv.split_first() else {
        return Err(AiError::Failed(format!("{} has no command", profile.name)));
    };
    let mut child = Command::new(program)
        .args(arguments)
        .current_dir(workdir.path())
        .env("PATH", search_path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        // Its own process group, so a timeout can stop everything it started (wrappers spawn the
        // real model process as a child).
        .process_group(0)
        .spawn()
        .map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => {
                AiError::Failed(format!("`{program}` is not installed or not on PATH"))
            }
            _ => AiError::Failed(e.to_string()),
        })?;
    let prompt = format!("{}\n\nInput:\n{}", request.instructions, request.input);
    let mut stdin = child.stdin.take().expect("piped");
    let write = async move {
        let _ = stdin.write_all(prompt.as_bytes()).await;
    };
    let group = child
        .id()
        .and_then(|pid| i32::try_from(pid).ok())
        .map(Pid::from_raw);
    let Ok(output) = tokio::time::timeout(Duration::from_secs(profile.timeout_seconds), async {
        tokio::join!(write, child.wait_with_output()).1
    })
    .await
    else {
        if let Some(group) = group {
            let _ = killpg(group, Signal::SIGKILL);
        }
        return Err(AiError::Failed(format!(
            "{} timed out after {} s",
            profile.name, profile.timeout_seconds
        )));
    };
    let output = output.map_err(failed)?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !output.status.success() {
        let message = format!(
            "{program} exited with {}: {}",
            output.status,
            snippet(if stderr.trim().is_empty() {
                &stdout
            } else {
                &stderr
            })
        );
        return Err(classify(message));
    }
    match answer {
        Answer::Stdout => parse_json_text(&stdout),
        Answer::OutputFile => {
            parse_json_text(&std::fs::read_to_string(&output_file).map_err(failed)?)
        }
        Answer::ClaudeEnvelope => {
            let envelope: Value = serde_json::from_str(stdout.trim())
                .map_err(|e| AiError::Failed(format!("invalid output: {e}")))?;
            if envelope.get("is_error").and_then(Value::as_bool) == Some(true) {
                let result = envelope
                    .get("result")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown error");
                return Err(classify(result.to_owned()));
            }
            match envelope.get("structured_output") {
                Some(answer) if answer.is_object() => Ok(answer.clone()),
                _ => parse_json_text(
                    envelope
                        .get("result")
                        .and_then(Value::as_str)
                        .unwrap_or_default(),
                ),
            }
        }
    }
}

/// Treats login, key and permission problems as authentication failures. Status codes count only
/// next to words like "HTTP" or "status", so a request ID or token count containing `401` does not.
fn classify(message: String) -> AiError {
    let lower = message.to_lowercase();
    let phrases = [
        "not logged in",
        "please log in",
        "please login",
        "login required",
        "log in again",
        "unauthorized",
        "authentication failed",
        "authentication error",
        "invalid api key",
        "invalid x-api-key",
        "incorrect api key",
        "api key is missing",
        "permission denied",
        "forbidden",
    ];
    let status = Regex::new(r"\b(?:http|status(?: code)?|error)[ :]*40[13]\b").expect("valid");
    if phrases.iter().any(|p| lower.contains(p)) || status.is_match(&lower) {
        AiError::Auth(message)
    } else {
        AiError::Failed(message)
    }
}

/// Parses a JSON object from model output, tolerating Markdown fences and surrounding text.
fn parse_json_text(text: &str) -> Result<Value, AiError> {
    let trimmed = text.trim();
    let unfenced = trimmed
        .strip_prefix("```json")
        .or_else(|| trimmed.strip_prefix("```"))
        .and_then(|rest| rest.strip_suffix("```"))
        .map_or(trimmed, str::trim);
    if let Ok(value) = serde_json::from_str::<Value>(unfenced)
        && value.is_object()
    {
        return Ok(value);
    }
    match (unfenced.find('{'), unfenced.rfind('}')) {
        (Some(start), Some(end)) if start < end => serde_json::from_str(&unfenced[start..=end])
            .map_err(|e| AiError::Failed(format!("answer is not valid JSON: {e}"))),
        _ => Err(AiError::Failed(format!(
            "answer contains no JSON object: {}",
            snippet(unfenced)
        ))),
    }
}

fn snippet(text: &str) -> String {
    let text = text.trim();
    let cut: String = text.chars().take(400).collect();
    if cut.len() < text.len() {
        format!("{cut}…")
    } else {
        cut
    }
}

/// The inherited PATH plus where Homebrew, pipx and npm-style installs put command-line tools.
fn search_path() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let mut parts = vec![
        "/opt/homebrew/bin".to_owned(),
        "/usr/local/bin".to_owned(),
        format!("{home}/.local/bin"),
        format!("{home}/.cargo/bin"),
    ];
    parts.extend(
        std::env::var("PATH")
            .unwrap_or_default()
            .split(':')
            .filter(|p| !p.is_empty())
            .map(String::from),
    );
    parts.extend(["/usr/bin".to_owned(), "/bin".to_owned()]);
    let mut seen = std::collections::HashSet::new();
    parts.retain(|p| seen.insert(p.clone()));
    parts.join(":")
}

#[cfg(test)]
mod tests {
    use bento_app::PortError;
    use wiremock::matchers::{header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    use super::*;

    struct Keys(Option<&'static str>);

    impl SecretStore for Keys {
        fn secret(&self, plugin: &str, key: &str) -> Result<Option<String>, PortError> {
            assert_eq!((plugin, key), ("ai", "deepseek"));
            Ok(self.0.map(String::from))
        }
    }

    fn request() -> AiRequest {
        AiRequest {
            instructions: "Summarize.".into(),
            input: r#"[{"id":"1","text":"hi"}]"#.into(),
            schema: json!({"type": "object"}),
        }
    }

    fn http_profile(base_url: &str) -> AiProfile {
        AiProfile {
            id: "deepseek".into(),
            name: "DeepSeek".into(),
            kind: AiProfileKind::Http {
                base_url: base_url.into(),
            },
            model: Some("deepseek-chat".into()),
            timeout_seconds: 10,
        }
    }

    fn cli_profile(command: &[&str]) -> AiProfile {
        AiProfile {
            id: "custom".into(),
            name: "Custom".into(),
            kind: AiProfileKind::Cli {
                preset: CliPreset::Custom,
                command: command.iter().map(ToString::to_string).collect(),
            },
            model: Some("m1".into()),
            timeout_seconds: 10,
        }
    }

    #[tokio::test]
    async fn http_sends_key_and_parses_fenced_json() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/v1/chat/completions"))
            .and(header("authorization", "Bearer sk-test"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "choices": [{"message": {"content": "```json\n{\"items\":[]}\n```"}}]
            })))
            .mount(&server)
            .await;
        let providers = AiProviders::new(Arc::new(Keys(Some("sk-test")))).unwrap();

        let answer = providers
            .complete(&http_profile(&format!("{}/v1/", server.uri())), &request())
            .await
            .unwrap();

        assert_eq!(answer, json!({"items": []}));
    }

    #[tokio::test]
    async fn http_401_and_missing_key_are_auth_failures() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(401).set_body_string("bad key"))
            .mount(&server)
            .await;

        let with_key = AiProviders::new(Arc::new(Keys(Some("sk")))).unwrap();
        let error = with_key
            .complete(&http_profile(&server.uri()), &request())
            .await
            .unwrap_err();
        assert!(matches!(error, AiError::Auth(_)), "{error}");

        let without_key = AiProviders::new(Arc::new(Keys(None))).unwrap();
        let error = without_key
            .complete(&http_profile(&server.uri()), &request())
            .await
            .unwrap_err();
        assert!(
            matches!(error, AiError::Auth(ref m) if m.contains("no API key")),
            "{error}"
        );
    }

    #[tokio::test]
    async fn custom_cli_gets_prompt_on_stdin_and_answers_on_stdout() {
        let profile = cli_profile(&[
            "/bin/sh",
            "-c",
            r#"grep -q 'Summarize.' && echo 'Sure: {"items":[{"id":"1","summary":"{model}"}]}'"#,
        ]);
        let providers = AiProviders::new(Arc::new(Keys(None))).unwrap();

        let answer = providers.complete(&profile, &request()).await.unwrap();

        assert_eq!(answer, json!({"items": [{"id": "1", "summary": "m1"}]}));
    }

    #[tokio::test]
    async fn custom_cli_can_answer_in_the_output_file_with_the_schema_file() {
        let profile = cli_profile(&[
            "/bin/sh",
            "-c",
            r#"cat >/dev/null; test -s '{schema_file}' && echo '{"items":[]}' > '{output_file}'"#,
        ]);
        let providers = AiProviders::new(Arc::new(Keys(None))).unwrap();

        assert_eq!(
            providers.complete(&profile, &request()).await.unwrap(),
            json!({"items": []})
        );
    }

    #[tokio::test]
    async fn cli_login_errors_are_auth_failures() {
        let profile = cli_profile(&[
            "/bin/sh",
            "-c",
            "cat >/dev/null; echo 'Error: not logged in, run login' >&2; exit 1",
        ]);
        let providers = AiProviders::new(Arc::new(Keys(None))).unwrap();

        let error = providers.complete(&profile, &request()).await.unwrap_err();

        assert!(matches!(error, AiError::Auth(_)), "{error}");
    }

    #[test]
    fn presets_build_the_documented_commands() {
        let (codex, answer) = cli_command(
            CliPreset::Codex,
            &[],
            Some("gpt-5"),
            "/t/s.json",
            "/t/o.json",
            "{}",
            "/t",
        );
        assert_eq!(answer, Answer::OutputFile);
        assert_eq!(codex[..4], ["codex", "exec", "-m", "gpt-5"]);
        assert!(
            codex
                .windows(2)
                .any(|w| w == ["--output-schema", "/t/s.json"])
        );
        assert_eq!(codex.last().unwrap(), "-");

        let (claude, answer) = cli_command(
            CliPreset::Claude,
            &[],
            None,
            "/t/s.json",
            "/t/o.json",
            "{\"a\":1}",
            "/t",
        );
        assert_eq!(answer, Answer::ClaudeEnvelope);
        assert!(
            claude
                .windows(2)
                .any(|w| w == ["--json-schema", "{\"a\":1}"])
        );
        assert!(claude.windows(2).any(|w| w == ["--tools", ""]), "no tools");
    }

    #[test]
    fn classifies_only_real_authentication_problems() {
        for auth in [
            "Error: Not logged in. Run login.",
            "HTTP 401 Unauthorized",
            "status code 403",
            "Invalid API key",
        ] {
            assert!(matches!(classify(auth.into()), AiError::Auth(_)), "{auth}");
        }
        for other in [
            "prompt is too long: 214013 tokens > 200000",
            "request req_8a401f failed",
            "rate limited (429)",
        ] {
            assert!(
                matches!(classify(other.into()), AiError::Failed(_)),
                "{other}"
            );
        }
    }

    #[tokio::test]
    async fn timeout_kills_the_whole_process_group() {
        let dir = tempfile::tempdir().unwrap();
        let pid_file = dir.path().join("child.pid");
        let script = format!(
            "cat >/dev/null; sleep 30 & echo $! > '{}'; wait",
            pid_file.display()
        );
        let mut profile = cli_profile(&["/bin/sh", "-c", &script]);
        profile.timeout_seconds = 1;
        let providers = AiProviders::new(Arc::new(Keys(None))).unwrap();

        let error = providers.complete(&profile, &request()).await.unwrap_err();

        assert!(error.to_string().contains("timed out"));
        let child: i32 = std::fs::read_to_string(&pid_file)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        let alive = nix::sys::signal::kill(Pid::from_raw(child), None).is_ok();
        assert!(!alive, "the grandchild was killed with the group");
    }

    #[tokio::test]
    async fn http_leaves_out_an_unset_model() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_json(json!({"choices": [{"message": {"content": "{}"}}]})),
            )
            .mount(&server)
            .await;
        let mut profile = http_profile(&server.uri());
        profile.model = None;
        AiProviders::new(Arc::new(Keys(Some("sk"))))
            .unwrap()
            .complete(&profile, &request())
            .await
            .unwrap();

        let body: Value = server.received_requests().await.unwrap()[0]
            .body_json()
            .unwrap();

        assert!(body.get("model").is_none(), "{body}");
    }

    #[test]
    fn parses_json_from_noisy_text() {
        assert_eq!(
            parse_json_text("Here you go:\n{\"a\": 1}\nThanks").unwrap(),
            json!({"a": 1})
        );
        assert!(parse_json_text("no json here").is_err());
    }
}
