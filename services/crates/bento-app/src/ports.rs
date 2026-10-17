//! Interfaces the use cases need from the outside world.

use std::collections::HashSet;

use async_trait::async_trait;
use bento_domain::{AiProfile, DestinationConfig, FeedItem, Message, RawItem, SourceConfig};
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
    /// The subset of `ids` never appended before. Used to skip known items before any processing.
    fn unseen(&self, ids: &[Uuid]) -> Result<HashSet<Uuid>, PortError>;
    /// Appends, atomically and in order, the entries whose item IDs were never appended before.
    /// Returns how many were appended.
    fn append_new(&self, entries: &[OutboxEntry]) -> Result<usize, PortError>;
    /// Marks items as already sent without appending them (skipping a source's backlog).
    fn mark_seen(&self, ids: &[Uuid]) -> Result<(), PortError>;
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

/// Fetches a web page and returns its main text as Markdown, or `None` if it has none.
#[async_trait]
pub trait DetailExtractor: Send + Sync {
    async fn extract(&self, url: &str) -> Result<Option<String>, PortError>;
}

/// One structured AI call: instructions, the input as JSON text, and the JSON Schema the answer
/// must follow.
#[derive(Clone, Debug, PartialEq)]
pub struct AiRequest {
    pub instructions: String,
    pub input: String,
    pub schema: serde_json::Value,
}

#[derive(Debug, Error)]
pub enum AiError {
    /// Login, API key or permission problem. The profile is paused for a while.
    #[error("authentication failed: {0}")]
    Auth(String),
    #[error("{0}")]
    Failed(String),
}

/// Runs a request on the service a profile describes.
#[async_trait]
pub trait AiProvider: Send + Sync {
    async fn complete(
        &self,
        profile: &AiProfile,
        request: &AiRequest,
    ) -> Result<serde_json::Value, AiError>;
}

/// One AI call, kept for the app's usage and latency view.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AiCall {
    pub started_at: DateTime<Utc>,
    pub profile_id: String,
    pub task_id: String,
    pub duration_ms: u64,
    pub items: usize,
    pub input_chars: usize,
    pub error: Option<String>,
}

