//! Runs a CLI source: pick the command for the query, run it with a timeout, map its output.

use std::collections::{BTreeMap, HashMap};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use bento_app::{PortError, SecretStore, SourceFetcher};
use bento_domain::{RawItem, SourceConfig};
use regex::Regex;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

use crate::manifest::{CliSource, Manifest};
use crate::mapping::Mapping;
use crate::output;

/// Largest stdout read from a source command.
const MAX_OUTPUT_BYTES: usize = 24 * 1024 * 1024;
/// Largest stderr kept for error messages.
const MAX_STDERR_BYTES: usize = 64 * 1024;
/// Upper bound for a source's `limit` setting.
const MAX_LIMIT: u32 = 100;

#[derive(Debug, thiserror::Error)]
pub enum FetchError {
    #[error("no command matches the query `{0}`")]
    NoCommand(String),
    #[error("`{program}` is not installed or not on PATH")]
    NotInstalled { program: String },
    #[error("could not run `{program}`: {source}")]
    Spawn {
        program: String,
        source: std::io::Error,
    },
    #[error("`{program}` printed more than {limit} bytes; lower the source's limit")]
    TooLarge { program: String, limit: usize },
    #[error("`{program}` timed out after {seconds} s")]
    Timeout { program: String, seconds: u64 },
    #[error("`{program}` exited with {status}: {stderr}")]
    Failed {
        program: String,
        status: String,
        stderr: String,
        /// The start of stdout: some programs print their error there (`--json` modes).
        stdout: String,
    },
}

/// Why reading a command's stdout stopped.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Ended {
    Eof,
    Timeout,
    Truncated,
}

/// A compiled command route.
#[derive(Debug)]
pub(crate) struct Route {
    pattern: Regex,
    args: Vec<String>,
}

pub struct CliSourceFetcher {
    plugin_id: String,
    cli: CliSource,
    routes: Vec<Route>,
    mapping: Mapping,
    secrets: Arc<dyn SecretStore>,
}

impl CliSourceFetcher {
    pub(crate) fn new(
        manifest: &Manifest,
        cli: CliSource,
        routes: Vec<Route>,
        mapping: Mapping,
        secrets: Arc<dyn SecretStore>,
    ) -> Self {
        Self {
            plugin_id: manifest.id.clone(),
            cli,
            routes,
            mapping,
            secrets,
        }
    }

    /// The argv for a query and limit, or `None` if no route matches.
    #[must_use]
    pub fn command_for(&self, query: &str, limit: u32) -> Option<Vec<String>> {
        let query = query.trim();
        self.routes.iter().find_map(|route| {
            let captures = route.pattern.captures(query)?;
            let mut vars =
                HashMap::from([("query", query.to_owned()), ("limit", limit.to_string())]);
            for name in route.pattern.capture_names().flatten() {
                if let Some(value) = captures.name(name) {
                    vars.insert(name, value.as_str().to_owned());
                }
            }
            Some(
                route
                    .args
                    .iter()
                    .map(|arg| substitute(arg, &vars))
                    .collect(),
            )
        })
    }

    /// Maps a command's stdout to raw items (also used by `bento-collector plugin test`).
    #[must_use]
    pub fn map_output(&self, stdout: &str) -> Vec<RawItem> {
        output::documents(stdout, self.cli.output)
            .iter()
            .flat_map(|doc| self.mapping.map(doc))
            .collect()
    }
}

/// `PATH` plus the plugin's `env`, with `{secret.<key>}` values filled from the Keychain. A
/// variable whose secret is not set is left out.
pub(crate) fn environment(
    plugin_id: &str,
    templates: &BTreeMap<String, String>,
    secrets: &dyn SecretStore,
) -> Result<Vec<(String, String)>, PortError> {
    let mut env = vec![("PATH".to_owned(), search_path())];
    for (name, template) in templates {
        match template
            .strip_prefix("{secret.")
            .and_then(|rest| rest.strip_suffix('}'))
        {
            Some(key) => {
                if let Some(value) = secrets.secret(plugin_id, key)? {
                    env.push((name.clone(), value));
                }
            }
            None => env.push((name.clone(), template.clone())),
        }
    }
    Ok(env)
}

