//! Loads plugin folders: `<dir>/<id>/plugin.json` and, for CLI sources, `mapping.json`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use bento_app::{FetcherRegistry, SecretStore, SourceFetcher};

use crate::fetcher::{CliSourceFetcher, compile_routes};
use crate::manifest::{Capability, Manifest, PROTOCOL_VERSION};
use crate::mapping::Mapping;
use crate::protocol::ProtocolPlugin;

/// IDs of sources built into the daemon; plugins cannot use them.
pub const RESERVED_IDS: &[&str] = &["rss"];

/// A plugin that loaded successfully.
pub struct LoadedPlugin {
    pub manifest: Manifest,
    pub directory: PathBuf,
    /// For CLI sources.
    pub fetcher: Option<Arc<CliSourceFetcher>>,
    /// For protocol plugins (sources and interactive login).
    pub protocol: Option<Arc<ProtocolPlugin>>,
}

/// A plugin folder that could not be loaded, shown to the user instead of silently ignored.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LoadError {
    pub directory: PathBuf,
    pub message: String,
}

#[derive(Default)]
pub struct PluginRegistry {
    pub plugins: Vec<LoadedPlugin>,
    pub errors: Vec<LoadError>,
}

impl PluginRegistry {
    /// Loads every plugin folder in `directories`, in order. A plugin ID seen again in a later
    /// directory replaces the earlier one, so user plugins override bundled ones.
    pub fn load(directories: &[PathBuf], secrets: &Arc<dyn SecretStore>) -> Self {
        let mut registry = Self::default();
        for directory in directories {
            let Ok(entries) = std::fs::read_dir(directory) else {
                continue;
            };
            let mut folders: Vec<PathBuf> = entries
                .filter_map(Result::ok)
                .map(|e| e.path())
                .filter(|p| p.join("plugin.json").is_file())
                .collect();
            folders.sort();
            for folder in folders {
                match load_plugin(&folder, secrets) {
                    Ok(plugin) => {
                        registry
                            .plugins
                            .retain(|p| p.manifest.id != plugin.manifest.id);
                        registry.plugins.push(plugin);
                    }
                    Err(message) => registry.errors.push(LoadError {
                        directory: folder,
                        message,
                    }),
                }
            }
        }
        registry
    }

    /// Source fetchers keyed by plugin ID.
    #[must_use]
    pub fn fetchers(&self) -> FetcherRegistry {
        self.plugins
            .iter()
            .filter_map(|p| {
                let fetcher: Arc<dyn SourceFetcher> = match (&p.fetcher, &p.protocol) {
                    (Some(cli), _) => cli.clone(),
                    (None, Some(protocol)) => protocol.clone(),
                    (None, None) => return None,
                };
                Some((p.manifest.id.clone(), fetcher))
            })
            .collect::<HashMap<_, _>>()
    }

    #[must_use]
    pub fn plugin(&self, id: &str) -> Option<&LoadedPlugin> {
        self.plugins.iter().find(|p| p.manifest.id == id)
    }
}

fn load_plugin(folder: &Path, secrets: &Arc<dyn SecretStore>) -> Result<LoadedPlugin, String> {
    let manifest: Manifest = read_json(&folder.join("plugin.json"))?;
    if manifest.protocol != PROTOCOL_VERSION {
        return Err(format!(
            "plugin protocol {} is not supported (this version of Bento supports {PROTOCOL_VERSION})",
            manifest.protocol
        ));
    }
    if RESERVED_IDS.contains(&manifest.id.as_str()) {
        return Err(format!(
            "plugin id `{}` is reserved for a built-in source",
            manifest.id
        ));
    }
    if !manifest
        .id
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    {
        return Err(format!(
            "plugin id `{}` must be lowercase letters, digits and dashes",
            manifest.id
        ));
    }
    let mut fetcher = None;
    let mut protocol = None;
    match (
        &manifest.source,
        manifest.capabilities.contains(&Capability::Source),
    ) {
        (Some(source), true) => match (&source.cli, &source.protocol) {
            (Some(cli), None) => {
                let mapping: Mapping = read_json(&folder.join("mapping.json"))?;
                mapping
                    .validate()
                    .map_err(|e| format!("mapping.json: {e}"))?;
                let routes = compile_routes(cli)
                    .map_err(|e| format!("plugin.json: invalid command match: {e}"))?;
                if cli.commands.iter().any(|c| c.args.is_empty()) {
                    return Err("plugin.json: a command has no arguments".into());
                }
                fetcher = Some(Arc::new(CliSourceFetcher::new(
                    &manifest,
                    cli.clone(),
                    routes,
                    mapping,
                    secrets.clone(),
                )));
            }
            (None, Some(spec)) => {
                protocol = Some(Arc::new(ProtocolPlugin::new(
                    &manifest,
                    folder,
                    &spec.executable,
                    spec.timeout_seconds,
                    secrets.clone(),
                )));
            }
            _ => {
                return Err(
                    "plugin.json: `source` needs exactly one of `cli` and `protocol`".into(),
                );
            }
        },
        (None, true) => {
            return Err("plugin.json: `source` capability without a `source` section".into());
        }
        _ => {}
    }
    Ok(LoadedPlugin {
        manifest,
        directory: folder.to_owned(),
        fetcher,
        protocol,
    })
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T, String> {
    let name = path
        .file_name()
        .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
    let text = std::fs::read_to_string(path).map_err(|e| format!("{name}: {e}"))?;
    serde_json::from_str(&text).map_err(|e| format!("{name}: {e}"))
}
