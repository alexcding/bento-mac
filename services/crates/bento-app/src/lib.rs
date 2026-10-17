//! Bento's use cases. They depend only on the domain and on the ports defined here; adapters
//! (SQLite, plugins, AI CLIs, publishers) implement the ports in their own crates.

pub mod deliver;
pub mod enrich;
pub mod ingest;
pub mod ports;
pub mod schedule;

pub use deliver::{Deliverer, SendReport};
pub use enrich::{EnrichReport, Enricher, Enrichment};
pub use ingest::{IngestReport, Ingestor, Prepared};
pub use ports::{
    AiCall, AiCallRecorder, AiError, AiProvider, AiRequest, Clock, Delivery, DeliveryOutcome,
    DeliveryStore, DetailExtractor, Outbox, OutboxEntry, PortError, PublishError, Publisher,
    RunRecord, SecretStore, SourceFetcher, SourceState, SourceStateStore, SystemClock,
};
pub use schedule::{DryRun, FetcherRegistry, RunReport, Scheduler};
