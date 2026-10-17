//! Posts messages to Discord webhooks, Telegram bots and, through plugins, the user's own Telegram
//! and X accounts. The webhook URL or bot token comes from the Keychain
//! (`DESTINATION_SECRETS`, keyed by destination ID) and never appears in errors.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use bento_app::{PublishError, Publisher, SecretStore};
use bento_domain::html::truncate_chars;
use bento_domain::{DESTINATION_SECRETS, DestinationConfig, DestinationKind, Message};
use bento_plugin_host::CliPublisher;
use bento_plugin_host::protocol::{ProtocolError, ProtocolPlugin, REJECTED, UNCERTAIN};
use reqwest::{Response, StatusCode};
use serde_json::{Value, json};

pub const TELEGRAM_API: &str = "https://api.telegram.org";
/// Largest image downloaded for a plugin to attach (X accepts up to 5 MB).
const MAX_IMAGE_BYTES: usize = 5 * 1024 * 1024;
/// Wait used when a 429 says nothing about how long.
const DEFAULT_RETRY_AFTER: Duration = Duration::from_secs(60);

pub struct Publishers {
    client: reqwest::Client,
    secrets: Arc<dyn SecretStore>,
    telegram_api: String,
    /// The Telegram plugin, which posts as the signed-in account.
    telegram_account: Option<Arc<ProtocolPlugin>>,
    /// The X plugin's publish command.
    x: Option<Arc<CliPublisher>>,
}

impl Publishers {
    /// `telegram_api` is `TELEGRAM_API` outside tests.
    ///
    /// # Panics
    /// If the TLS backend cannot be initialized.
    #[must_use]
    pub fn new(secrets: Arc<dyn SecretStore>, telegram_api: &str, timeout: Duration) -> Self {
        Self {
            client: reqwest::Client::builder()
                .timeout(timeout)
                .build()
                .expect("HTTP client"),
            secrets,
            telegram_api: telegram_api.trim_end_matches('/').to_owned(),
            telegram_account: None,
            x: None,
        }
    }

    #[must_use]
    pub fn with_x(mut self, publisher: Option<Arc<CliPublisher>>) -> Self {
        self.x = publisher;
        self
    }

    #[must_use]
    pub fn with_telegram_account(mut self, plugin: Option<Arc<ProtocolPlugin>>) -> Self {
        self.telegram_account = plugin;
        self
    }

    async fn discord(&self, webhook: &str, message: &Message) -> Result<(), PublishError> {
        let mut embed = serde_json::Map::new();
        if let Some(title) = &message.title {
            embed.insert("title".into(), truncate_chars(title, 250).into());
        }
        if let Some(url) = &message.url {
            embed.insert("url".into(), url.clone().into());
        }
        let text = message.text_within(4000);
        if !text.trim().is_empty() {
            embed.insert("description".into(), text.into());
        } else if message.title.is_none() {
            let fallback = message.url.clone().unwrap_or_else(|| "(no text)".into());
            embed.insert("description".into(), fallback.into());
        }
        if let Some(author) = &message.author {
            embed.insert(
                "author".into(),
                json!({ "name": truncate_chars(author, 250) }),
            );
        }
        if let Some(image) = &message.image_url {
            embed.insert("image".into(), json!({ "url": image }));
        }
        if !message.source_name.is_empty() {
            embed.insert(
                "footer".into(),
                json!({ "text": truncate_chars(&message.source_name, 250) }),
            );
        }
        let body = json!({ "embeds": [embed], "allowed_mentions": { "parse": [] } });
        let response = self
            .client
            .post(webhook)
            .query(&[("wait", "true")])
            .json(&body)
            .send()
            .await;
        check(response).await.map(drop)
    }

