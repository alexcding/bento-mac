//! `bento-collector`: the composition root. Parses arguments, opens adapters, hands them to use
//! cases. No business logic lives here.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use bento_app::{Ingestor, SystemClock};
use bento_domain::RawItem;
use bento_store_sqlite::SqliteStore;
use clap::{Parser, Subcommand};
use uuid::Uuid;

/// Source ID used by `emit-test-item`. Fixed so repeated runs are easy to spot in the app.
const TEST_SOURCE_ID: Uuid = Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0001);

#[derive(Parser)]
#[command(version, about = "Bento background collector")]
struct Cli {
    /// Directory holding collector.sqlite. Defaults to ~/Library/Application Support/Bento.
    #[arg(long, env = "BENTO_DATA_DIR")]
    data_dir: Option<PathBuf>,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Run as a daemon until stopped (default).
    Run,
    /// Write one test item to the outbox, to check the path into the app and iCloud.
    EmitTestItem {
        #[arg(long, default_value = "Hello from bento-collector")]
        title: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let cli = Cli::parse();
    let data_dir = match cli.data_dir {
        Some(dir) => dir,
        None => default_data_dir()?,
    };
    std::fs::create_dir_all(&data_dir)
        .with_context(|| format!("creating {}", data_dir.display()))?;
    let store = open_store(&data_dir)?;

    match cli.command.unwrap_or(Command::Run) {
        Command::Run => run(store).await,
        Command::EmitTestItem { title } => emit_test_item(&store, title),
    }
}

fn default_data_dir() -> Result<PathBuf> {
    Ok(dirs::data_dir()
        .context("no Application Support directory")?
        .join("Bento"))
}

fn open_store(data_dir: &Path) -> Result<SqliteStore> {
    let path = data_dir.join("collector.sqlite");
    SqliteStore::open(&path).with_context(|| format!("opening {}", path.display()))
}

async fn run(_store: SqliteStore) -> Result<()> {
    tracing::info!(version = env!("CARGO_PKG_VERSION"), "collector started");
    // The scheduler and the control socket arrive in phase 1.
    shutdown_signal().await?;
    tracing::info!("collector stopped");
    Ok(())
}

/// Resolves on Ctrl-C or SIGTERM (what launchd sends when stopping an agent).
async fn shutdown_signal() -> Result<()> {
    use tokio::signal::unix::{SignalKind, signal};
    let mut terminate = signal(SignalKind::terminate()).context("installing SIGTERM handler")?;
    tokio::select! {
        result = tokio::signal::ctrl_c() => result.context("waiting for Ctrl-C")?,
        _ = terminate.recv() => {}
    }
    Ok(())
}

fn emit_test_item(store: &SqliteStore, title: String) -> Result<()> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .context("system clock before 1970")?;
    let raw = RawItem {
        external_id: format!("test-{}", now.as_millis()),
        title: Some(title),
        text: "Written by `bento-collector emit-test-item`.".into(),
        body_markdown: Some(
            "# Test item\n\nIf you can read this on another device, sync works.".into(),
        ),
        ..RawItem::default()
    };
    let report = Ingestor::new(store, SystemClock).ingest(TEST_SOURCE_ID, vec![raw])?;
    tracing::info!(written = report.written, "test item written to outbox");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emit_test_item_writes_one_row() {
        let dir = tempfile::tempdir().unwrap();
        let store = open_store(dir.path()).unwrap();

        emit_test_item(&store, "t".into()).unwrap();

        let rows = store.outbox_after(0, 10).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].item.source_id, TEST_SOURCE_ID);
        assert!(rows[0].detail.is_some());
    }
}
