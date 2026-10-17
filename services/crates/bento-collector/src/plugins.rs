//! Plugin loading and the `plugins` catalog the app reads.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::Result;
use bento_app::SecretStore;
use bento_plugin_host::{PluginRegistry, requirements};
use bento_store_sqlite::{PluginCatalogEntry, SqliteStore};

/// Bundled plugins (`Bento.app/Contents/Resources/plugins`, next to this binary in
/// `Contents/MacOS`), then user plugins, then any given explicitly. Later directories override.
pub fn directories(data_dir: &Path, extra: &[PathBuf]) -> Vec<PathBuf> {
    let mut directories = Vec::new();
    if let Some(bundle_contents) = std::env::current_exe()
        .ok()
        .and_then(|exe| Some(exe.parent()?.parent()?.to_owned()))
    {
        directories.push(bundle_contents.join("Resources/plugins"));
    }
    directories.push(data_dir.join("Plugins"));
    directories.extend(extra.iter().cloned());
    directories
}

pub fn load(directories: &[PathBuf], secrets: &Arc<dyn SecretStore>) -> PluginRegistry {
    let registry = PluginRegistry::load(directories, secrets);
    for plugin in &registry.plugins {
        tracing::info!(plugin = %plugin.manifest.id, directory = %plugin.directory.display(), "plugin loaded");
    }
    for error in &registry.errors {
        tracing::warn!(directory = %error.directory.display(), error = %error.message, "plugin not loaded");
    }
    registry
}

/// Checks every plugin's requirements and replaces the catalog. Includes the built-in RSS source
/// so Settings lists every source type in one place.
pub async fn publish_catalog(registry: &PluginRegistry, store: &SqliteStore) -> Result<()> {
    let mut entries = vec![rss_entry()];
    // Every requirement check runs at once, so one slow check does not hold up the others.
    let checks = registry.plugins.iter().map(|plugin| {
        futures::future::join_all(plugin.manifest.requires.iter().map(requirements::check))
    });
    let statuses_per_plugin = futures::future::join_all(checks).await;
    for (plugin, statuses) in registry.plugins.iter().zip(statuses_per_plugin) {
        entries.push(PluginCatalogEntry {
            id: plugin.manifest.id.clone(),
            name: plugin.manifest.name.clone(),
            version: plugin.manifest.version.clone(),
            directory: plugin.directory.display().to_string(),
            manifest: serde_json::to_string(&plugin.manifest)?,
            requirements: serde_json::to_string(&statuses)?,
            error: None,
        });
    }
    for error in &registry.errors {
        let folder = error
            .directory
            .file_name()
            .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
        entries.push(PluginCatalogEntry {
            id: format!("error:{}", error.directory.display()),
            name: folder,
            version: String::new(),
            directory: error.directory.display().to_string(),
            manifest: "{}".into(),
            requirements: "[]".into(),
            error: Some(error.message.clone()),
        });
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_millis();
    store.replace_plugin_catalog(&entries, i64::try_from(now).unwrap_or(i64::MAX))?;
    Ok(())
}

fn rss_entry() -> PluginCatalogEntry {
    let manifest = serde_json::json!({
        "id": bento_source_rss::PLUGIN_ID,
        "name": "RSS / Atom",
        "version": env!("CARGO_PKG_VERSION"),
        "protocol": bento_plugin_host::manifest::PROTOCOL_VERSION,
        "capabilities": ["source"],
        "description": "Any RSS or Atom feed. Built in.",
        "source": {"default_interval_minutes": 30, "query_hint": "Feed URL"}
    });
    PluginCatalogEntry {
        id: bento_source_rss::PLUGIN_ID.into(),
        name: "RSS / Atom".into(),
        version: env!("CARGO_PKG_VERSION").into(),
        directory: "built-in".into(),
        manifest: manifest.to_string(),
        requirements: "[]".into(),
        error: None,
    }
}
