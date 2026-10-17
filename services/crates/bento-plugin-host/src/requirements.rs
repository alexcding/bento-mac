//! Checks whether the programs plugins need are installed.

use std::process::Stdio;
use std::time::Duration;

use serde::Serialize;
use tokio::process::Command;

use crate::manifest::Requirement;

const CHECK_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct RequirementStatus {
    pub name: String,
    pub installed: bool,
    /// First line of the check's output (usually a version), or why it failed.
    pub detail: String,
    pub install: String,
}

pub async fn check(requirement: &Requirement) -> RequirementStatus {
    let (installed, detail) = run(&requirement.check).await;
    RequirementStatus {
        name: requirement.name.clone(),
        installed,
        detail,
        install: requirement.install.clone(),
    }
}

async fn run(argv: &[String]) -> (bool, String) {
    let Some((program, arguments)) = argv.split_first() else {
        return (false, "empty check command".into());
    };
    let child = Command::new(program)
        .args(arguments)
        .env("PATH", crate::search_path())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(CHECK_TIMEOUT, child).await {
        Err(_) => (false, "check timed out".into()),
        Ok(Err(error)) if error.kind() == std::io::ErrorKind::NotFound => {
            (false, format!("`{program}` not found"))
        }
        Ok(Err(error)) => (false, error.to_string()),
        Ok(Ok(output)) => {
            let text = if output.stdout.is_empty() {
                output.stderr
            } else {
                output.stdout
            };
            let first = String::from_utf8_lossy(&text)
                .lines()
                .next()
                .unwrap_or_default()
                .trim()
                .to_owned();
            (output.status.success(), first)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn requirement(check: &[&str]) -> Requirement {
        Requirement {
            name: "tool".into(),
            check: check.iter().map(ToString::to_string).collect(),
            install: "brew install tool".into(),
        }
    }

    #[tokio::test]
    async fn reports_installed_with_first_output_line() {
        let status = check(&requirement(&["/bin/echo", "v1.2\nmore"])).await;
        assert!(status.installed);
        assert_eq!(status.detail, "v1.2");
    }

    #[tokio::test]
    async fn reports_missing_programs() {
        let status = check(&requirement(&["definitely-not-a-real-tool-xyz"])).await;
        assert!(!status.installed);
        assert!(status.detail.contains("not found"));
    }

    #[tokio::test]
    async fn non_zero_exit_is_not_installed() {
        assert!(!check(&requirement(&["/usr/bin/false"])).await.installed);
    }
}
