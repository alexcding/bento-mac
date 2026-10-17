//! Bento protocol plugin for public Telegram channels. `source/fetch` reads the channel's public
//! web preview (`https://t.me/s/<channel>`), which needs no login and links images on Telegram's
//! CDN. Account login (private channels, sending) is a later addition.

use std::io::Read;

use bento_domain::{Author, Media, MediaKind, RawItem, html};
use chrono::DateTime;
use scraper::{ElementRef, Html, Selector};
use serde_json::{Value, json};

/// Messages the preview page shows at most.
const MAX_LIMIT: usize = 20;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let mut input = String::new();
    let response = match std::io::stdin().read_to_string(&mut input) {
        Ok(_) => handle(&input, "https://t.me").await,
        Err(error) => error_response(&Value::Null, -32000, &error.to_string()),
    };
    println!("{response}");
}

async fn handle(input: &str, base_url: &str) -> Value {
    let Ok(request) = serde_json::from_str::<Value>(input) else {
        return error_response(&Value::Null, -32700, "parse error");
    };
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let params = request.get("params").cloned().unwrap_or_else(|| json!({}));
    match request.get("method").and_then(Value::as_str) {
        Some("source/fetch") => match fetch(base_url, &params).await {
            Ok(items) => json!({"jsonrpc": "2.0", "id": id, "result": {"items": items}}),
            Err(message) => error_response(&id, -32000, &message),
        },
        Some(other) => error_response(&id, -32601, &format!("unknown method {other}")),
        None => error_response(&id, -32600, "missing method"),
    }
}

