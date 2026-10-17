//! `bento-collector`: the composition root. Parses arguments, opens adapters, hands them to use
//! cases. No business logic lives here.

mod config_file;
mod plugins;

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use bento_app::{
    FetcherRegistry, Ingestor, RunReport, Scheduler, SecretStore, SourceFetcher, SystemClock,
};
use bento_domain::{CollectorConfig, RawItem};
use bento_plugin_host::PluginRegistry;
use bento_secrets_keychain::KeychainSecrets;
use bento_source_rss::RssFetcher;
use bento_store_sqlite::SqliteStore;
use clap::{Parser, Subcommand};
use config_file::ConfigFile;
use uuid::Uuid;

/// Source ID used by `emit-test-item`. Fixed so repeated runs are easy to spot in the app.
const TEST_SOURCE_ID: Uuid = Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0001);

/// How often the daemon reloads its config and checks for due sources.
const TICK: Duration = Duration::from_secs(15);

/// How often plugin requirements are re-checked and the catalog republished.
const CATALOG_INTERVAL: Duration = Duration::from_mins(10);

/// `collector.log` is moved to `collector.log.1` at startup once it grows past this.
const MAX_LOG_BYTES: u64 = 5 * 1024 * 1024;

#[derive(Parser)]
#[command(version, about = "Bento background collector")]
struct Cli {
    /// Directory holding collector.sqlite and collector-config.json. Defaults to
    /// ~/Library/Application Support/Bento.
    #[arg(long, env = "BENTO_DATA_DIR")]
    data_dir: Option<PathBuf>,

    /// Extra plugin directory, loaded after the bundled and user plugins. Repeatable.
    #[arg(long = "plugins-dir")]
    plugins_dirs: Vec<PathBuf>,

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
    /// Manage plugin secrets in the Keychain. Values are read from stdin and never printed.
    Secrets {
        #[command(subcommand)]
        action: SecretsAction,
    },
    /// Plugin developer tools.
    Plugin {
        #[command(subcommand)]
        action: PluginAction,
    },
}

#[derive(Subcommand)]
enum SecretsAction {
    /// Store a secret; the value is read from stdin.
    Set { plugin: String, key: String },
    /// Remove a secret.
    Delete { plugin: String, key: String },
    /// Print, as JSON, which of a plugin's declared secrets are set.
    Status { plugin: String },
}

