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
    /// Posts as the user's X account, through the X plugin.
    X,
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
            Self::X => Some("x"),
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

    /// A short post: the title (or the text) and the link, cut to fit `limits`.
    #[must_use]
    pub fn short_text(&self, limits: &TextLimits) -> String {
        let body = self.title.as_deref().unwrap_or(&self.text).trim();
        let link = self
            .url
            .as_deref()
            .map(str::trim)
            .filter(|url| !url.is_empty());
        let reserved = link.map_or(0, |_| limits.url_chars + 2);
        let budget = limits.max_chars.saturating_sub(reserved);
        let mut body = body.to_owned();
        if limits.weight(&body) > budget {
            let ellipsis = limits.weight("…");
            let mut cut = String::new();
            let mut used = 0;
            for word in body.split_inclusive(char::is_whitespace) {
                let weight = limits.weight(word);
                if used + weight + ellipsis > budget {
                    // A word longer than what is left is cut by characters, but never inside a
                    // link, which would then count as text rather than as a link.
                    let (head, rest) = word.split_at(leading_link(word));
                    if !head.is_empty() {
                        let weight = limits.weight(head);
                        if used + weight + ellipsis > budget {
                            break;
                        }
                        cut.push_str(head);
                        used += weight;
                    }
                    for c in rest.chars() {
                        let weight = limits.weight(&c.to_string());
                        if used + weight + ellipsis > budget || c.is_whitespace() {
                            break;
                        }
                        cut.push(c);
                        used += weight;
                    }
                    break;
                }
                cut.push_str(word);
                used += weight;
            }
            body = format!("{}…", cut.trim_end());
        }
        match link {
            Some(link) if body.is_empty() => link.to_owned(),
            Some(link) => format!("{body}\n\n{link}"),
            None => body,
        }
    }
}

/// How a platform counts a short post's length, as X does: `max_chars` in all, each link counting
/// `url_chars`, and characters outside Latin and common punctuation (CJK, emoji) counting
/// `wide_char_weight`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TextLimits {
    pub max_chars: usize,
    #[serde(default = "default_url_chars")]
    pub url_chars: usize,
    #[serde(default = "default_wide_char_weight")]
    pub wide_char_weight: usize,
}

/// The length in bytes of the link `word` starts with, or 0: `http(s)://…`, or a bare domain such
/// as `github.com/x`, which X also counts as a link. A link ends at whitespace, at the first
/// non-ASCII character (languages written without spaces often follow one directly) and before
/// trailing punctuation.
fn leading_link(word: &str) -> usize {
    let end = word
        .find(|c: char| !c.is_ascii() || c.is_ascii_whitespace())
        .unwrap_or(word.len());
    let candidate = word[..end].trim_end_matches(|c| ".,;:!?)]'\"".contains(c));
    let is_link = if let Some(rest) = candidate
        .strip_prefix("https://")
        .or_else(|| candidate.strip_prefix("http://"))
    {
        !rest.is_empty()
    } else {
        looks_like_domain(candidate)
    };
    if is_link { candidate.len() } else { 0 }
}

/// `name.tld` with optional subdomains and path: letters, digits and dashes per label, and a
/// top-level part of two or more letters.
fn looks_like_domain(text: &str) -> bool {
    let host = text.split(['/', '?', '#']).next().unwrap_or_default();
    let Some((name, tld)) = host.rsplit_once('.') else {
        return false;
    };
    let label = |part: &str| {
        !part.is_empty() && part.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
    };
    name.split('.').all(label) && tld.len() >= 2 && tld.chars().all(|c| c.is_ascii_alphabetic())
}

fn default_url_chars() -> usize {
    23
}

fn default_wide_char_weight() -> usize {
    1
}

impl TextLimits {
    /// The counted length of `text`: a link (see `leading_link`) counts `url_chars`.
    #[must_use]
    pub fn weight(&self, text: &str) -> usize {
        text.split_inclusive(char::is_whitespace)
            .map(|word| {
                let (link, rest) = word.split_at(leading_link(word));
                // X counts a link as `url_chars`; a bare domain is never counted shorter than it
                // is written, in case X does not take it for a link.
                let link = match link {
                    "" => 0,
                    link if link.starts_with("http") => self.url_chars,
                    link => self.url_chars.max(link.len()),
                };
                link + rest.chars().map(|c| self.char_weight(c)).sum::<usize>()
            })
            .sum()
    }

    fn char_weight(&self, c: char) -> usize {
        // twitter-text's light ranges: Latin through Georgian, and general punctuation.
        let light = matches!(u32::from(c), 0..=0x10FF | 0x2000..=0x200D | 0x2010..=0x201F | 0x2032..=0x2037);
        if light { 1 } else { self.wide_char_weight }
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
    fn short_text_fits_x_counting() {
        let limits = TextLimits {
            max_chars: 280,
            url_chars: 23,
            wide_char_weight: 2,
        };
        let mut post = Message::new(&item(&"word ".repeat(100)), None, "X");
        let text = post.short_text(&limits);
        assert!(limits.weight(&text) <= 280, "{}", limits.weight(&text));
        assert!(text.ends_with("…\n\nhttps://x.com/a/1"), "{text}");

        post.title = Some("中".repeat(200));
        let text = post.short_text(&limits);
        assert!(limits.weight(&text) <= 280);
        assert_eq!(
            text.chars().filter(|c| *c == '中').count(),
            (280 - 25 - 2) / 2
        );

        post.title = Some("Short".into());
        assert_eq!(post.short_text(&limits), "Short\n\nhttps://x.com/a/1");
        assert_eq!(
            limits.weight("see https://example.com/very/long/path"),
            4 + 23
        );
        assert_eq!(
            limits.weight("https://a.com/p。中中"),
            23 + 2 * 3,
            "the link ends at CJK text"
        );
        post.title = Some(format!("标题\nhttps://a.com/p。{}", "中".repeat(150)));
        let text = post.short_text(&limits);
        assert!(limits.weight(&text) <= 280, "{}", limits.weight(&text));
        assert!(
            text.contains("https://a.com/p。中"),
            "text after a link is kept: {text}"
        );

        // Bare domains and punctuation after a link are never counted short.
        assert_eq!(limits.weight("on github.com and"), 3 + 23 + 4);
        assert_eq!(limits.weight("see https://a.com/p."), 4 + 23 + 1);
        assert_eq!(limits.weight("e.g. U.S."), 9, "abbreviations are not links");
        post.title = None;
        post.text = format!("Launch post on github.com and {}", "lorem ".repeat(60));
        let text = post.short_text(&limits);
        assert!(limits.weight(&text) <= 280, "{}", limits.weight(&text));
    }

    #[test]
    fn unknown_kinds_parse_as_unsupported() {
        let kind: DestinationKind = serde_json::from_str(r#""mastodon""#).unwrap();
        assert_eq!(kind, DestinationKind::Unsupported);
        let kind: DestinationKind = serde_json::from_str(r#""telegram_account""#).unwrap();
        assert_eq!(kind, DestinationKind::TelegramAccount);
    }
}
