//! Destinations new items are posted to, and the message posted for an item.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::html::truncate_chars;
use crate::item::{FeedItem, MediaKind};

/// Keychain namespace for destination secrets: the key is the destination ID (lowercase) and the
/// value is the Discord webhook URL or the Telegram bot token. Telegram account destinations use
/// the Telegram plugin's sign-in instead.
pub const DESTINATION_SECRETS: &str = "destination";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DestinationConfig {
    pub id: Uuid,
    pub kind: DestinationKind,
    pub name: String,
    /// Telegram chat: a numeric ID or `@channel` for a bot; `me`, `@name` or `t.me/c/<id>` for an
    /// account. Unused for Discord.
    #[serde(default)]
    pub chat_id: Option<String>,
    /// Minimum time between two posts to this destination.
    pub post_delay_seconds: u32,
    pub enabled: bool,
    /// Sources whose new items this destination receives: those of its channel.
    #[serde(default)]
    pub source_ids: Vec<Uuid>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DestinationKind {
    Discord,
    TelegramBot,
    /// Posts as the user's own Telegram account, through the Telegram plugin.
    TelegramAccount,
    /// A kind this daemon cannot post to yet. Its destinations are ignored.
    #[serde(other)]
    Unsupported,
}

impl DestinationKind {
    /// A flood wait on one destination pauses every destination sharing the limit: all bot
    /// destinations (one bot token in practice) or all account destinations.
    #[must_use]
    pub fn shared_limit(self) -> Option<&'static str> {
        match self {
            Self::TelegramBot => Some("telegram_bot"),
            Self::TelegramAccount => Some("telegram_account"),
            Self::Discord | Self::Unsupported => None,
        }
    }
}

/// What is posted for one item, independent of the destination's format.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Message {
    pub title: Option<String>,
    /// The summary when there is one, else the post text.
    pub text: String,
    pub url: Option<String>,
    pub image_url: Option<String>,
    pub author: Option<String>,
    pub source_name: String,
}

impl Message {
    /// The message for `item`. A quoted or reposted item's text follows the item's own.
    #[must_use]
    pub fn new(item: &FeedItem, referenced: Option<&FeedItem>, source_name: &str) -> Self {
        let pick = |item: &FeedItem| {
            item.summary
                .clone()
                .filter(|summary| !summary.trim().is_empty())
                .unwrap_or_else(|| item.text.clone())
        };
        let mut text = pick(item);
        if let Some(quoted) = referenced {
            let who = quoted
                .author_name
                .as_deref()
                .or(quoted.author_handle.as_deref())
                .unwrap_or("Quote");
            let quoted_text = pick(quoted);
            if !quoted_text.trim().is_empty() {
                text = if text.trim().is_empty() {
                    format!("> {who}: {}", quoted_text.trim())
                } else {
                    format!("{}\n\n> {who}: {}", text.trim_end(), quoted_text.trim())
                };
            }
        }
        let image = |item: &FeedItem| {
            item.media.iter().find_map(|media| match media.kind {
                MediaKind::Image => Some(media.url.clone()),
                MediaKind::Video => media.thumbnail_url.clone(),
            })
        };
        Self {
            title: item
                .translated_title
                .clone()
                .or_else(|| item.title.clone())
                .filter(|title| !title.trim().is_empty()),
            text,
            url: item.url.clone(),
            image_url: image(item).or_else(|| referenced.and_then(image)),
            author: item
                .author_name
                .clone()
                .or_else(|| item.author_handle.clone()),
            source_name: source_name.to_owned(),
        }
    }

    /// `text` cut to `max` characters.
    #[must_use]
    pub fn text_within(&self, max: usize) -> String {
        truncate_chars(&self.text, max)
    }
}

#[cfg(test)]
mod tests {
    use chrono::Utc;

    use super::*;
    use crate::item::Media;

    fn item(text: &str) -> FeedItem {
        FeedItem {
            id: Uuid::from_u128(1),
            source_id: Uuid::from_u128(2),
            external_id: "1".into(),
            url: Some("https://x.com/a/1".into()),
            title: None,
            text: text.into(),
            translated_title: None,
            summary: None,
            author_name: Some("Ann".into()),
            author_handle: None,
            author_avatar_url: None,
            media: Vec::new(),
            reference_item_id: None,
            published_at: Utc::now(),
            is_published_at_estimated: false,
            language: None,
            fetched_at: Utc::now(),
        }
    }

    #[test]
    fn prefers_summary_and_translated_title() {
        let mut post = item("long text");
        post.title = Some("原标题".into());
        post.translated_title = Some("Title".into());
        post.summary = Some("Short".into());

        let message = Message::new(&post, None, "News");

        assert_eq!(message.title.as_deref(), Some("Title"));
        assert_eq!(message.text, "Short");
        assert_eq!(message.author.as_deref(), Some("Ann"));
    }

    #[test]
    fn quotes_the_referenced_post_and_borrows_its_image() {
        let mut quoted = item("original");
        quoted.author_name = Some("Bob".into());
        quoted.media = vec![Media {
            kind: MediaKind::Video,
            url: "https://v".into(),
            width: None,
            height: None,
            thumbnail_url: Some("https://thumb".into()),
            duration: None,
            embed_url: None,
        }];

        let message = Message::new(&item("my take"), Some(&quoted), "X");

        assert_eq!(message.text, "my take\n\n> Bob: original");
        assert_eq!(message.image_url.as_deref(), Some("https://thumb"));
    }

    #[test]
    fn unknown_kinds_parse_as_unsupported() {
        let kind: DestinationKind = serde_json::from_str(r#""x""#).unwrap();
        assert_eq!(kind, DestinationKind::Unsupported);
        let kind: DestinationKind = serde_json::from_str(r#""telegram_account""#).unwrap();
        assert_eq!(kind, DestinationKind::TelegramAccount);
    }
}
