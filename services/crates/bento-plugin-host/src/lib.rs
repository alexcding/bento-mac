//! Bento plugins: a folder per plugin with `plugin.json` (manifest), `mapping.json` (output to raw
//! items) and optionally `settings.schema.json`. Source plugins wrap an external command; the host
//! routes the query to a command, runs it with a timeout and the plugin's secrets in its
//! environment, and maps the output.

mod fetcher;
pub mod manifest;
pub mod mapping;
mod output;
pub mod protocol;
mod registry;
pub mod requirements;

pub use fetcher::{CliSourceFetcher, FetchError};
pub use registry::{LoadError, LoadedPlugin, PluginRegistry};

pub(crate) use fetcher::search_path;
