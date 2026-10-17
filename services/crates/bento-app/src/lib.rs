//! Bento's use cases. They depend only on the domain and on the ports defined here; adapters
//! (SQLite, plugins, AI CLIs, publishers) implement the ports in their own crates.

pub mod enrich;
pub mod ingest;
pub mod ports;
pub mod schedule;

pub use enrich::{EnrichReport, Enricher, Enrichment};
pub use ingest::{IngestReport, Ingestor, Prepared};
pub use ports::{
    AiCall, AiCallRecorder, AiError, AiProvider, AiRequest, Clock, DetailExtractor, Outbox,
    OutboxEntry, PortError, RunRecord, SecretStore, SourceFetcher, SourceState, SourceStateStore,
    SystemClock,
};
pub use schedule::{FetcherRegistry, RunReport, Scheduler};
