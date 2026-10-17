//! `mapping.json`: turns a command's JSON output into raw items with RFC 9535 `JSONPath`.
//!
//! A value is one expression or a list tried in order until one yields a non-empty value. An
//! expression starting with `$` is a `JSONPath` (first match); anything else is a template where
//! `{$...}` is replaced by a `JSONPath` value (a template with a missing value yields nothing).

use bento_domain::{Author, Media, MediaKind, RawItem, Reference, ReferenceKind, html};
use chrono::{DateTime, NaiveDate, NaiveDateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use serde_json_path::JsonPath;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Mapping {
    /// Paths selecting the items; the first that selects anything wins. A selected array
    /// contributes its elements. Default `["$"]`.
    #[serde(default = "default_items")]
    pub items: Vec<String>,
    #[serde(flatten)]
    pub fields: Fields,
}

fn default_items() -> Vec<String> {
    vec!["$".into()]
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fields {
    pub external_id: Expr,
    #[serde(default)]
    pub url: Expr,
    #[serde(default)]
    pub title: Expr,
    #[serde(default)]
    pub text: Expr,
    #[serde(default)]
    pub author_name: Expr,
    #[serde(default)]
    pub author_handle: Expr,
    #[serde(default)]
    pub author_avatar_url: Expr,
    /// Unix seconds or milliseconds, `YYYYMMDD`, RFC 3339, RFC 2822, or Twitter's
    /// `Wed Oct 10 20:19:24 +0000 2018`.
    #[serde(default)]
    pub published_at: Expr,
    #[serde(default)]
    pub language: Expr,
    #[serde(default)]
    pub media: Vec<MediaMapping>,
    /// Quoted or reposted items, mapped with these same fields; the first that exists wins.
    #[serde(default)]
    pub reference: Vec<ReferenceMapping>,
    /// Items without a URL are dropped (the card links to the original).
    #[serde(default = "yes")]
    pub require_url: bool,
}

fn yes() -> bool {
    true
}

/// One expression or an ordered list of fallbacks.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Expr {
    #[default]
    None,
    One(String),
    Any(Vec<String>),
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MediaMapping {
    #[serde(rename = "type")]
    pub kind: MediaKind,
    /// Path to an array; the other expressions then apply to each element. Without it they apply
    /// to the item.
    #[serde(default)]
    pub each: Option<String>,
    pub url: Expr,
    #[serde(default)]
    pub thumbnail_url: Expr,
    #[serde(default)]
    pub width: Expr,
    #[serde(default)]
    pub height: Expr,
    #[serde(default)]
    pub duration: Expr,
    #[serde(default)]
    pub embed_url: Expr,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReferenceMapping {
    #[serde(rename = "type")]
    pub kind: ReferenceKind,
    /// Paths to the nested item; the first that exists wins.
    pub path: Expr,
}

#[derive(Debug, thiserror::Error)]
pub enum MappingError {
    #[error("invalid JSONPath `{path}`: {message}")]
    Path { path: String, message: String },
}

impl Mapping {
    /// Checks every `JSONPath` once, so a broken mapping fails at load instead of per fetch.
    pub fn validate(&self) -> Result<(), MappingError> {
        let mut paths: Vec<&str> = self.items.iter().map(String::as_str).collect();
        let fields = &self.fields;
        for expr in [
            &fields.external_id,
            &fields.url,
            &fields.title,
            &fields.text,
            &fields.author_name,
            &fields.author_handle,
            &fields.author_avatar_url,
            &fields.published_at,
            &fields.language,
        ] {
            paths.extend(expr.paths());
        }
        for media in &fields.media {
            paths.extend(media.each.as_deref());
            for expr in [
                &media.url,
                &media.thumbnail_url,
                &media.width,
                &media.height,
                &media.duration,
                &media.embed_url,
            ] {
                paths.extend(expr.paths());
            }
        }
        for reference in &fields.reference {
            paths.extend(reference.path.paths());
        }
        for path in paths {
            parse_path(path)?;
        }
        Ok(())
    }

    /// Maps every item in `document`. Items without an ID (or URL, when required) are skipped.
    #[must_use]
    pub fn map(&self, document: &Value) -> Vec<RawItem> {
        let mut items = Vec::new();
        for path in &self.items {
            let selected = query(path, document);
            if selected.is_empty() {
                continue;
            }
            for value in selected {
                match value {
                    Value::Array(elements) => {
                        items.extend(elements.iter().filter_map(|e| self.fields.item(e)));
                    }
                    other => items.extend(self.fields.item(other)),
                }
            }
            break;
        }
        items
    }
}

impl Fields {
    fn item(&self, value: &Value) -> Option<RawItem> {
        let external_id = self.external_id.string(value)?;
        let url = self.url.string(value);
        if self.require_url && url.is_none() {
            return None;
        }
        let reference = self.reference.iter().find_map(|reference| {
            let nested = reference
                .path
                .values(value)
                .into_iter()
                .find(|v| v.is_object())?;
            let mut fields = self.clone();
            fields.reference.clear();
            Some(Box::new(Reference {
                kind: reference.kind,
                item: fields.item(nested)?,
            }))
        });
        Some(RawItem {
            external_id,
            url,
            title: self
                .title
                .string(value)
                .map(|t| html::title_to_text(&t))
                .filter(|t| !t.is_empty()),
            text: self
                .text
                .string(value)
                .map(|t| html::body_to_text(&t))
                .unwrap_or_default(),
            author: Some(Author {
                name: self.author_name.string(value),
                handle: self.author_handle.string(value),
                avatar_url: self.author_avatar_url.string(value).map(https),
            }),
            media: self.media.iter().flat_map(|m| m.map(value)).collect(),
            published_at: self
                .published_at
                .values(value)
                .into_iter()
                .find_map(parse_date),
            language: self.language.string(value),
            reference,
            ..RawItem::default()
        })
    }
}

impl MediaMapping {
    fn map(&self, item: &Value) -> Vec<Media> {
        let contexts: Vec<&Value> = match &self.each {
            Some(path) => query(path, item)
                .into_iter()
                .flat_map(|v| match v {
                    Value::Array(elements) => elements.iter().collect(),
                    other => vec![other],
                })
                .collect(),
            None => vec![item],
        };
        contexts
            .into_iter()
            .filter_map(|context| {
                Some(Media {
                    kind: self.kind,
                    url: self
                        .url
                        .string(context)
                        .map(https)
                        .filter(|u| is_web_url(u))?,
                    width: self.width.number(context).and_then(dimension),
                    height: self.height.number(context).and_then(dimension),
                    thumbnail_url: self.thumbnail_url.string(context).map(https),
                    duration: self.duration.number(context),
                    embed_url: self.embed_url.string(context),
                })
            })
            .collect()
    }
}

impl Expr {
    fn alternatives(&self) -> &[String] {
        match self {
            Expr::None => &[],
            Expr::One(one) => std::slice::from_ref(one),
            Expr::Any(any) => any,
        }
    }

    fn paths(&self) -> Vec<&str> {
        self.alternatives()
            .iter()
            .flat_map(|alternative| {
                if alternative.starts_with('$') {
                    vec![alternative.as_str()]
                } else {
                    template_paths(alternative)
                }
            })
            .collect()
    }

    /// The first alternative that yields a non-empty string.
    fn string(&self, value: &Value) -> Option<String> {
        self.alternatives().iter().find_map(|alternative| {
            if alternative.starts_with('$') {
                query(alternative, value)
                    .into_iter()
                    .find_map(scalar_string)
            } else {
                render(alternative, value)
            }
        })
    }

    fn number(&self, value: &Value) -> Option<f64> {
        self.alternatives().iter().find_map(|alternative| {
            query(alternative, value).into_iter().find_map(|v| match v {
                Value::Number(n) => n.as_f64(),
                Value::String(s) => s.trim().parse().ok(),
                _ => None,
            })
        })
    }

    /// Every value the alternatives select, in order (for dates and references).
    fn values<'a>(&self, value: &'a Value) -> Vec<&'a Value> {
        self.alternatives()
            .iter()
            .flat_map(|alternative| query(alternative, value))
            .collect()
    }
}

fn parse_path(path: &str) -> Result<JsonPath, MappingError> {
    JsonPath::parse(path).map_err(|error| MappingError::Path {
        path: path.into(),
        message: error.to_string(),
    })
}

/// Paths were validated at load, so a parse failure here only skips the expression.
fn query<'a>(path: &str, value: &'a Value) -> Vec<&'a Value> {
    JsonPath::parse(path)
        .map(|p| p.query(value).all())
        .unwrap_or_default()
}