#[derive(Subcommand)]
enum PluginAction {
    /// List loaded plugins and load errors.
    List,
    /// Map a saved command output with a plugin's mapping and print the items as JSON.
    Test {
        /// Plugin folder.
        folder: PathBuf,
        /// File with the command's output.
        output: PathBuf,
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
    let daemon = matches!(command, Command::Run | Command::RunOnce);
    init_logging(
        matches!(command, Command::Run).then(|| data_dir.join("collector.log")),
        daemon,
    )?;
    let keychain = Arc::new(KeychainSecrets::default());
    let secrets: Arc<dyn SecretStore> = keychain.clone();
    let directories = plugins::directories(&data_dir, &cli.plugins_dirs);

    match command {
        Command::Run => {
            run(
                &data_dir,
                open_store(&data_dir)?,
                plugins::load(&directories, &secrets),
            )
            .await
        }
        Command::RunOnce => {
            run_once(
                &data_dir,
                &open_store(&data_dir)?,
                &plugins::load(&directories, &secrets),
            )
            .await
        }
        Command::EmitTestItem { title } => emit_test_item(&open_store(&data_dir)?, title),
        Command::Secrets { action } => {
            secrets_command(&keychain, &plugins::load(&directories, &secrets), action)
        }
        Command::Plugin { action } => plugin_command(&directories, &secrets, action),
    }
}

fn default_data_dir() -> Result<PathBuf> {
    Ok(dirs::data_dir()
        .context("no Application Support directory")?
        .join("Bento"))
}

/// Logs to `log_file` (daemon) or stderr. One-off commands default to warnings only.
fn init_logging(log_file: Option<PathBuf>, verbose: bool) -> Result<()> {
    let default = if verbose { "info" } else { "warn" };
    let filter =
        tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| default.into());
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

/// Built-in RSS plus every loaded source plugin.
fn fetchers(registry: &PluginRegistry) -> Result<FetcherRegistry> {
    let mut fetchers = registry.fetchers();
    let rss: Arc<dyn SourceFetcher> = Arc::new(RssFetcher::new()?);
    fetchers.insert(bento_source_rss::PLUGIN_ID.to_string(), rss);
    Ok(fetchers)
}

async fn run(data_dir: &Path, store: SqliteStore, registry: PluginRegistry) -> Result<()> {
    tracing::info!(version = env!("CARGO_PKG_VERSION"), "collector started");
    let scheduler = Scheduler::new(fetchers(&registry)?, &store, &store, SystemClock);
    let mut catalog_due = tokio::time::Instant::now();
    let mut config_file = ConfigFile::new(data_dir.join("collector-config.json"));
    let mut config = CollectorConfig::default();
    let shutdown = shutdown_signal();
    tokio::pin!(shutdown);
    loop {
        if tokio::time::Instant::now() >= catalog_due {
            if let Err(error) = plugins::publish_catalog(&registry, &store).await {
                tracing::warn!(error = format!("{error:#}"), "plugin catalog not updated");
            }
            catalog_due = tokio::time::Instant::now() + CATALOG_INTERVAL;
        }
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

async fn run_once(data_dir: &Path, store: &SqliteStore, registry: &PluginRegistry) -> Result<()> {
    let config = ConfigFile::new(data_dir.join("collector-config.json"))
        .reload_if_changed()?
        .unwrap_or_default();
    plugins::publish_catalog(registry, store).await?;
    let reports = Scheduler::new(fetchers(registry)?, store, store, SystemClock)
        .run_due(&config)
        .await?;
    log_reports(&reports);
    Ok(())
}

fn secrets_command(
    keychain: &KeychainSecrets,
    registry: &PluginRegistry,
    action: SecretsAction,
) -> Result<()> {
    match action {
        SecretsAction::Set { plugin, key } => {
            let mut value = String::new();
            std::io::stdin().read_to_string(&mut value)?;
            let value = value.trim_end_matches(['\n', '\r']);
            anyhow::ensure!(!value.is_empty(), "no value on stdin");
            keychain.set(&plugin, &key, value)?;
        }
        SecretsAction::Delete { plugin, key } => keychain.delete(&plugin, &key)?,
        SecretsAction::Status { plugin } => {
            let manifest = &registry
                .plugin(&plugin)
                .with_context(|| format!("no plugin named {plugin}"))?
                .manifest;
            let keys: Vec<&str> = match &manifest.auth {
                bento_plugin_host::manifest::Auth::Secrets { fields } => {
                    fields.iter().map(|f| f.key.as_str()).collect()
                }
                bento_plugin_host::manifest::Auth::None => Vec::new(),
            };
            let mut status = serde_json::Map::new();
            for key in keys {
                status.insert(key.into(), keychain.secret(&plugin, key)?.is_some().into());
            }
            println!("{}", serde_json::Value::Object(status));
        }
    }
    Ok(())
}

fn plugin_command(
    directories: &[PathBuf],
    secrets: &Arc<dyn SecretStore>,
    action: PluginAction,
) -> Result<()> {
    match action {
        PluginAction::List => {
            let registry = PluginRegistry::load(directories, secrets);
            for plugin in &registry.plugins {
                println!(
                    "{}\t{}\t{}",
                    plugin.manifest.id,
                    plugin.manifest.version,
                    plugin.directory.display()
                );
            }
            for error in &registry.errors {
                println!("error\t{}\t{}", error.directory.display(), error.message);
            }
        }
        PluginAction::Test { folder, output } => {
            let parent = folder
                .parent()
                .context("plugin folder has no parent")?
                .to_owned();
            let registry = PluginRegistry::load(&[parent], secrets);
            if let Some(error) = registry.errors.iter().find(|e| e.directory == folder) {
                anyhow::bail!("{}", error.message);
            }
            let plugin = registry
                .plugins
                .iter()
                .find(|p| p.directory == folder)
                .context("no plugin.json in that folder")?;
            let fetcher = plugin.fetcher.as_ref().context("plugin has no source")?;
            let items = fetcher.map_output(&std::fs::read_to_string(&output)?);
            println!("{}", serde_json::to_string_pretty(&items)?);
            eprintln!("{} items", items.len());
        }
    }
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
