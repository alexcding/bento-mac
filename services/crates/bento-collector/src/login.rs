//! `bento-collector plugin auth <id>`: runs a protocol plugin's interactive login and stores the
//! secrets it returns in the Keychain.
//!
//! With `--json`, each step is one JSON line on stdout (`{"status", "prompt", "error"}`) and input
//! is read as one line from stdin when a prompt asks for it; the app drives this mode.

use std::io::{BufRead, Write};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use bento_plugin_host::PluginRegistry;
use bento_plugin_host::protocol::{AuthStatus, AuthStep, PromptKind};
use bento_secrets_keychain::KeychainSecrets;
use serde_json::json;

pub async fn run(
    registry: &PluginRegistry,
    keychain: &KeychainSecrets,
    plugin_id: &str,
    json_mode: bool,
) -> Result<()> {
    let plugin = registry
        .plugin(plugin_id)
        .with_context(|| format!("no plugin named {plugin_id}"))?
        .protocol
        .clone()
        .with_context(|| format!("{plugin_id} has no interactive login"))?;
    let mut step = plugin.auth_begin().await?;
    loop {
        report(&step, json_mode)?;
        match step.status {
            AuthStatus::Done => {
                for (key, value) in &step.save_secrets {
                    keychain.set(plugin_id, key, value)?;
                }
                if !json_mode {
                    println!("Signed in to {plugin_id}.");
                }
                return Ok(());
            }
            AuthStatus::Failed => bail!(
                "{}",
                step.error.clone().unwrap_or_else(|| "login failed".into())
            ),
            AuthStatus::Pending => {}
        }
        let wants_input = step
            .prompt
            .as_ref()
            .is_some_and(|p| matches!(p.kind, PromptKind::Text | PromptKind::Password));
        let input = if wants_input {
            let mut line = String::new();
            if std::io::stdin().lock().read_line(&mut line)? == 0 {
                bail!("login cancelled");
            }
            Some(line.trim().to_owned())
        } else {
            tokio::time::sleep(Duration::from_millis(step.poll_after_ms.unwrap_or(2_000))).await;
            None
        };
        step = plugin.auth_step(&step.state, input.as_deref()).await?;
    }
}

fn report(step: &AuthStep, json_mode: bool) -> Result<()> {
    let mut out = std::io::stdout().lock();
    if json_mode {
        // Secrets never leave the daemon.
        writeln!(
            out,
            "{}",
            json!({"status": step.status, "prompt": step.prompt, "error": step.error})
        )?;
    } else if let Some(prompt) = &step.prompt {
        writeln!(out, "{}", prompt.message)?;
        if let Some(qr) = &prompt.qr {
            writeln!(out, "  QR code content: {qr}")?;
        }
        if matches!(prompt.kind, PromptKind::Text | PromptKind::Password) {
            write!(out, "> ")?;
        }
    }
    out.flush()?;
    Ok(())
}