fn scalar_string(value: &Value) -> Option<String> {
    let text = match value {
        Value::String(s) => s.trim().to_owned(),
        Value::Number(n) => n.to_string(),
        _ => return None,
    };
    (!text.is_empty()).then_some(text)
}

fn template_paths(template: &str) -> Vec<&str> {
    let mut paths = Vec::new();
    let mut rest = template;
    while let Some(start) = rest.find("{$") {
        let Some(end) = rest[start..].find('}') else {
            break;
        };
        paths.push(&rest[start + 1..start + end]);
        rest = &rest[start + end + 1..];
    }
    paths
}

fn render(template: &str, value: &Value) -> Option<String> {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(start) = rest.find("{$") {
        out.push_str(&rest[..start]);
        let end = rest[start..].find('}')?;
        let path = &rest[start + 1..start + end];
        out.push_str(&query(path, value).into_iter().find_map(scalar_string)?);
        rest = &rest[start + end + 1..];
    }
    out.push_str(rest);
    (!out.is_empty()).then_some(out)
}

/// A pixel dimension from a JSON number; fractions are dropped, negatives and overflow rejected.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn dimension(value: f64) -> Option<u32> {
    (value >= 0.0 && value <= f64::from(u32::MAX)).then_some(value as u32)
}

fn is_web_url(url: &str) -> bool {
    url.starts_with("https://") || url.starts_with("http://")
}