    async fn telegram(
        &self,
        token: &str,
        chat_id: &str,
        message: &Message,
    ) -> Result<(), PublishError> {
        let base = format!("{}/bot{token}", self.telegram_api);
        if let Some(photo) = &message.image_url {
            let body = json!({
                "chat_id": chat_id,
                "photo": photo,
                "caption": telegram_html(message, 1024),
                "parse_mode": "HTML",
            });
            let response = self
                .client
                .post(format!("{base}/sendPhoto"))
                .json(&body)
                .send()
                .await;
            match check(response).await {
                // Telegram could not use the image (too large, not reachable, wrong type): post the
                // text instead.
                Err(PublishError::Rejected(_)) => {}
                other => return other.map(drop),
            }
        }
        let body = json!({
            "chat_id": chat_id,
            "text": telegram_html(message, 4096),
            "parse_mode": "HTML",
            "link_preview_options": { "is_disabled": message.url.is_none() },
        });
        let response = self
            .client
            .post(format!("{base}/sendMessage"))
            .json(&body)
            .send()
            .await;
        check(response).await.map(drop)
    }
}

#[async_trait]
impl Publisher for Publishers {
    async fn publish(
        &self,
        destination: &DestinationConfig,
        message: &Message,
    ) -> Result<(), PublishError> {
        match destination.kind {
            DestinationKind::TelegramAccount => {
                return self.telegram_account(destination, message).await;
            }
            DestinationKind::X => return self.x(message).await,
            _ => {}
        }
        let secret = self
            .secrets
            .secret(DESTINATION_SECRETS, &destination.id.to_string())
            .map_err(|e| PublishError::Failed(format!("reading the Keychain failed: {e}")))?
            .filter(|secret| !secret.trim().is_empty());
        match destination.kind {
            DestinationKind::Discord => {
                let webhook =
                    secret.ok_or_else(|| PublishError::Rejected("no webhook URL saved".into()))?;
                self.discord(webhook.trim(), message).await
            }
            DestinationKind::TelegramBot => {
                let token =
                    secret.ok_or_else(|| PublishError::Rejected("no bot token saved".into()))?;
                let chat_id = destination
                    .chat_id
                    .as_deref()
                    .map(str::trim)
                    .filter(|chat| !chat.is_empty())
                    .ok_or_else(|| PublishError::Rejected("no chat set".into()))?;
                self.telegram(token.trim(), chat_id, message).await
            }
            DestinationKind::TelegramAccount
            | DestinationKind::X
            | DestinationKind::Unsupported => Err(PublishError::Rejected(
                "this destination kind is not supported".into(),
            )),
        }
    }
}

impl Publishers {
    async fn x(&self, message: &Message) -> Result<(), PublishError> {
        let publisher = self
            .x
            .as_ref()
            .ok_or_else(|| PublishError::Rejected("the X plugin is not installed".into()))?;
        // The command needs a local file; without one the post goes out as text.
        let image = match &message.image_url {
            Some(url) => self.download_image(url).await,
            None => None,
        };
        publisher
            .publish(message, image.as_ref().map(tempfile::NamedTempFile::path))
            .await
    }

