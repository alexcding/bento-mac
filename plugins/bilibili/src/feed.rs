//! The logged-in user's following feed (`/x/polymer/web-dynamic/v1/feed/all`) mapped to raw items.

use bento_domain::{Author, Media, MediaKind, RawItem, Reference, ReferenceKind};
use chrono::DateTime;
use serde_json::{Value, json};

use crate::{Endpoints, Failure};

/// Pages read per fetch at most.
const MAX_PAGES: usize = 5;
const DEFAULT_LIMIT: usize = 20;
/// "Not logged in".
const NOT_LOGGED_IN: i64 = -101;

pub async fn fetch(
    client: &reqwest::Client,
    endpoints: &Endpoints,
    params: &Value,
) -> Result<Value, Failure> {
    let secret = |key: &str| {
        params
            .pointer(&format!("/secrets/{key}"))
            .and_then(Value::as_str)
            .unwrap_or_default()
    };
    if secret("sessdata").is_empty() {
        return Err(Failure::auth("Sign in to Bilibili first."));
    }
    let cookie = [
        ("SESSDATA", "sessdata"),
        ("bili_jct", "bili_jct"),
        ("buvid3", "buvid3"),
        ("buvid4", "buvid4"),
        ("DedeUserID", "dedeuserid"),
    ]
    .iter()
    .filter(|(_, key)| !secret(key).is_empty())
    .map(|(name, key)| format!("{name}={}", secret(key)))
    .collect::<Vec<_>>()
    .join("; ");
    let limit = params
        .pointer("/settings/limit")
        .and_then(Value::as_u64)
        .and_then(|n| usize::try_from(n).ok())
        .unwrap_or(DEFAULT_LIMIT)
        .clamp(1, 100);

    let mut items = Vec::new();
    let mut offset = String::new();
    for _ in 0..MAX_PAGES {
        let mut query = vec![
            ("timezone_offset", "-480"),
            ("features", "itemOpusStyle"),
            ("page", "1"),
        ];
        if !offset.is_empty() {
            query.push(("offset", offset.as_str()));
        }
        let page: Value = client
            .get(format!(
                "{}/x/polymer/web-dynamic/v1/feed/all",
                endpoints.api
            ))
            .query(&query)
            .header("Referer", "https://t.bilibili.com/")
            .header("Accept", "application/json")
            .header("Cookie", &cookie)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        match page.get("code").and_then(Value::as_i64) {
            Some(0) => {}
            Some(NOT_LOGGED_IN) => {
                return Err(Failure::auth("Your Bilibili session ended. Sign in again."));
            }
            _ => {
                let message = page
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("Bilibili error");
                return Err(Failure::other(message.to_owned()));
            }
        }
        let data = page.get("data").unwrap_or(&Value::Null);
        let page_items = data
            .get("items")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        items.extend(page_items.iter().filter_map(raw_item));
        let next = data
            .get("offset")
            .or_else(|| data.get("next_offset"))
            .and_then(|v| {
                v.as_str()
                    .map(str::to_owned)
                    .or_else(|| v.as_i64().map(|n| n.to_string()))
            })
            .unwrap_or_default();
        if items.len() >= limit || page_items.is_empty() || next.is_empty() || next == offset {
            break;
        }
        offset = next;
    }
    items.truncate(limit);
    Ok(json!({"items": items}))
}

/// One dynamic as a raw item; `None` without an ID.
fn raw_item(item: &Value) -> Option<RawItem> {
    let id = text(item.get("id_str")).or_else(|| item.get("id").map(ToString::to_string))?;
    let modules = item.get("modules").unwrap_or(&Value::Null);
    let author = modules.get("module_author").unwrap_or(&Value::Null);
    let dynamic = modules.get("module_dynamic").unwrap_or(&Value::Null);
    let major = dynamic.get("major").unwrap_or(&Value::Null);
    let archive = major.get("archive").unwrap_or(&Value::Null);
    let opus = major.get("opus").unwrap_or(&Value::Null);
    let article = major.get("article").unwrap_or(&Value::Null);
    let common = major.get("common").unwrap_or(&Value::Null);
    let pgc = major.get("pgc").unwrap_or(&Value::Null);
    let other = other_major(major);

    let body = [
        dynamic.pointer("/desc/text"),
        archive.get("desc"),
        opus.pointer("/summary/text"),
        article.get("desc"),
        common.get("desc"),
        pgc.get("desc"),
        other.desc.as_ref(),
    ]
    .into_iter()
    .find_map(text)
    .map(|t| clean(&t))
    .unwrap_or_default();
    let title = [
        archive.get("title"),
        article.get("title"),
        common.get("title"),
        pgc.get("title"),
        opus.get("title"),
        other.title.as_ref(),
    ]
    .into_iter()
    .find_map(text);
    let bvid = text(archive.get("bvid"));
    let url = bvid
        .as_ref()
        .map(|bvid| format!("https://www.bilibili.com/video/{bvid}"))
        .or_else(|| {
            [
                archive.get("jump_url"),
                opus.get("jump_url"),
                other.url.as_ref(),
                item.pointer("/basic/jump_url"),
            ]
            .into_iter()
            .find_map(text)
            .map(https)
        })
        .unwrap_or_else(|| format!("https://t.bilibili.com/{id}"));

    let media = media(bvid.as_deref(), major, other.cover.as_ref());
    if body.is_empty() && title.is_none() && media.is_empty() {
        return None; // a type this plugin cannot show; better nothing than a blank card
    }

    let reference = item
        .get("orig")
        .filter(|orig| orig.is_object())
        .and_then(raw_item)
        .map(|orig| {
            Box::new(Reference {
                kind: ReferenceKind::Repost,
                item: orig,
            })
        });
    let published_at = author
        .get("pub_ts")
        .and_then(|v| {
            v.as_i64()
                .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
        })
        .and_then(|ts| {
            if ts > 10_000_000_000 {
                DateTime::from_timestamp_millis(ts)
            } else {
                DateTime::from_timestamp(ts, 0)
            }
        });
    Some(RawItem {
        external_id: id,
        url: Some(url),
        title,
        text: body,
        author: Some(Author {
            name: text(author.get("name")),
            handle: None,
            avatar_url: text(author.get("face")).map(https),
        }),
        media,
        published_at,
        language: Some("zh".into()),
        reference,
        ..RawItem::default()
    })
}