/// Protocol-relative URLs (`//cdn…`) become https.
fn https(url: String) -> String {
    match url.strip_prefix("//") {
        Some(rest) => format!("https://{rest}"),
        None => url,
    }
}

fn parse_date(value: &Value) -> Option<DateTime<Utc>> {
    match value {
        Value::Number(n) => n.as_f64().and_then(from_unix),
        Value::String(s) => {
            let s = s.trim();
            if s.len() == 8 && s.bytes().all(|b| b.is_ascii_digit()) {
                let date = NaiveDate::parse_from_str(s, "%Y%m%d").ok()?;
                return Some(Utc.from_utc_datetime(&date.and_hms_opt(0, 0, 0)?));
            }
            if let Ok(number) = s.parse::<f64>() {
                return from_unix(number);
            }
            DateTime::parse_from_rfc3339(s)
                .or_else(|_| DateTime::parse_from_rfc2822(s))
                .or_else(|_| DateTime::parse_from_str(s, "%a %b %d %H:%M:%S %z %Y"))
                .map(|d| d.with_timezone(&Utc))
                .ok()
                .or_else(|| {
                    NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S")
                        .ok()
                        .map(|d| Utc.from_utc_datetime(&d))
                })
        }
        _ => None,
    }
}

/// Seconds, or milliseconds when the value is too large to be seconds.
#[allow(clippy::cast_possible_truncation)]
fn from_unix(value: f64) -> Option<DateTime<Utc>> {
    let millis = if value > 1e11 { value } else { value * 1000.0 };
    DateTime::from_timestamp_millis(millis as i64)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn mapping(json: Value) -> Mapping {
        let mapping: Mapping = serde_json::from_value(json).unwrap();
        mapping.validate().unwrap();
        mapping
    }

    #[test]
    fn maps_fields_with_fallbacks_and_templates() {
        let m = mapping(json!({
            "items": ["$.data[*]"],
            "external_id": ["$.id_str", "$.id"],
            "url": ["$.url", "https://x.com/{$.user.screen_name}/status/{$.id}"],
            "text": "$.full_text",
            "author_name": "$.user.name",
            "author_avatar_url": "$.user.avatar",
            "published_at": "$.created_at"
        }));
        let doc = json!({"data": [{
            "id": 42, "full_text": "Hello &amp; <b>world</b>",
            "user": {"name": "Ann", "screen_name": "ann", "avatar": "//cdn/a.png"},
            "created_at": "Wed Oct 10 20:19:24 +0000 2018"
        }]});

        let items = m.map(&doc);

        assert_eq!(items.len(), 1);
        let item = &items[0];
        assert_eq!(item.external_id, "42");
        assert_eq!(item.url.as_deref(), Some("https://x.com/ann/status/42"));
        assert_eq!(item.text, "Hello & world");
        assert_eq!(
            item.author.as_ref().unwrap().avatar_url.as_deref(),
            Some("https://cdn/a.png")
        );
        assert_eq!(
            item.published_at,
            Some(Utc.with_ymd_and_hms(2018, 10, 10, 20, 19, 24).unwrap())
        );
    }

    #[test]
    fn first_items_path_that_selects_anything_wins_and_arrays_flatten() {
        let m = mapping(
            json!({"items": ["$.missing", "$"], "external_id": "$.id", "require_url": false}),
        );
        assert_eq!(m.map(&json!([{"id": "a"}, {"id": "b"}])).len(), 2);
        assert_eq!(m.map(&json!({"id": "solo"}))[0].external_id, "solo");
    }

    #[test]
    fn skips_items_without_id_or_required_url() {
        let m = mapping(json!({"external_id": "$.id", "url": "$.url"}));
        let items = m.map(&json!([{"id": "1", "url": "u"}, {"id": "2"}, {"url": "v"}]));
        assert_eq!(
            items
                .iter()
                .map(|i| i.external_id.as_str())
                .collect::<Vec<_>>(),
            ["1"]
        );
    }

    #[test]
    fn parses_every_supported_date_form() {
        let at = Utc.with_ymd_and_hms(2026, 10, 16, 0, 0, 0).unwrap();
        for value in [
            json!(1_792_108_800),
            json!(1_792_108_800_000_i64),
            json!("1792108800"),
            json!("20261016"),
            json!("2026-10-16T00:00:00Z"),
            json!("Fri, 16 Oct 2026 00:00:00 GMT"),
            json!("2026-10-16 00:00:00"),
        ] {
            assert_eq!(parse_date(&value), Some(at), "{value}");
        }
        assert_eq!(parse_date(&json!("someday")), None);
    }

    #[test]
    fn maps_media_per_element_and_references() {
        let m = mapping(json!({
            "external_id": "$.id",
            "url": "https://example.com/{$.id}",
            "media": [
                {"type": "image", "each": "$.photos", "url": ["$.src", "$"]},
                {"type": "image", "url": "$.thumbnail"},
                {"type": "video", "url": "$.video", "duration": "$.secs", "embed_url": "https://e/{$.id}"}
            ],
            "reference": [{"type": "repost", "path": "$.retweeted"}, {"type": "quote", "path": "$.quoted"}]
        }));
        let doc = json!({"id": "1", "photos": [{"src": "https://a.jpg"}, "//b.jpg"], "thumbnail": "self",
                         "video": "https://v.mp4", "secs": 12,
                         "quoted": {"id": "0", "photos": []}});

        let item = &m.map(&doc)[0];

        let urls: Vec<_> = item.media.iter().map(|m| m.url.as_str()).collect();
        assert_eq!(
            urls,
            ["https://a.jpg", "https://b.jpg", "https://v.mp4"],
            "non-web URLs dropped"
        );
        assert_eq!(item.media[2].duration, Some(12.0));
        assert_eq!(item.media[2].embed_url.as_deref(), Some("https://e/1"));
        let reference = item.reference.as_ref().unwrap();
        assert_eq!(reference.kind, ReferenceKind::Quote);
        assert_eq!(reference.item.external_id, "0");
    }

    #[test]
    fn rejects_invalid_paths_at_validation() {
        let m: Mapping = serde_json::from_value(json!({"external_id": "$[?"})).unwrap();
        assert!(m.validate().is_err());
    }
}
