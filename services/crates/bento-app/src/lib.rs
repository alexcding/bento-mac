//! Bento's use cases. They depend only on the domain and on the ports defined here; adapters
//! (SQLite, plugins, AI CLIs, publishers) implement the ports in their own crates.

pub mod ingest;
pub mod ports;

pub use ingest::{IngestReport, Ingestor};
pub use ports::{Clock, Outbox, OutboxEntry, PortError, SystemClock};