/// Title, description, cover and link of the majors without their own handling: live streams
/// (`live_rcmd` carries its card as a JSON string), live replays, music and collections.
#[derive(Default)]
struct OtherMajor {
    title: Option<Value>,
    desc: Option<Value>,
    cover: Option<Value>,
    url: Option<Value>,
}

fn other_major(major: &Value) -> OtherMajor {
    let live_rcmd = major
        .pointer("/live_rcmd/content")
        .and_then(Value::as_str)
        .and_then(|s| serde_json::from_str::<Value>(s).ok())
        .and_then(|content| content.get("live_play_info").cloned());
    let card = live_rcmd.or_else(|| {
        ["live", "music", "ugc_season", "courses"]
            .iter()
            .find_map(|key| major.get(*key).filter(|v| v.is_object()).cloned())
    });
    let Some(card) = card else {
        return OtherMajor::default();
    };
    OtherMajor {
        title: card.get("title").cloned(),
        desc: card.get("desc").or_else(|| card.get("label")).cloned(),
        cover: card.get("cover").cloned(),
        url: card.get("jump_url").or_else(|| card.get("link")).cloned(),
    }
}

/// The video (with cover, duration and embed) for videos, else up to four cover or post images.
fn media(bvid: Option<&str>, major: &Value, other_cover: Option<&Value>) -> Vec<Media> {
    let field = |key: &str| major.get(key).unwrap_or(&Value::Null);
    let (archive, opus) = (field("archive"), field("opus"));
    let mut media = Vec::new();
    if let Some(bvid) = bvid {
        media.push(Media {
            kind: MediaKind::Video,
            url: format!("https://www.bilibili.com/video/{bvid}"),
            width: None,
            height: None,
            thumbnail_url: text(archive.get("cover")).map(https),
            duration: text(archive.get("duration_text")).and_then(|d| duration(&d)),
            embed_url: Some(format!(
                "https://player.bilibili.com/player.html?bvid={bvid}&autoplay=0"
            )),
        });
    } else {
        let covers = [
            field("article").get("cover"),
            field("common").get("cover"),
            field("pgc").get("cover"),
            other_cover,
        ]
        .into_iter()
        .filter_map(text);
        let pictures = opus
            .get("pics")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|p| text(p.get("url")));
        let mut seen = std::collections::HashSet::new();
        for url in covers
            .chain(pictures)
            .map(https)
            .filter(|u| seen.insert(u.clone()))
            .take(4)
        {
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

    media
}

fn text(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

/// Collapses runs of spaces and blank lines.
fn clean(text: &str) -> String {
    let lines: Vec<String> = text
        .replace('\r', "\n")
        .lines()
        .map(|l| l.split_whitespace().collect::<Vec<_>>().join(" "))
        .collect();
    let mut out = Vec::new();
    for line in lines {
        if line.is_empty() && out.last().is_some_and(String::is_empty) {
            continue;
        }
        out.push(line);
    }
    out.join("\n").trim().to_owned()
}

/// `//host/x` and `http://` image hosts become `https://`.
fn https(url: String) -> String {
    if let Some(rest) = url.strip_prefix("//") {
        format!("https://{rest}")
    } else if let Some(rest) = url.strip_prefix("http://") {
        format!("https://{rest}")
    } else {
        url
    }
}

/// `"12:34"` or `"1:02:03"` in seconds.
fn duration(text: &str) -> Option<f64> {
    text.split(':').try_fold(0.0, |total, part| {
        part.trim().parse::<f64>().ok().map(|n| total * 60.0 + n)
    })
}

#[cfg(test)]
mod tests {
    use wiremock::matchers::{header, method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    use super::*;

    fn fixture() -> Value {
        serde_json::from_str(include_str!("../fixtures/feed.json")).unwrap()
    }

    fn items(page: &Value) -> Vec<RawItem> {
        page["data"]["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(raw_item)
            .collect()
    }

    #[test]
    fn maps_videos_with_embed_and_duration() {
        let video = &items(&fixture())[0];
        assert_eq!(video.external_id, "900000000000000001");
        assert_eq!(
            video.url.as_deref(),
            Some("https://www.bilibili.com/video/BV1xx411c7mD")
        );
        assert_eq!(video.title.as_deref(), Some("我们测试了最新相机"));
        assert_eq!(video.text, "新视频来了");
        assert_eq!(
            video.author.as_ref().unwrap().avatar_url.as_deref(),
            Some("https://i0.hdslb.com/bfs/face/a.jpg")
        );
        assert_eq!(
            video.published_at,
            DateTime::from_timestamp(1_792_141_200, 0)
        );
        let media = &video.media[0];
        assert_eq!(
            (media.kind, media.duration),
            (MediaKind::Video, Some(754.0))
        );
        assert_eq!(
            media.thumbnail_url.as_deref(),
            Some("https://i1.hdslb.com/bfs/archive/c.jpg")
        );
        assert!(
            media
                .embed_url
                .as_deref()
                .unwrap()
                .contains("bvid=BV1xx411c7mD")
        );
    }

    #[test]
    fn maps_image_posts_and_forwards() {
        let all = items(&fixture());
        let draw = &all[1];
        assert_eq!(
            draw.title, None,
            "no title: the card uses the text's first line"
        );
        assert_eq!(draw.text, "今天画的猫\n第二行");
        assert_eq!(
            draw.url.as_deref(),
            Some("https://t.bilibili.com/900000000000000002")
        );
        assert_eq!(draw.media.len(), 2);

        let forward = &all[2];
        let orig = forward.reference.as_ref().unwrap();
        assert_eq!(orig.kind, ReferenceKind::Repost);
        assert_eq!(orig.item.text, "原始动态内容");
    }

    #[test]
    fn maps_live_streams_and_drops_types_it_cannot_show() {
        let live = json!({"id_str": "7", "modules": {
        "module_author": {"name": "主播", "pub_ts": 1_792_141_200},
        "module_dynamic": {"desc": null, "major": {"type": "MAJOR_TYPE_LIVE_RCMD", "live_rcmd": {
            "content": json!({"live_play_info": {"title": "今晚直播", "cover": "//i0.hdslb.com/bfs/live/c.jpg",
                                                  "link": "//live.bilibili.com/123"}}).to_string()
        }}}}});
        let item = raw_item(&live).unwrap();
        assert_eq!(item.title.as_deref(), Some("今晚直播"));
        assert_eq!(item.url.as_deref(), Some("https://live.bilibili.com/123"));
        assert_eq!(item.media[0].url, "https://i0.hdslb.com/bfs/live/c.jpg");

        let unknown = json!({"id_str": "8", "modules": {"module_author": {"name": "x"},
            "module_dynamic": {"desc": null, "major": {"type": "MAJOR_TYPE_NEW_THING", "new_thing": {}}}}});
        assert!(raw_item(&unknown).is_none());
    }

    #[test]
    fn parses_durations() {
        assert_eq!(duration("12:34"), Some(754.0));
        assert_eq!(duration("1:02:03"), Some(3723.0));
        assert_eq!(duration("live"), None);
    }

    #[tokio::test]
    async fn fetch_sends_cookies_pages_and_maps_logout_to_auth_required() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/x/polymer/web-dynamic/v1/feed/all"))
            .and(header("cookie", "SESSDATA=s; DedeUserID=42"))
            .and(query_param("features", "itemOpusStyle"))
            .respond_with(ResponseTemplate::new(200).set_body_json(fixture()))
            .mount(&server)
            .await;
        let endpoints = Endpoints {
            passport: server.uri(),
            api: server.uri(),
        };
        let client = reqwest::Client::new();

        let result = fetch(
            &client,
            &endpoints,
            &json!({"secrets": {"sessdata": "s", "dedeuserid": "42"}, "settings": {"limit": 2}}),
        )
        .await
        .unwrap();
        assert_eq!(
            result["items"].as_array().unwrap().len(),
            2,
            "limit applies"
        );

        let missing = fetch(&client, &endpoints, &json!({"secrets": {}}))
            .await
            .unwrap_err();
        assert_eq!(missing.code, crate::AUTH_REQUIRED);

        let logged_out = MockServer::start().await;
        Mock::given(method("GET"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_json(json!({"code": -101, "message": "账号未登录"})),
            )
            .mount(&logged_out)
            .await;
        let endpoints = Endpoints {
            passport: String::new(),
            api: logged_out.uri(),
        };
        let error = fetch(
            &client,
            &endpoints,
            &json!({"secrets": {"sessdata": "old"}}),
        )
        .await
        .unwrap_err();
        assert_eq!(error.code, crate::AUTH_REQUIRED);
    }
}