fn error_response(id: &Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

async fn fetch(base_url: &str, params: &Value) -> Result<Vec<RawItem>, String> {
    let query = params
        .get("query")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let channel = channel_name(query)
        .ok_or_else(|| format!("`{query}` is not a public channel name or t.me link"))?;
    let limit = params
        .pointer("/settings/limit")
        .and_then(Value::as_u64)
        .and_then(|n| usize::try_from(n).ok())
        .unwrap_or(MAX_LIMIT)
        .clamp(1, MAX_LIMIT);
    let client = reqwest::Client::builder()
        .user_agent("Mozilla/5.0 (Macintosh) Bento/0.1")
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .get(format!("{base_url}/s/{channel}"))
        .send()
        .await
        .map_err(|e| format!("request failed: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("t.me returned HTTP {}", response.status().as_u16()));
    }
    let page = response.text().await.map_err(|e| e.to_string())?;
    let mut items = parse(&page);
    if items.is_empty() && !page.contains("tgme_channel_history") {
        return Err(format!(
            "@{channel} has no public preview (private channel, or not a channel)"
        ));
    }
    items.reverse(); // the page lists oldest first
    items.truncate(limit);
    Ok(items)
}

/// `@name`, `name`, `t.me/name`, `t.me/s/name` or a full URL → `name`.
fn channel_name(query: &str) -> Option<String> {
    let trimmed = query
        .trim()
        .trim_start_matches("https://")
        .trim_start_matches("http://");
    let path = trimmed
        .strip_prefix("t.me/")
        .or_else(|| trimmed.strip_prefix("telegram.me/"))
        .unwrap_or(trimmed);
    let path = path.strip_prefix("s/").unwrap_or(path);
    let name = path.trim_start_matches('@').split(['/', '?', '#']).next()?;
    let valid = (4..=32).contains(&name.len())
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
    valid.then(|| name.to_owned())
}

fn selector(css: &str) -> Selector {
    Selector::parse(css).expect("valid selector")
}

fn parse(page: &str) -> Vec<RawItem> {
    let document = Html::parse_document(page);
    let message = selector("div.tgme_widget_message[data-post]");
    document
        .select(&message)
        .filter_map(|m| raw_item(&m))
        .collect()
}

fn raw_item(message: &ElementRef) -> Option<RawItem> {
    let post = message.value().attr("data-post")?;
    let external_id = post.rsplit('/').next()?.to_owned();
    let first = |css: &str| message.select(&selector(css)).next();
    let date_link = first("a.tgme_widget_message_date");
    let url = date_link
        .and_then(|a| a.value().attr("href"))
        .map_or_else(|| format!("https://t.me/{post}"), str::to_owned);
    let published_at = first("a.tgme_widget_message_date time")
        .and_then(|t| t.value().attr("datetime"))
        .and_then(|d| DateTime::parse_from_rfc3339(d).ok())
        .map(|d| d.to_utc());
    let text = first("div.tgme_widget_message_text")
        .map(|t| text_with_line_breaks(&t.inner_html()))
        .unwrap_or_default();
    let author_name = first("a.tgme_widget_message_owner_name")
        .map(|a| a.text().collect::<String>().trim().to_owned());
    let avatar = first("i.tgme_widget_message_user_photo img")
        .and_then(|i| i.value().attr("src"))
        .map(str::to_owned);

    let mut media = Vec::new();
    for photo in message.select(&selector("a.tgme_widget_message_photo_wrap")) {
        if let Some(url) = background_url(photo.value().attr("style")) {
            media.push(Media {
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
    for player in message.select(&selector("a.tgme_widget_message_video_player")) {
        let inside = |css: &str| player.select(&selector(css)).next();
        media.push(Media {
            kind: MediaKind::Video,
            url: player
                .value()
                .attr("href")
                .map_or_else(|| url.clone(), str::to_owned),
            width: None,
            height: None,
            thumbnail_url: inside("i.tgme_widget_message_video_thumb")
                .and_then(|t| background_url(t.value().attr("style"))),
            duration: inside("time.message_video_duration")
                .and_then(|t| duration(&t.text().collect::<String>())),
            embed_url: None,
        });
    }
    if text.is_empty() && media.is_empty() {
        return None; // service messages, stickers
    }
    Some(RawItem {
        external_id,
        url: Some(url),
        text,
        author: Some(Author {
            name: author_name,
            handle: None,
            avatar_url: avatar,
        }),
        media,
        published_at,
        ..RawItem::default()
    })
}

/// Message HTML as text, keeping its line breaks.
fn text_with_line_breaks(inner_html: &str) -> String {
    inner_html
        .replace("<br/>", "\n")
        .replace("<br>", "\n")
        .split('\n')
        .map(html::body_to_text)
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_owned()
}

/// The URL in `background-image:url('…')`.
fn background_url(style: Option<&str>) -> Option<String> {
    let style = style?;
    let start = style.find("url(")? + 4;
    let end = start + style[start..].find(')')?;
    let url = style[start..end].trim_matches(['\'', '"']);
    url.starts_with("https://").then(|| url.to_owned())
}

/// `"0:06"` or `"1:02:03"` in seconds.
fn duration(text: &str) -> Option<f64> {
    text.trim().split(':').try_fold(0.0, |total, part| {
        part.parse::<f64>().ok().map(|n| total * 60.0 + n)
    })
}

#[cfg(test)]
mod tests {
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    use super::*;

    const PAGE: &str = include_str!("../fixtures/channel.html");

    #[test]
    fn accepts_the_usual_ways_of_naming_a_channel() {
        for query in [
            "@telegram",
            "telegram",
            "t.me/telegram",
            "https://t.me/s/telegram",
            "https://t.me/telegram/441",
        ] {
            assert_eq!(channel_name(query).as_deref(), Some("telegram"), "{query}");
        }
        assert_eq!(channel_name("a b"), None);
        assert_eq!(channel_name(""), None);
    }

    #[test]
    fn parses_text_photo_and_video_posts_from_a_real_page() {
        let items = parse(PAGE);

        assert_eq!(
            items
                .iter()
                .map(|i| i.external_id.as_str())
                .collect::<Vec<_>>(),
            ["441", "452", "445"]
        );
        let video = &items[0];
        assert_eq!(video.url.as_deref(), Some("https://t.me/telegram/441"));
        assert!(
            video.text.starts_with("Bot-to-Bot Communication."),
            "{}",
            video.text
        );
        assert_eq!(
            video.published_at,
            DateTime::parse_from_rfc3339("2026-05-14T16:08:31+00:00")
                .ok()
                .map(|d| d.to_utc())
        );
        assert_eq!(
            video.author.as_ref().unwrap().name.as_deref(),
            Some("Telegram News")
        );
        assert!(
            video
                .author
                .as_ref()
                .unwrap()
                .avatar_url
                .as_deref()
                .unwrap()
                .starts_with("https://cdn")
        );
        assert_eq!(video.media[0].kind, MediaKind::Video);
        assert_eq!(video.media[0].duration, Some(6.0));
        assert!(
            video.media[0]
                .thumbnail_url
                .as_deref()
                .unwrap()
                .starts_with("https://cdn")
        );

        let photo = &items[1];
        assert_eq!(photo.media[0].kind, MediaKind::Image);
        assert!(photo.media[0].url.starts_with("https://cdn"));
        assert!(items[2].media.is_empty());
    }

    #[test]
    fn keeps_every_video_of_an_album() {
        let player = |n: u32| {
            format!(
                r#"<a class="tgme_widget_message_video_player" href="https://t.me/c/9?single&v={n}">
                   <i class="tgme_widget_message_video_thumb" style="background-image:url('https://cdn.example/{n}.jpg')"></i>
                   <time class="message_video_duration">0:0{n}</time></a>"#
            )
        };
        let page = format!(
            r#"<section class="tgme_channel_history"><div class="tgme_widget_message" data-post="c/9">{}{}</div></section>"#,
            player(1),
            player(2)
        );

        let items = parse(&page);

        let durations: Vec<_> = items[0].media.iter().map(|m| m.duration).collect();
        assert_eq!(durations, [Some(1.0), Some(2.0)]);
    }

    #[test]
    fn keeps_line_breaks() {
        assert_eq!(
            text_with_line_breaks("<b>Title.</b><br/>Line &amp; two<br>three"),
            "Title.\nLine & two\nthree"
        );
    }

    #[tokio::test]
    async fn fetch_returns_newest_first_within_the_limit() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/s/telegram"))
            .respond_with(ResponseTemplate::new(200).set_body_raw(PAGE, "text/html"))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/s/privatechan"))
            .respond_with(ResponseTemplate::new(200).set_body_raw(
                "<html><body>Contact @privatechan</body></html>",
                "text/html",
            ))
            .mount(&server)
            .await;

        let items = fetch(
            &server.uri(),
            &json!({"query": "@telegram", "settings": {"limit": 2}}),
        )
        .await
        .unwrap();
        assert_eq!(
            items
                .iter()
                .map(|i| i.external_id.as_str())
                .collect::<Vec<_>>(),
            ["445", "452"]
        );

        let error = fetch(&server.uri(), &json!({"query": "privatechan"}))
            .await
            .unwrap_err();
        assert!(error.contains("no public preview"), "{error}");
    }
}
