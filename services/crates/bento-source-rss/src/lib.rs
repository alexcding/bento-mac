//! Built-in RSS and Atom source. Plugin ID `rss`; the source's `query` is the feed URL.

mod html;

use std::time::Duration;

use async_trait::async_trait;
use bento_app::{PortError, SourceFetcher};
use bento_domain::{Author, Media, MediaKind, RawItem, SourceConfig};
use feed_rs::model::{Entry, Feed};
use thiserror::Error;

pub const PLUGIN_ID: &str = "rss";

/// Longest excerpt kept in `RawItem::text`, in characters.
const MAX_TEXT_CHARS: usize = 1_000;

#[derive(Debug, Error)]
pub enum RssError {
    #[error("request failed: {0}")]
    Http(#[from] reqwest::Error),
    #[error("feed returned HTTP {0}")]
    Status(u16),
    #[error("not a valid RSS or Atom feed: {0}")]
    Parse(#[from] feed_rs::parser::ParseFeedError),
}

pub struct RssFetcher {
    client: reqwest::Client,
}

impl RssFetcher {
    pub fn new() -> Result<Self, RssError> {
        let client = reqwest::Client::builder()
            .user_agent(concat!(
                "Bento/",
                env!("CARGO_PKG_VERSION"),
                " (+https://github.com/alexcding/Bento)"
            ))
            .timeout(Duration::from_secs(30))
            .build()?;
        Ok(Self { client })
    }

    async fn fetch_feed(&self, url: &str) -> Result<Vec<RawItem>, RssError> {
        let response = self.client.get(url).send().await?;
        if !response.status().is_success() {
            return Err(RssError::Status(response.status().as_u16()));
        }
        let body = response.bytes().await?;
        parse(&body)
    }
}

#[async_trait]
impl SourceFetcher for RssFetcher {
    async fn fetch(&self, source: &SourceConfig) -> Result<Vec<RawItem>, PortError> {
        self.fetch_feed(&source.query).await.map_err(PortError::new)
    }
}

/// Parses an RSS or Atom document into raw items, newest entries first as the feed lists them.
pub fn parse(document: &[u8]) -> Result<Vec<RawItem>, RssError> {
    let feed = feed_rs::parser::parse(document)?;
    Ok(feed
        .entries
        .iter()
        .map(|entry| raw_item(&feed, entry))
        .collect())
}

fn raw_item(feed: &Feed, entry: &Entry) -> RawItem {
    let url = entry
        .links
        .iter()
        .find(|link| link.rel.as_deref().is_none_or(|rel| rel == "alternate"))
        .or_else(|| entry.links.first())
        .map(|link| link.href.clone());
    let text = entry
        .summary
        .as_ref()
        .map(|summary| summary.content.as_str())
        .or_else(|| {
            entry
                .content
                .as_ref()
                .and_then(|content| content.body.as_deref())
        })
        .map(|html| html::truncate_chars(&html::to_text(html), MAX_TEXT_CHARS))
        .unwrap_or_default();
    let author_name = entry
        .authors
        .first()
        .and_then(|person| person.name.clone())
        .or_else(|| {
            feed.title
                .as_ref()
                .map(|title| html::to_text(&title.content))
        });
    RawItem {
        external_id: if entry.id.is_empty() {
            url.clone().unwrap_or_default()
        } else {
            entry.id.clone()
        },
        url,
        title: entry
            .title
            .as_ref()
            .map(|title| html::to_text(&title.content)),
        text,
        author: Some(Author {
            name: author_name,
            handle: None,
            avatar_url: feed
                .icon
                .as_ref()
                .or(feed.logo.as_ref())
                .map(|image| image.uri.clone()),
        }),
        media: media(entry),
        published_at: entry.published.or(entry.updated),
        language: feed.language.clone(),
        ..RawItem::default()
    }
}

/// Images and videos from `media:content`, `media:thumbnail` and enclosures (feed-rs maps all three
/// into `entry.media`).
fn media(entry: &Entry) -> Vec<Media> {
    let mut out = Vec::new();
    for object in &entry.media {
        let thumbnail = object.thumbnails.first().map(|t| t.image.uri.clone());
        for content in &object.content {
            let Some(url) = &content.url else { continue };
            let mime = content
                .content_type
                .as_ref()
                .map(ToString::to_string)
                .unwrap_or_default();
            let kind = match mime.split('/').next() {
                Some("image") => MediaKind::Image,
                Some("video") => MediaKind::Video,
                _ => continue,
            };
            out.push(Media {
                kind,
                url: url.to_string(),
                width: content.width,
                height: content.height,
                thumbnail_url: thumbnail.clone(),
                duration: content.duration.map(|d| d.as_secs_f64()),
                embed_url: None,
            });
        }
        if object.content.is_empty()
            && let Some(url) = thumbnail
        {
            out.push(Media {
                kind: MediaKind::Image,
                url,
                width: None,
                height: None,
                thumbnail_url: None,
                duration: None,
                embed_url: None,
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    use super::*;

    const RSS: &str = include_str!("../tests/fixtures/rss2.xml");
    const ATOM: &str = include_str!("../tests/fixtures/atom.xml");

    #[test]
    fn parses_rss2() {
        let items = parse(RSS.as_bytes()).unwrap();

        assert_eq!(items.len(), 2);
        let first = &items[0];
        assert_eq!(first.external_id, "https://example.com/posts/1");
        assert_eq!(first.url.as_deref(), Some("https://example.com/posts/1"));
        assert_eq!(first.title.as_deref(), Some("First & best"));
        assert_eq!(first.text, "Hello world. A second line.");
        assert_eq!(
            first.published_at,
            Some(Utc.with_ymd_and_hms(2026, 10, 16, 8, 0, 0).unwrap())
        );
        assert_eq!(first.language.as_deref(), Some("en"));
        let author = first.author.as_ref().unwrap();
        assert_eq!(author.name.as_deref(), Some("Example Blog"));
        assert_eq!(
            author.avatar_url.as_deref(),
            Some("https://example.com/logo.png")
        );
        assert_eq!(first.media.len(), 1);
        assert_eq!(first.media[0].kind, MediaKind::Image);
        assert_eq!(first.media[0].url, "https://example.com/1.jpg");
    }

    #[test]
    fn rss_item_without_date_has_none() {
        let items = parse(RSS.as_bytes()).unwrap();
        assert_eq!(items[1].published_at, None);
        assert!(items[1].media.is_empty());
    }

    #[test]
    fn parses_atom() {
        let items = parse(ATOM.as_bytes()).unwrap();

        assert_eq!(items.len(), 1);
        let entry = &items[0];
        assert_eq!(entry.external_id, "tag:example.org,2026:1");
        assert_eq!(entry.url.as_deref(), Some("https://example.org/1"));
        assert_eq!(entry.author.as_ref().unwrap().name.as_deref(), Some("Jane"));
        assert_eq!(entry.text, "Atom summary");
        assert_eq!(
            entry.published_at,
            Some(Utc.with_ymd_and_hms(2026, 10, 15, 12, 0, 0).unwrap())
        );
    }

    #[test]
    fn rejects_non_feeds() {
        assert!(matches!(
            parse(b"<html><body>nope</body></html>"),
            Err(RssError::Parse(_))
        ));
    }

    fn source(url: &str) -> SourceConfig {
        serde_json::from_value(serde_json::json!({
            "id": uuid::Uuid::from_u128(1), "plugin_id": "rss", "name": "t", "query": url,
            "interval_minutes": 30, "enabled": true
        }))
        .unwrap()
    }

    #[tokio::test]
    async fn fetches_over_http() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/feed"))
            .respond_with(ResponseTemplate::new(200).set_body_string(RSS))
            .mount(&server)
            .await;

        let items = RssFetcher::new()
            .unwrap()
            .fetch(&source(&format!("{}/feed", server.uri())))
            .await
            .unwrap();

        assert_eq!(items.len(), 2);
    }

    #[tokio::test]
    async fn http_errors_fail_the_fetch() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .respond_with(ResponseTemplate::new(503))
            .mount(&server)
            .await;

        let error = RssFetcher::new()
            .unwrap()
            .fetch(&source(&server.uri()))
            .await
            .unwrap_err();

        assert_eq!(error.to_string(), "feed returned HTTP 503");
    }
}
