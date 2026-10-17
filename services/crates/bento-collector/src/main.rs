//! `bento-collector`: the composition root. Parses arguments, opens adapters, hands them to use
//! cases. No business logic lives here.

mod config_file;
mod deliver;
mod login;
mod plugins;

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use bento_ai::AiProviders;
use bento_app::{
    AiCallRecorder, DetailExtractor, Enricher, Enrichment, FetcherRegistry, Ingestor, RunReport,
    Scheduler, SecretStore, SourceFetcher, SystemClock,
};
use bento_domain::{CollectorConfig, RawItem};
use bento_extract::ArticleExtractor;
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

/// How long shutdown waits for a post in flight (each send times out after 30 s; launchd allows
/// 20 s before it kills the process, so this stays below).
const DELIVERY_SHUTDOWN: Duration = Duration::from_secs(15);
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
    ///
    /// With `--source`, run only that source now, due or not, and print a JSON summary on stdout;
    /// with `--dry-run` as well, print the items it would add without storing anything.
    RunOnce {
        #[arg(long)]
        source: Option<Uuid>,
        #[arg(long, requires = "source")]
        dry_run: bool,
    },
    /// Write one test item to the outbox, to check the path into the app and iCloud.
    EmitTestItem {
        #[arg(long, default_value = "Hello from bento-collector")]
        title: String,
    },
    /// Mark items as already collected, so this collector never processes or publishes them.
    /// Used when another Mac's collector hands over.
    Seen {
        #[command(subcommand)]
        action: SeenAction,
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
enum SeenAction {
    /// Read item IDs (one UUID per line) from stdin and mark them seen. Prints how many.
    Import,
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
    /// Sign in to a plugin with an interactive login (QR code, phone code).
    Auth {
        plugin: String,
        /// One JSON line per step on stdout; input read from stdin (used by the app).
        #[arg(long)]
        json: bool,
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
    let daemon = matches!(command, Command::Run | Command::RunOnce { .. });
    init_logging(
        matches!(command, Command::Run).then(|| data_dir.join("collector.log")),
        daemon,
    )?;
    let keychain = Arc::new(KeychainSecrets::default());
    let secrets: Arc<dyn SecretStore> = keychain.clone();
    let directories = plugins::directories(&data_dir, &cli.plugins_dirs);

    match command {
        Command::Run => {
            let registry = plugins::load(&directories, &secrets);
            run(
                &data_dir,
                Arc::new(open_store(&data_dir)?),
                registry,
                secrets,
            )
            .await
        }
        Command::RunOnce { source, dry_run } => {
            let registry = plugins::load(&directories, &secrets);
            let store = Arc::new(open_store(&data_dir)?);
            run_once(&data_dir, &store, &registry, &secrets, source, dry_run).await
        }
        Command::EmitTestItem { title } => emit_test_item(&open_store(&data_dir)?, title),
        Command::Seen {
            action: SeenAction::Import,
        } => import_seen(&open_store(&data_dir)?, std::io::stdin().lock()),
        Command::Secrets { action } => {
            secrets_command(&keychain, &plugins::load(&directories, &secrets), action)
        }
        Command::Plugin {
            action: PluginAction::Auth { plugin, json },
        } => {
            login::run(
                &plugins::load(&directories, &secrets),
                &keychain,
                &plugin,
                json,
            )
            .await
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

/// Article extraction and AI tasks, with AI calls logged to the store.
fn enrichment(
    store: &Arc<SqliteStore>,
    secrets: &Arc<dyn SecretStore>,
) -> Result<Arc<dyn Enricher>> {
    let extractor: Arc<dyn DetailExtractor> = Arc::new(ArticleExtractor::new()?);
    let recorder: Arc<dyn AiCallRecorder> = store.clone();
    Ok(Arc::new(Enrichment::new(
        Some(extractor),
        Arc::new(AiProviders::new(secrets.clone())?),
        recorder,
        Arc::new(SystemClock),
    )))
}

/// Built-in RSS plus every loaded source plugin.
fn fetchers(registry: &PluginRegistry) -> Result<FetcherRegistry> {
    let mut fetchers = registry.fetchers();
    let rss: Arc<dyn SourceFetcher> = Arc::new(RssFetcher::new()?);
    fetchers.insert(bento_source_rss::PLUGIN_ID.to_string(), rss);
    Ok(fetchers)
}

async fn run(
    data_dir: &Path,
    store: Arc<SqliteStore>,
    registry: PluginRegistry,
    secrets: Arc<dyn SecretStore>,
) -> Result<()> {
    tracing::info!(version = env!("CARGO_PKG_VERSION"), "collector started");
    let scheduler = Scheduler::new(fetchers(&registry)?, &*store, &*store, SystemClock)
        .with_enricher(enrichment(&store, &secrets)?);
    let mut catalog_due = tokio::time::Instant::now();
    let mut config_file = ConfigFile::new(data_dir.join("collector-config.json"));
    let mut config = CollectorConfig::default();
    let (stop_delivery, delivery_stopped) = tokio::sync::watch::channel(false);
    let delivery = deliver::spawn(data_dir, store.clone(), secrets.clone(), delivery_stopped);
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
        // A run in progress is dropped on shutdown, which stops its child processes; anything not
        // yet stored is fetched again next time.
        tokio::select! {
            result = scheduler.run_due(&config) => match result {
                Ok(reports) => log_reports(&reports),
                Err(error) => tracing::error!(%error, "scheduler failed"),
            },
            result = &mut shutdown => {
                result?;
                break;
            }
        }
        tokio::select! {
            result = &mut shutdown => {
                result?;
                break;
            }
            () = tokio::time::sleep(TICK) => {}
        }
    }
    stop_delivery.send_replace(true);
    if tokio::time::timeout(DELIVERY_SHUTDOWN, delivery)
        .await
        .is_err()
    {
        tracing::warn!("a post was still sending at shutdown");
    }
    tracing::info!("collector stopped");
    Ok(())
}

async fn run_once(
    data_dir: &Path,
    store: &Arc<SqliteStore>,
    registry: &PluginRegistry,
    secrets: &Arc<dyn SecretStore>,
    source_id: Option<Uuid>,
    dry_run: bool,
) -> Result<()> {
    let config = ConfigFile::new(data_dir.join("collector-config.json"))
        .reload_if_changed()?
        .unwrap_or_default();
    let scheduler = Scheduler::new(fetchers(registry)?, &**store, &**store, SystemClock)
        .with_enricher(enrichment(store, secrets)?);
    let Some(source_id) = source_id else {
        plugins::publish_catalog(registry, store).await?;
        log_reports(&scheduler.run_due(&config).await?);
        return Ok(());
    };
    let source = config
        .sources
        .iter()
        .find(|s| s.id == source_id)
        .with_context(|| format!("no source {source_id} in the config"))?;
    let summary = if dry_run {
        let preview = scheduler.dry_run(source, &config).await?;
        let (prepared, enrich) = (preview.prepared, preview.enrich);
        let items: Vec<serde_json::Value> = prepared
            .items
            .iter()
            .map(|n| serde_json::json!({"item": n.item, "detail": n.body_markdown}))
            .collect();
        serde_json::json!({
            "fetched": prepared.fetched, "too_old": prepared.too_old, "items": items,
            "articles": enrich.details_extracted, "ai_failures": enrich.ai_failures,
            "backlog_skipped": preview.backlog_skipped,
        })
    } else {
        let report = scheduler.run_now(source, &config).await?;
        log_reports(std::slice::from_ref(&report));
        match &report.outcome {
            Ok(ingest) => serde_json::json!({
                "fetched": ingest.fetched, "too_old": ingest.too_old, "new": ingest.written,
                "backlog_skipped": ingest.backlog_skipped, "articles": report.enrich.details_extracted,
                "ai_failures": report.enrich.ai_failures,
            }),
            Err(error) => serde_json::json!({"error": error.to_string()}),
        }
    };
    println!("{summary}");
    Ok(())
}

/// Marks every UUID line of `input` seen; blank and invalid lines are skipped.
fn import_seen(store: &SqliteStore, input: impl std::io::BufRead) -> Result<()> {
    let mut ids = Vec::new();
    for line in input.lines() {
        if let Ok(id) = Uuid::parse_str(line?.trim()) {
            ids.push(id);
        }
    }
    for chunk in ids.chunks(5_000) {
        bento_app::Outbox::mark_seen(store, chunk)?;
    }
    println!("{}", ids.len());
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
                bento_plugin_host::manifest::Auth::Interactive { secrets } => {
                    secrets.iter().map(String::as_str).collect()
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
        PluginAction::Auth { .. } => unreachable!("handled in main"),
        PluginAction::Test { folder, output } => {
            let folder = folder
                .canonicalize()
                .with_context(|| folder.display().to_string())?;
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

pub(crate) fn reload(file: &mut ConfigFile, config: &mut CollectorConfig) {
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
                articles = report.enrich.details_extracted,
                article_failures = report.enrich.detail_failures,
                "source fetched"
            ),
            Err(error) => tracing::warn!(source = %report.source_id, %error, "source failed"),
        }
        for failure in &report.enrich.ai_failures {
            tracing::warn!(source = %report.source_id, %failure, "AI task failed; kept the source text");
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
    fn import_seen_marks_valid_ids_and_skips_junk() {
        let dir = tempfile::tempdir().unwrap();
        let store = open_store(dir.path()).unwrap();
        let known = Uuid::from_u128(7);

        import_seen(&store, format!("{known}\n\nnot-a-uuid\n").as_bytes()).unwrap();

        assert!(
            bento_app::Outbox::unseen(&store, &[known, Uuid::from_u128(8)])
                .unwrap()
                .contains(&Uuid::from_u128(8))
        );
        assert!(
            !bento_app::Outbox::unseen(&store, &[known])
                .unwrap()
                .contains(&known)
        );
    }

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
