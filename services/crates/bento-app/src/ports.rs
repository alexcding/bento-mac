//! Interfaces the use cases need from the outside world.

use bento_domain::FeedItem;
use chrono::{DateTime, Utc};
use thiserror::Error;

/// Failure inside an adapter. Use cases pass it through untouched.
#[derive(Debug, Error)]
#[error(transparent)]
pub struct PortError(#[from] Box<dyn std::error::Error + Send + Sync>);

impl PortError {
    pub fn new(error: impl std::error::Error + Send + Sync + 'static) -> Self {
        Self(Box::new(error))
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
    /// Appends entries atomically and in order.
    fn append(&self, entries: &[OutboxEntry]) -> Result<(), PortError>;
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