    /// Downloads an image to a temporary file, or `None` if it cannot be used.
    async fn download_image(&self, url: &str) -> Option<tempfile::NamedTempFile> {
        let response = self
            .client
            .get(url)
            .send()
            .await
            .ok()?
            .error_for_status()
            .ok()?;
        let extension = match response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)?
            .to_str()
            .ok()?
        {
            "image/jpeg" | "image/jpg" => ".jpg",
            "image/png" => ".png",
            "image/webp" => ".webp",
            "image/gif" => ".gif",
            _ => return None,
        };
        if response
            .content_length()
            .is_some_and(|length| length > MAX_IMAGE_BYTES as u64)
        {
            return None;
        }
        let bytes = response.bytes().await.ok()?;
        if bytes.len() > MAX_IMAGE_BYTES {
            return None;
        }
        let mut file = tempfile::Builder::new()
            .prefix("bento-image")
            .suffix(extension)
            .tempfile()
            .ok()?;
        std::io::Write::write_all(&mut file, &bytes).ok()?;
        Some(file)
    }

    async fn telegram_account(
        &self,
        destination: &DestinationConfig,
        message: &Message,
    ) -> Result<(), PublishError> {
        let plugin = self
            .telegram_account
            .as_ref()
            .ok_or_else(|| PublishError::Rejected("the Telegram plugin is not installed".into()))?;
        let chat = destination
            .chat_id
            .as_deref()
            .map(str::trim)
            .filter(|chat| !chat.is_empty())
            .ok_or_else(|| PublishError::Rejected("no chat set".into()))?;
        let html = telegram_html(message, 4096);
        let caption = telegram_html(message, 1024);
        plugin
            .publish(chat, &html, &caption, message.image_url.as_deref())
            .await
            .map_err(|error| match error {
                // The post may have gone out: never retried.
                ProtocolError::Timeout(_)
                | ProtocolError::Invalid(_)
                | ProtocolError::Plugin {
                    code: UNCERTAIN, ..
                } => PublishError::TimedOut(error.to_string()),
                ProtocolError::RateLimited(seconds) => {
                    PublishError::RateLimited(Duration::from_secs(seconds))
                }
                ProtocolError::AuthRequired => {
                    PublishError::Rejected("sign in to Telegram again in Settings → Plugins".into())
                }
                ProtocolError::Plugin {
                    code: REJECTED,
                    message,
                } => PublishError::Rejected(message),
                other => PublishError::Failed(other.to_string()),
            })
    }
}

/// Maps a response to the delivery rules: 2xx sent, 429 wait, 5xx retry, other 4xx refused, a
/// timeout never retried. Errors never include the URL, which holds the secret.
async fn check(response: Result<Response, reqwest::Error>) -> Result<Value, PublishError> {
    let response = match response {
        Ok(response) => response,
        Err(error) if error.is_timeout() => {
            return Err(PublishError::TimedOut(error.without_url().to_string()));
        }
        // Nothing was sent when the connection could not be made, so it is retried; any other
        // failure may come after the post arrived.
        Err(error) if error.is_connect() => {
            return Err(PublishError::Failed(error.without_url().to_string()));
        }
        Err(error) => return Err(PublishError::TimedOut(error.without_url().to_string())),
    };
    let status = response.status();
    let header_wait = response
        .headers()
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.trim().parse::<f64>().ok());
    let body: Value = response.json().await.unwrap_or(Value::Null);
    if status.is_success() {
        return Ok(body);
    }
    if status == StatusCode::TOO_MANY_REQUESTS {
        // Discord: `retry_after` (seconds, fractional). Telegram: `parameters.retry_after`.
        let wait = body["retry_after"]
            .as_f64()
            .or_else(|| body["parameters"]["retry_after"].as_f64())
            .or(header_wait)
            .map_or(DEFAULT_RETRY_AFTER, |seconds| {
                Duration::from_secs_f64(seconds.clamp(1.0, 86_400.0).ceil())
            });
        return Err(PublishError::RateLimited(wait));
    }
    let detail = body["description"]
        .as_str()
        .or_else(|| body["message"].as_str())
        .map_or_else(|| status.to_string(), |text| format!("{status}: {text}"));
    if status.is_server_error() {
        Err(PublishError::Failed(detail))
    } else {
        Err(PublishError::Rejected(detail))
    }
}

