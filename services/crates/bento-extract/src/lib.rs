//! Article text for items whose source wants it: fetch the page, keep the main content with a
//! Readability port, convert it to Markdown.

use std::time::Duration;

use async_trait::async_trait;
use bento_app::{DetailExtractor, PortError};
use thiserror::Error;

/// Largest page read.
const MAX_PAGE_BYTES: usize = 5 * 1024 * 1024;
/// Shorter extractions are not articles (cookie walls, login pages, errors).
const MIN_TEXT_CHARS: usize = 200;

#[derive(Debug, Error)]
pub enum ExtractError {
    #[error("request failed: {0}")]
    Http(#[from] reqwest::Error),
    #[error("page returned HTTP {0}")]
    Status(u16),
}

pub struct ArticleExtractor {
    client: reqwest::Client,
}

impl ArticleExtractor {
    pub fn new() -> Result<Self, ExtractError> {
        let client = reqwest::Client::builder()
            .user_agent(concat!(
                "Mozilla/5.0 (compatible; Bento/",
                env!("CARGO_PKG_VERSION"),
                ")"
            ))
            .timeout(Duration::from_secs(20))
            .build()?;
        Ok(Self { client })
    }

    async fn fetch(&self, url: &str) -> Result<Option<String>, ExtractError> {
        let response = self.client.get(url).send().await?;
        if !response.status().is_success() {
            return Err(ExtractError::Status(response.status().as_u16()));
        }
        let is_html = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .is_none_or(|v| v.contains("html"));
        if !is_html
            || response
                .content_length()
                .is_some_and(|n| n > MAX_PAGE_BYTES as u64)
        {
            return Ok(None);
        }
        let bytes = response.bytes().await?;
        if bytes.len() > MAX_PAGE_BYTES {
            return Ok(None);
        }
        Ok(markdown_from_html(&String::from_utf8_lossy(&bytes), url))
    }
}

#[async_trait]
impl DetailExtractor for ArticleExtractor {
    async fn extract(&self, url: &str) -> Result<Option<String>, PortError> {
        self.fetch(url).await.map_err(PortError::new)
    }
}

/// The page's main content as Markdown, or `None` when nothing article-like is found.
#[must_use]
pub fn markdown_from_html(html: &str, url: &str) -> Option<String> {
    let mut readability = dom_smoothie::Readability::new(html, Some(url), None).ok()?;
    let article = readability.parse().ok()?;
    if article.text_content.trim().chars().count() < MIN_TEXT_CHARS {
        return None;
    }
    let markdown = htmd::convert(&article.content).ok()?;
    let markdown = markdown.trim();
    (!markdown.is_empty()).then(|| markdown.to_owned())
}

#[cfg(test)]
mod tests {
    use wiremock::matchers::method;
    use wiremock::{Mock, MockServer, ResponseTemplate};

    use super::*;

    const ARTICLE: &str = include_str!("../tests/fixtures/article.html");

    #[test]
    fn keeps_the_article_and_drops_page_chrome() {
        let markdown = markdown_from_html(ARTICLE, "https://example.com/post").unwrap();

        assert!(
            markdown.contains("the first major version since 1.0"),
            "{markdown}"
        );
        assert!(markdown.contains("**borrow checker**"));
        assert!(!markdown.contains("Subscribe to our newsletter"));
        assert!(!markdown.contains("Cookie settings"));
    }

    #[test]
    fn short_pages_are_not_articles() {
        assert_eq!(
            markdown_from_html(
                "<html><body><p>Please log in.</p></body></html>",
                "https://e.com"
            ),
            None
        );
    }

    #[tokio::test]
    async fn fetches_html_and_skips_other_content() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(wiremock::matchers::path("/post"))
            .respond_with(
                ResponseTemplate::new(200).set_body_raw(ARTICLE, "text/html; charset=utf-8"),
            )
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(wiremock::matchers::path("/file.pdf"))
            .respond_with(
                ResponseTemplate::new(200).set_body_raw(vec![0_u8; 10], "application/pdf"),
            )
            .mount(&server)
            .await;
        let extractor = ArticleExtractor::new().unwrap();

        assert!(
            extractor
                .extract(&format!("{}/post", server.uri()))
                .await
                .unwrap()
                .is_some()
        );
        assert_eq!(
            extractor
                .extract(&format!("{}/file.pdf", server.uri()))
                .await
                .unwrap(),
            None
        );
        assert!(
            extractor
                .extract(&format!("{}/missing", server.uri()))
                .await
                .is_err()
        );
    }
}