/// Runs a command and returns its stdout. Reading stops at `MAX_OUTPUT_BYTES` or at the
/// timeout; either way the child is killed, and the output read so far is used only if
/// `partial_output_ok` (otherwise it is an error).
pub(crate) async fn run_command(
    argv: &[String],
    env: Vec<(String, String)>,
    seconds: u64,
    partial_output_ok: bool,
) -> Result<String, FetchError> {
    let program = argv[0].clone();
    let mut child = Command::new(&program)
        .args(&argv[1..])
        .envs(env)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|source| match source.kind() {
            std::io::ErrorKind::NotFound => FetchError::NotInstalled {
                program: program.clone(),
            },
            _ => FetchError::Spawn {
                program: program.clone(),
                source,
            },
        })?;
    let mut stdout = child.stdout.take().expect("piped");
    let stderr = child.stderr.take().expect("piped");
    let stderr_task = tokio::spawn(drain_stderr(stderr));
    let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
    let spawn_error = |source| FetchError::Spawn {
        program: program.clone(),
        source,
    };

    let mut out = Vec::new();
    let mut chunk = vec![0_u8; 64 * 1024];
    let mut ended = Ended::Eof;
    loop {
        match tokio::time::timeout_at(deadline, stdout.read(&mut chunk)).await {
            Err(_) => {
                ended = Ended::Timeout;
                break;
            }
            Ok(Ok(0)) => break,
            Ok(Ok(n)) => {
                out.extend_from_slice(&chunk[..n]);
                if out.len() >= MAX_OUTPUT_BYTES {
                    out.truncate(MAX_OUTPUT_BYTES);
                    ended = Ended::Truncated;
                    break;
                }
            }
            Ok(Err(source)) => return Err(spawn_error(source)),
        }
    }
    let mut status = None;
    if ended == Ended::Eof {
        match tokio::time::timeout_at(deadline, child.wait()).await {
            Ok(exit) => status = Some(exit.map_err(spawn_error)?),
            Err(_) => ended = Ended::Timeout,
        }
    }
    if status.is_none() {
        let _ = child.kill().await;
    }
    let err = tokio::time::timeout(Duration::from_secs(1), stderr_task)
        .await
        .ok()
        .and_then(Result::ok)
        .unwrap_or_default();
    let partial_ok = partial_output_ok && !out.is_empty();
    match (ended, status) {
        (Ended::Timeout, _) if !partial_ok => {
            return Err(FetchError::Timeout { program, seconds });
        }
        (Ended::Truncated, _) if !partial_ok => {
            return Err(FetchError::TooLarge {
                program,
                limit: MAX_OUTPUT_BYTES,
            });
        }
        (_, Some(status)) if !status.success() && !partial_ok => {
            let stderr = String::from_utf8_lossy(&err);
            let tail: String = stderr
                .trim()
                .chars()
                .rev()
                .take(800)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            return Err(FetchError::Failed {
                program,
                status: status.to_string(),
                stderr: tail,
                stdout: String::from_utf8_lossy(&out).chars().take(4000).collect(),
            });
        }
        _ => {}
    }
    Ok(String::from_utf8_lossy(&out).into_owned())
}

#[async_trait]
impl SourceFetcher for CliSourceFetcher {
    async fn fetch(&self, source: &SourceConfig) -> Result<Vec<RawItem>, PortError> {
        let limit = source
            .settings
            .get("limit")
            .and_then(serde_json::Value::as_u64)
            .map_or(self.cli.default_limit, |n| {
                u32::try_from(n).unwrap_or(MAX_LIMIT)
            })
            .clamp(1, MAX_LIMIT);
        let argv = self
            .command_for(&source.query, limit)
            .ok_or_else(|| PortError::new(FetchError::NoCommand(source.query.clone())))?;
        let env = environment(&self.plugin_id, &self.cli.env, &*self.secrets)?;
        let stdout = run_command(
            &argv,
            env,
            self.cli.timeout_seconds,
            self.cli.partial_output_ok,
        )
        .await
        .map_err(PortError::new)?;
        Ok(self.map_output(&stdout))
    }
}

