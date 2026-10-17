//! Interfaces the use cases need from the outside world.

use async_trait::async_trait;
use bento_domain::{FeedItem, RawItem, SourceConfig};
use chrono::{DateTime, Utc};
use thiserror::Error;
use uuid::Uuid;

/// Failure inside an adapter. Use cases pass it through untouched.
#[derive(Debug, Error)]
#[error(transparent)]
pub struct PortError(#[from] Box<dyn std::error::Error + Send + Sync>);

impl PortError {
    pub fn new(error: impl std::error::Error + Send + Sync + 'static) -> Self {
        Self(Box::new(error))
    }

    pub fn msg(message: impl Into<String>) -> Self {
        Self(message.into().into())
    }
}

/// One processed item handed to the Mac app, which saves it to the synced database.
#[derive(Clone, Debug, PartialEq)]
pub struct OutboxEntry {
    pub item: FeedItem,
    /// Compressed detail Markdown (see `bento_domain::detail`).
    pub detail: Option<Vec<u8>>,
}

pub trait Outbox {
    /// Appends, atomically and in order, the entries whose item IDs were never appended before.
    /// Returns how many were appended.
    fn append_new(&self, entries: &[OutboxEntry]) -> Result<usize, PortError>;
}

pub trait Clock {
    fn now(&self) -> DateTime<Utc>;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> DateTime<Utc> {
        Utc::now()
    }
}

/// Plugin secrets (cookies, tokens), stored in the Keychain by the daemon itself so values never
/// leave it.
pub trait SecretStore: Send + Sync {
    fn secret(&self, plugin_id: &str, key: &str) -> Result<Option<String>, PortError>;
}

/// Fetches raw items for one source. One implementation per plugin.
#[async_trait]
pub trait SourceFetcher: Send + Sync {
    async fn fetch(&self, source: &SourceConfig) -> Result<Vec<RawItem>, PortError>;
}

/// Scheduling state for one source. Mirrored to the app as `source_state` in `collector.sqlite`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SourceState {
    pub source_id: Uuid,
    pub last_run_at: Option<DateTime<Utc>>,
    pub next_run_at: DateTime<Utc>,
    pub consecutive_failures: u32,
    pub last_error: Option<String>,
    /// New items written by the last successful run.
    pub last_new_items: usize,
}

/// One source run, kept for the app's run history and performance view.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunRecord {
    pub source_id: Uuid,
    pub started_at: DateTime<Utc>,
    pub duration_ms: u64,
    pub fetched: usize,
    pub too_old: usize,
    pub new_items: usize,
    pub error: Option<String>,
}

pub trait SourceStateStore {
    fn source_state(&self, source_id: Uuid) -> Result<Option<SourceState>, PortError>;
    fn save_source_state(&self, state: &SourceState) -> Result<(), PortError>;
    fn record_run(&self, run: &RunRecord) -> Result<(), PortError>;
}

impl<T: Outbox + ?Sized> Outbox for &T {
    fn append_new(&self, entries: &[OutboxEntry]) -> Result<usize, PortError> {
        (**self).append_new(entries)
    }
}

impl<T: Clock + ?Sized> Clock for &T {
    fn now(&self) -> DateTime<Utc> {
        (**self).now()
    }
}

impl<T: SourceStateStore + ?Sized> SourceStateStore for &T {
    fn source_state(&self, source_id: Uuid) -> Result<Option<SourceState>, PortError> {
        (**self).source_state(source_id)
    }

    fn save_source_state(&self, state: &SourceState) -> Result<(), PortError> {
        (**self).save_source_state(state)
    }

    fn record_run(&self, run: &RunRecord) -> Result<(), PortError> {
        (**self).record_run(run)
    }
}
