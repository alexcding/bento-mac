//! Bento's item model and the pure rules around it.
//!
//! This crate performs no I/O. Everything here is deterministic and shared, through
//! `services/testdata/vectors.json`, with the Swift side.

pub mod ai;
pub mod config;
pub mod detail;
pub mod html;
pub mod item;
pub mod stable_id;

pub use ai::{AiConfig, AiOutput, AiProfile, AiProfileKind, AiTask, CliPreset, OutputTarget};
pub use config::{CollectorConfig, SourceConfig};
pub use item::{
    Author, FeedItem, Media, MediaKind, NormalizedItem, RawItem, Reference, ReferenceKind,
};