/// Reads stderr to the end so the child never blocks on it, keeping the first part for messages.
async fn drain_stderr(mut stderr: tokio::process::ChildStderr) -> Vec<u8> {
    let mut kept = Vec::new();
    let mut chunk = [0_u8; 8 * 1024];
    while let Ok(n) = stderr.read(&mut chunk).await {
        if n == 0 {
            break;
        }
        let room = MAX_STDERR_BYTES.saturating_sub(kept.len());
        kept.extend_from_slice(&chunk[..n.min(room)]);
    }
    kept
}

pub(crate) fn compile_routes(cli: &CliSource) -> Result<Vec<Route>, regex::Error> {
    cli.commands
        .iter()
        .map(|command| {
            Ok(Route {
                pattern: Regex::new(&command.pattern)?,
                args: command.args.clone(),
            })
        })
        .collect()
}

/// Replaces `{name}` and `{name|urldecode}`; unknown names are left as written.
fn substitute(template: &str, vars: &HashMap<&str, String>) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(start) = rest.find('{') {
        out.push_str(&rest[..start]);
        let Some(end) = rest[start..].find('}') else {
            break;
        };
        let spec = &rest[start + 1..start + end];
        let (name, filter) = spec.split_once('|').unwrap_or((spec, ""));
        match (vars.get(name), filter) {
            (Some(value), "urldecode") => out.push_str(&url_decode(value)),
            (Some(value), _) => out.push_str(value),
            (None, _) => out.push_str(&rest[start..=start + end]),
        }
        rest = &rest[start + end + 1..];
    }
    out.push_str(rest);
    out
}

fn url_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < bytes.len() => match (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                (Some(high), Some(low)) => {
                    out.push(high << 4 | low);
                    i += 2;
                }
                _ => out.push(b'%'),
            },
            byte => out.push(byte),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex(byte: u8) -> Option<u8> {
    char::from(byte)
        .to_digit(16)
        .and_then(|d| u8::try_from(d).ok())
}

/// The inherited PATH plus where Homebrew, pipx and cargo install programs. A `LaunchAgent` starts
/// with a minimal PATH, so these are added explicitly.
pub(crate) fn search_path() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let mut parts: Vec<String> = vec![
        "/opt/homebrew/bin".into(),
        "/usr/local/bin".into(),
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
    parts.extend(["/usr/bin".into(), "/bin".into()]);
    let mut seen = std::collections::HashSet::new();
    parts.retain(|p| seen.insert(p.clone()));
    parts.join(":")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn substitutes_variables_and_filters() {
        let vars = HashMap::from([
            ("q", "rust%20lang+news".to_owned()),
            ("limit", "5".to_owned()),
        ]);
        assert_eq!(substitute("{q|urldecode}", &vars), "rust lang news");
        assert_eq!(substitute("-n={limit}", &vars), "-n=5");
        assert_eq!(substitute("{unknown}", &vars), "{unknown}");
    }

    #[test]
    fn url_decode_handles_utf8_and_bad_escapes() {
        assert_eq!(url_decode("%E4%B8%AD%E6%96%87"), "中文");
        assert_eq!(url_decode("100%"), "100%");
        assert_eq!(url_decode("a%zzb"), "a%zzb");
        assert_eq!(url_decode("%中"), "%中");
    }

    #[test]
    fn search_path_includes_tool_locations_once() {
        let path = search_path();
        assert!(path.starts_with("/opt/homebrew/bin:/usr/local/bin:"));
        assert_eq!(path.matches("/opt/homebrew/bin").count(), 1);
    }
}