/// The post as Telegram HTML, at most `limit` visible characters: bold title, text, then a link
/// labeled with the source and author.
fn telegram_html(message: &Message, limit: usize) -> String {
    let title = message
        .title
        .as_deref()
        .map(|title| truncate_chars(title, 200));
    let label = [
        Some(message.source_name.as_str()),
        message.author.as_deref(),
    ]
    .into_iter()
    .flatten()
    .filter(|part| !part.is_empty())
    .collect::<Vec<_>>()
    .join(" · ");
    let label = if label.is_empty() {
        "Open".to_owned()
    } else {
        truncate_chars(&label, 100)
    };
    let overhead = title.as_ref().map_or(0, |t| t.chars().count() + 2)
        + message
            .url
            .as_ref()
            .map_or(0, |_| label.chars().count() + 2);
    let text = message.text_within(limit.saturating_sub(overhead + 1));
    let mut parts = Vec::new();
    if let Some(title) = title {
        parts.push(format!("<b>{}</b>", escape(&title)));
    }
    if !text.trim().is_empty() {
        parts.push(escape(text.trim()));
    }
    if let Some(url) = &message.url {
        parts.push(format!(
            "<a href=\"{}\">{}</a>",
            escape(url).replace('"', "&quot;"),
            escape(&label)
        ));
    }
    parts.join("\n\n")
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

#[cfg(test)]
mod tests {
    use bento_app::PortError;
    use uuid::Uuid;
    use wiremock::matchers::{body_partial_json, method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    use super::*;

    struct Secret(Option<String>);
    impl SecretStore for Secret {
        fn secret(&self, plugin_id: &str, key: &str) -> Result<Option<String>, PortError> {
            assert_eq!(
                (plugin_id, key),
                (DESTINATION_SECRETS, Uuid::from_u128(1).to_string().as_str())
            );
            Ok(self.0.clone())
        }
    }

    fn destination(kind: DestinationKind) -> DestinationConfig {
        DestinationConfig {
            id: Uuid::from_u128(1),
            kind,
            name: "d".into(),
            chat_id: Some("@news".into()),
            post_delay_seconds: 20,
            enabled: true,
            source_ids: Vec::new(),
        }
    }

    fn message(image: Option<&str>) -> Message {
        Message {
            title: Some("A <b>title</b>".into()),
            text: "Body & more".into(),
            url: Some("https://example.com/a?x=1&y=2".into()),
            image_url: image.map(str::to_owned),
            author: Some("Ann".into()),
            source_name: "News".into(),
        }
    }

    fn publishers(server: &MockServer, secret: Option<String>, timeout: Duration) -> Publishers {
        Publishers::new(Arc::new(Secret(secret)), &server.uri(), timeout)
    }

    #[tokio::test]
    async fn posts_a_discord_embed_and_honours_retry_after() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/hook"))
            .and(query_param("wait", "true"))
            .and(body_partial_json(
                json!({ "embeds": [{ "title": "A <b>title</b>", "footer": { "text": "News" } }] }),
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "id": "1" })))
            .up_to_n_times(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(429).set_body_json(json!({ "retry_after": 2.5 })))
            .mount(&server)
            .await;
        let publishers = publishers(
            &server,
            Some(format!("{}/hook", server.uri())),
            Duration::from_secs(5),
        );

        publishers
            .publish(&destination(DestinationKind::Discord), &message(None))
            .await
            .unwrap();
        let limited = publishers
            .publish(&destination(DestinationKind::Discord), &message(None))
            .await;

        assert!(
            matches!(limited, Err(PublishError::RateLimited(wait)) if wait == Duration::from_secs(3))
        );
    }

    #[tokio::test]
    async fn telegram_falls_back_to_text_when_the_photo_is_refused() {
        let server = MockServer::start().await;
        Mock::given(path("/botTOKEN/sendPhoto"))
            .respond_with(ResponseTemplate::new(400).set_body_json(json!({ "ok": false, "description": "Bad Request: wrong type of the web page content" })))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(path("/botTOKEN/sendMessage"))
            .and(body_partial_json(json!({
                "chat_id": "@news",
                "parse_mode": "HTML",
                "text": "<b>A &lt;b&gt;title&lt;/b&gt;</b>\n\nBody &amp; more\n\n<a href=\"https://example.com/a?x=1&amp;y=2\">News · Ann</a>",
            })))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "ok": true })))
            .expect(1)
            .mount(&server)
            .await;

        publishers(&server, Some("TOKEN".into()), Duration::from_secs(5))
            .publish(
                &destination(DestinationKind::TelegramBot),
                &message(Some("https://img")),
            )
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn telegram_flood_waits_server_errors_retry_and_timeouts_hide_the_token() {
        let server = MockServer::start().await;
        Mock::given(path("/botFLOOD/sendMessage"))
            .respond_with(
                ResponseTemplate::new(429)
                    .set_body_json(json!({ "ok": false, "parameters": { "retry_after": 30 } })),
            )
            .mount(&server)
            .await;
        Mock::given(path("/botDOWN/sendMessage"))
            .respond_with(ResponseTemplate::new(502))
            .mount(&server)
            .await;
        Mock::given(path("/botSLOW/sendMessage"))
            .respond_with(ResponseTemplate::new(200).set_delay(Duration::from_secs(2)))
            .mount(&server)
            .await;
        let send = |token: &str| {
            let publishers = publishers(&server, Some(token.into()), Duration::from_millis(300));
            async move {
                publishers
                    .publish(&destination(DestinationKind::TelegramBot), &message(None))
                    .await
            }
        };

        assert!(
            matches!(send("FLOOD").await, Err(PublishError::RateLimited(wait)) if wait == Duration::from_secs(30))
        );
        assert!(matches!(send("DOWN").await, Err(PublishError::Failed(_))));
        let Err(PublishError::TimedOut(error)) = send("SLOW").await else {
            panic!("expected a timeout")
        };
        assert!(!error.contains("SLOW"), "{error}");
    }

    #[tokio::test]
    async fn missing_secret_or_chat_is_refused() {
        let server = MockServer::start().await;
        let none = publishers(&server, None, Duration::from_secs(1));
        assert!(matches!(
            none.publish(&destination(DestinationKind::Discord), &message(None))
                .await,
            Err(PublishError::Rejected(_))
        ));

        let mut no_chat = destination(DestinationKind::TelegramBot);
        no_chat.chat_id = Some(" ".into());
        let token = publishers(&server, Some("T".into()), Duration::from_secs(1));
        assert!(matches!(
            token.publish(&no_chat, &message(None)).await,
            Err(PublishError::Rejected(_))
        ));
    }

    #[test]
    fn telegram_text_fits_the_limit() {
        let mut long = message(None);
        long.text = "x".repeat(5000);
        let html = telegram_html(&long, 1024);
        let visible = html
            .replace("<b>", "")
            .replace("</b>", "")
            .replace("&lt;", "<")
            .replace("&gt;", ">");
        let visible =
            visible.split("<a href").next().unwrap().chars().count() + "News · Ann".chars().count();
        assert!(visible <= 1024, "{visible}");
    }

    #[tokio::test]
    async fn downloads_only_usable_images() {
        let server = MockServer::start().await;
        Mock::given(path("/a.png"))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("content-type", "image/png")
                    .set_body_bytes(vec![1, 2, 3]),
            )
            .mount(&server)
            .await;
        Mock::given(path("/page"))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("content-type", "text/html")
                    .set_body_string("<html>"),
            )
            .mount(&server)
            .await;
        let publishers = publishers(&server, None, Duration::from_secs(5));

        let image = publishers
            .download_image(&format!("{}/a.png", server.uri()))
            .await
            .unwrap();
        assert!(image.path().extension().is_some_and(|e| e == "png"));
        assert_eq!(std::fs::read(image.path()).unwrap(), [1, 2, 3]);
        assert!(
            publishers
                .download_image(&format!("{}/page", server.uri()))
                .await
                .is_none()
        );
        assert!(
            publishers
                .download_image(&format!("{}/missing", server.uri()))
                .await
                .is_none()
        );
    }
}
