//! `bento-collector`: the composition root. Parses arguments, opens adapters, hands them to use
//! cases. No business logic lives here.

mod config_file;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use bento_app::{FetcherRegistry, Ingestor, RunReport, Scheduler, SourceFetcher, SystemClock};
use bento_domain::{CollectorConfig, RawItem};
use bento_source_rss::RssFetcher;
use bento_store_sqlite::SqliteStore;
use clap::{Parser, Subcommand};
use config_file::ConfigFile;
use uuid::Uuid;

/// Source ID used by `emit-test-item`. Fixed so repeated runs are easy to spot in the app.
const TEST_SOURCE_ID: Uuid = Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0001);

/// How often the daemon reloads its config and checks for due sources.
const TICK: Duration = Duration::from_secs(15);

/// `collector.log` is moved to `collector.log.1` at startup once it grows past this.
const MAX_LOG_BYTES: u64 = 5 * 1024 * 1024;

#[derive(Parser)]
#[command(version, about = "Bento background collector")]
struct Cli {
    /// Directory holding collector.sqlite and collector-config.json. Defaults to
    /// ~/Library/Application Support/Bento.
    #[arg(long, env = "BENTO_DATA_DIR")]
    data_dir: Option<PathBuf>,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Run as a daemon until stopped (default). Logs to collector.log in the data directory.
    Run,
    /// Run every due source once, then exit. Logs to stderr.
    RunOnce,
    /// Write one test item to the outbox, to check the path into the app and iCloud.
    EmitTestItem {
        #[arg(long, default_value = "Hello from bento-collector")]
        title: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let data_dir = match cli.data_dir {
        Some(dir) => dir,
        None => default_data_dir()?,
    };
    std::fs::create_dir_all(&data_dir)
        .with_context(|| format!("creating {}", data_dir.display()))?;
    let command = cli.command.unwrap_or(Command::Run);
    init_logging(matches!(command, Command::Run).then(|| data_dir.join("collector.log")))?;
    let store = open_store(&data_dir)?;

    match command {
        Command::Run => run(&data_dir, store).await,
        Command::RunOnce => run_once(&data_dir, &store).await,
        Command::EmitTestItem { title } => emit_test_item(&store, title),
    }
}

fn default_data_dir() -> Result<PathBuf> {
    Ok(dirs::data_dir()
        .context("no Application Support directory")?
        .join("Bento"))
}

fn init_logging(log_file: Option<PathBuf>) -> Result<()> {
    let filter =
        tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into());
    let builder = tracing_subscriber::fmt().with_env_filter(filter);
    match log_file {
        Some(path) => {
            if std::fs::metadata(&path).is_ok_and(|m| m.len() > MAX_LOG_BYTES) {
                std::fs::rename(&path, path.with_extension("log.1"))?;
            }
            let file = std::fs::File::options()
                .create(true)
                .append(true)
                .open(&path)
                .with_context(|| format!("opening {}", path.display()))?;
            builder
                .with_ansi(false)
                .with_writer(Mutex::new(file))
                .init();
        }
        None => builder.with_writer(std::io::stderr).init(),
    }
    Ok(())
}

fn open_store(data_dir: &Path) -> Result<SqliteStore> {
    let path = data_dir.join("collector.sqlite");
    SqliteStore::open(&path).with_context(|| format!("opening {}", path.display()))
}

fn fetchers() -> Result<FetcherRegistry> {
    let rss: Arc<dyn SourceFetcher> = Arc::new(RssFetcher::new()?);
    Ok(HashMap::from([(
        bento_source_rss::PLUGIN_ID.to_string(),
        rss,
    )]))
}

async fn run(data_dir: &Path, store: SqliteStore) -> Result<()> {
    tracing::info!(version = env!("CARGO_PKG_VERSION"), "collector started");
    let scheduler = Scheduler::new(fetchers()?, &store, &store, SystemClock);
    let mut config_file = ConfigFile::new(data_dir.join("collector-config.json"));
    let mut config = CollectorConfig::default();
    let shutdown = shutdown_signal();
    tokio::pin!(shutdown);
    loop {
        reload(&mut config_file, &mut config);
        match scheduler.run_due(&config).await {
            Ok(reports) => log_reports(&reports),
            Err(error) => tracing::error!(%error, "scheduler failed"),
        }
        tokio::select! {
            result = &mut shutdown => {
                result?;
                break;
            }
            () = tokio::time::sleep(TICK) => {}
        }
    }
    tracing::info!("collector stopped");
    Ok(())
}

async fn run_once(data_dir: &Path, store: &SqliteStore) -> Result<()> {
    let config = ConfigFile::new(data_dir.join("collector-config.json"))
        .reload_if_changed()?
        .unwrap_or_default();
    let reports = Scheduler::new(fetchers()?, store, store, SystemClock)
        .run_due(&config)
        .await?;
    log_reports(&reports);
    Ok(())
}

fn reload(file: &mut ConfigFile, config: &mut CollectorConfig) {
    match file.reload_if_changed() {
        Ok(Some(new)) => {
            tracing::info!(sources = new.sources.len(), "config loaded");
            *config = new;
        }
        Ok(None) => {}
        Err(error) => tracing::warn!(
            error = format!("{error:#}"),
            "config not reloaded; keeping previous"
        ),
    }
}

fn log_reports(reports: &[RunReport]) {
    for report in reports {
        match &report.outcome {
            Ok(ingest) => tracing::info!(
                source = %report.source_id,
                fetched = ingest.fetched,
                too_old = ingest.too_old,
                new = ingest.written,
                "source fetched"
            ),
            Err(error) => tracing::warn!(source = %report.source_id, %error, "source failed"),
        }
    }
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
    let report = Ingestor::new(store, SystemClock).ingest(
        TEST_SOURCE_ID,
        vec![raw],
        chrono::Duration::MAX,
    )?;
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
