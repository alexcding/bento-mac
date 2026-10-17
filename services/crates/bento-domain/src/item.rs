//! Raw items (what source plugins return) and feed items (what Bento stores and syncs).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::stable_id::feed_item_id;

/// One post as returned by a source plugin. Only `external_id` is required.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct RawItem {
    pub external_id: String,
    pub url: Option<String>,
    pub title: Option<String>,
    pub text: String,
    pub author: Option<Author>,
    pub media: Vec<Media>,
    pub published_at: Option<DateTime<Utc>>,
    pub language: Option<String>,
    pub body_markdown: Option<String>,
    pub reference: Option<Box<Reference>>,
    /// Platform-specific fields. Stored by plugins for their own use, never required by the UI.
    pub extra: serde_json::Map<String, serde_json::Value>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Author {
    pub name: Option<String>,
    pub handle: Option<String>,
    pub avatar_url: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Media {
    #[serde(rename = "type")]
    pub kind: MediaKind,
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumbnail_url: Option<String>,
    /// Seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub embed_url: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MediaKind {
    Image,
    Video,
}

/// A quoted or reposted item (X quote tweets and retweets, Bilibili forwards).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Reference {
    #[serde(rename = "type")]
    pub kind: ReferenceKind,
    pub item: RawItem,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReferenceKind {
    Quote,
    Repost,
}

/// A stored item. Mirrors the synced `feedItems` table on the Swift side.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct FeedItem {
    pub id: Uuid,
    pub source_id: Uuid,
    pub external_id: String,
    pub url: Option<String>,
    pub title: Option<String>,
    pub text: String,
    pub translated_title: Option<String>,
    pub summary: Option<String>,
    pub author_name: Option<String>,
    pub author_handle: Option<String>,
    pub author_avatar_url: Option<String>,
    pub media: Vec<Media>,
    pub reference_item_id: Option<Uuid>,
    /// Serialized as Unix milliseconds, so every reader parses it the same way.
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub published_at: DateTime<Utc>,
    pub is_published_at_estimated: bool,
    pub language: Option<String>,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub fetched_at: DateTime<Utc>,
}

/// A feed item plus the full Markdown body the platform provided, if any.
#[derive(Clone, Debug, PartialEq)]
pub struct NormalizedItem {
    pub item: FeedItem,
    pub body_markdown: Option<String>,
}

impl RawItem {
    /// Turns a raw item into feed items. A referenced item comes first, so it is always stored
    /// before the item that points at it.
    #[must_use]
    pub fn normalize(self, source_id: Uuid, fetched_at: DateTime<Utc>) -> Vec<NormalizedItem> {
        let mut out = Vec::with_capacity(2);
        let reference_item_id = self.reference.map(|reference| {
            let id = feed_item_id(source_id, &reference.item.external_id);
            out.extend(reference.item.normalize(source_id, fetched_at));
            id
        });
        let author = self.author.unwrap_or_default();
        let item = FeedItem {
            id: feed_item_id(source_id, &self.external_id),
            source_id,
            external_id: self.external_id,
            url: self.url,
            title: non_empty(self.title),
            text: self.text,
            translated_title: None,
            summary: None,
            author_name: non_empty(author.name),
            author_handle: non_empty(author.handle),
            author_avatar_url: non_empty(author.avatar_url),
            media: self.media,
            reference_item_id,
            published_at: self.published_at.unwrap_or(fetched_at),
            is_published_at_estimated: self.published_at.is_none(),
            language: self.language,
            fetched_at,
        };
        out.push(NormalizedItem {
            item,
            body_markdown: non_empty(self.body_markdown),
        });
        out
    }
}

fn non_empty(value: Option<String>) -> Option<String> {
    value.filter(|s| !s.trim().is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(hour: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 16, hour, 0, 0).unwrap()
    }

    #[test]
    fn parses_minimal_plugin_json() {
        let raw: RawItem = serde_json::from_str(r#"{"external_id":"42"}"#).unwrap();
        assert_eq!(raw.external_id, "42");
        assert!(raw.media.is_empty());
    }

    #[test]
    fn parses_full_plugin_json() {
        let raw: RawItem = serde_json::from_str(
            r#"{
              "external_id": "1",
              "author": {"name": "A", "handle": "@a"},
              "media": [{"type": "video", "url": "v", "duration": 12.5, "embed_url": "e"}],
              "published_at": "2026-10-16T08:00:00Z",
              "reference": {"type": "quote", "item": {"external_id": "0", "text": "orig"}},
              "extra": {"likes": 3}
            }"#,
        )
        .unwrap();
        assert_eq!(raw.media[0].kind, MediaKind::Video);
        assert_eq!(raw.reference.unwrap().kind, ReferenceKind::Quote);
    }

    #[test]
    fn missing_date_falls_back_to_fetch_time() {
        let source = Uuid::from_u128(7);
        let out = RawItem {
            external_id: "1".into(),
            ..Default::default()
        }
        .normalize(source, at(9));
        assert_eq!(out[0].item.published_at, at(9));
        assert!(out[0].item.is_published_at_estimated);
    }

    #[test]
    fn reference_is_emitted_first_and_linked() {
        let source = Uuid::from_u128(7);
        let raw = RawItem {
            external_id: "child".into(),
            published_at: Some(at(8)),
            reference: Some(Box::new(Reference {
                kind: ReferenceKind::Repost,
                item: RawItem {
                    external_id: "parent".into(),
                    ..Default::default()
                },
            })),
            ..Default::default()
        };
        let out = raw.normalize(source, at(9));
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].item.external_id, "parent");
        assert_eq!(out[1].item.reference_item_id, Some(out[0].item.id));
        assert!(!out[1].item.is_published_at_estimated);
    }

    #[test]
    fn blank_strings_become_none() {
        let raw = RawItem {
            external_id: "1".into(),
            title: Some("  ".into()),
            body_markdown: Some(String::new()),
            ..Default::default()
        };
        let out = raw.normalize(Uuid::from_u128(1), at(9));
        assert_eq!(out[0].item.title, None);
        assert_eq!(out[0].body_markdown, None);
    }
}