pub trait AiCallRecorder: Send + Sync {
    fn record_ai_call(&self, call: &AiCall) -> Result<(), PortError>;
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
    /// When a run last succeeded; `None` until the first success.
    pub last_success_at: Option<DateTime<Utc>>,
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

/// One post waiting to be sent to a destination.
#[derive(Clone, Debug, PartialEq)]
pub struct Delivery {
    pub id: i64,
    pub destination_id: Uuid,
    pub item: FeedItem,
    /// The item it quotes or reposts, posted inside it.
    pub referenced: Option<FeedItem>,
    /// Failed attempts so far.
    pub attempts: u32,
    /// Not sent before this (a retry wait).
    pub next_attempt_at: DateTime<Utc>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeliveryOutcome {
    Sent,
    /// Try again at `at`. Rate limits do not count as a failed attempt.
    Retry {
        at: DateTime<Utc>,
        error: String,
        failed_attempt: bool,
    },
    /// Given up for good.
    Failed(String),
}

/// The delivery queue, fed from the outbox through its own cursor.
pub trait DeliveryStore: Send + Sync {
    /// Outbox rows after the delivery cursor, oldest first, as `(seq, item)`.
    fn undelivered_outbox(&self, limit: usize) -> Result<Vec<(i64, FeedItem)>, PortError>;
    /// Queues `(destination, item, seq)` deliveries due now and moves the cursor to `through_seq`,
    /// atomically. A destination is never queued the same item twice.
    fn queue_deliveries(
        &self,
        through_seq: i64,
        deliveries: &[(Uuid, Uuid, i64)],
        now: DateTime<Utc>,
    ) -> Result<(), PortError>;
    /// Each destination's oldest pending delivery, due or not.
    fn next_deliveries(&self) -> Result<Vec<Delivery>, PortError>;
    /// Marks a delivery as being sent, so a crash mid-send is never followed by a second send.
    fn start_delivery(&self, id: i64) -> Result<(), PortError>;
    /// Fails every delivery left marked as being sent.
    fn fail_interrupted_deliveries(&self, error: &str) -> Result<(), PortError>;
    /// Until when a Telegram flood wait pauses every Telegram destination.
    fn telegram_paused_until(&self) -> Result<Option<DateTime<Utc>>, PortError>;
    fn pause_telegram(&self, until: DateTime<Utc>) -> Result<(), PortError>;
    /// When a post last went out to the destination.
    fn last_sent_at(&self, destination_id: Uuid) -> Result<Option<DateTime<Utc>>, PortError>;
    fn finish_delivery(
        &self,
        id: i64,
        outcome: &DeliveryOutcome,
        now: DateTime<Utc>,
    ) -> Result<(), PortError>;
}

#[derive(Debug, Error)]
pub enum PublishError {
    /// 429 or a Telegram flood wait: wait this long.
    #[error("rate limited for {}s", .0.as_secs())]
    RateLimited(std::time::Duration),
    /// The request may have arrived. Never retried, so nothing is posted twice.
    #[error("timed out: {0}")]
    TimedOut(String),
    /// Refused for good: a bad token or webhook, an unknown chat, a malformed post.
    #[error("{0}")]
    Rejected(String),
    /// Network or server error, retried with backoff.
    #[error("{0}")]
    Failed(String),
}

/// Posts a message to one destination. One implementation covers every supported kind.
#[async_trait]
pub trait Publisher: Send + Sync {
    async fn publish(
        &self,
        destination: &DestinationConfig,
        message: &Message,
    ) -> Result<(), PublishError>;
}

pub trait SourceStateStore {
    fn source_state(&self, source_id: Uuid) -> Result<Option<SourceState>, PortError>;
    fn save_source_state(&self, state: &SourceState) -> Result<(), PortError>;
    fn record_run(&self, run: &RunRecord) -> Result<(), PortError>;
}

impl<T: Outbox + ?Sized> Outbox for &T {
    fn unseen(&self, ids: &[Uuid]) -> Result<HashSet<Uuid>, PortError> {
        (**self).unseen(ids)
    }

    fn append_new(&self, entries: &[OutboxEntry]) -> Result<usize, PortError> {
        (**self).append_new(entries)
    }

    fn mark_seen(&self, ids: &[Uuid]) -> Result<(), PortError> {
        (**self).mark_seen(ids)
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

impl<T: Clock + ?Sized> Clock for std::sync::Arc<T> {
    fn now(&self) -> DateTime<Utc> {
        (**self).now()
    }
}

impl<T: DeliveryStore + ?Sized> DeliveryStore for std::sync::Arc<T> {
    fn undelivered_outbox(&self, limit: usize) -> Result<Vec<(i64, FeedItem)>, PortError> {
        (**self).undelivered_outbox(limit)
    }

    fn queue_deliveries(
        &self,
        through_seq: i64,
        deliveries: &[(Uuid, Uuid, i64)],
        now: DateTime<Utc>,
    ) -> Result<(), PortError> {
        (**self).queue_deliveries(through_seq, deliveries, now)
    }

    fn next_deliveries(&self) -> Result<Vec<Delivery>, PortError> {
        (**self).next_deliveries()
    }

    fn start_delivery(&self, id: i64) -> Result<(), PortError> {
        (**self).start_delivery(id)
    }

    fn fail_interrupted_deliveries(&self, error: &str) -> Result<(), PortError> {
        (**self).fail_interrupted_deliveries(error)
    }

    fn telegram_paused_until(&self) -> Result<Option<DateTime<Utc>>, PortError> {
        (**self).telegram_paused_until()
    }

    fn pause_telegram(&self, until: DateTime<Utc>) -> Result<(), PortError> {
        (**self).pause_telegram(until)
    }

    fn last_sent_at(&self, destination_id: Uuid) -> Result<Option<DateTime<Utc>>, PortError> {
        (**self).last_sent_at(destination_id)
    }

    fn finish_delivery(
        &self,
        id: i64,
        outcome: &DeliveryOutcome,
        now: DateTime<Utc>,
    ) -> Result<(), PortError> {
        (**self).finish_delivery(id, outcome, now)
    }
}
