//! Bento's item model and the pure rules around it.
//!
//! This crate performs no I/O. Everything here is deterministic and shared, through
//! `services/testdata/vectors.json`, with the Swift side.

pub mod detail;
pub mod item;
pub mod stable_id;

pub use item::{
    Author, FeedItem, Media, MediaKind, NormalizedItem, RawItem, Reference, ReferenceKind,
};
