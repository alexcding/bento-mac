//! Compressed article detail, in any of a few formats.
//!
//! Format: one header byte naming the codec, then the payload. `0x01` is raw DEFLATE (RFC 1951)
//! of Markdown, which Apple's Compression framework reads as `COMPRESSION_ZLIB`. `0x02` is a
//! format byte ([`DetailFormat`]) followed by raw DEFLATE of the body. Markdown is still written
//! as `0x01`, so apps that only know it keep reading it.

use std::borrow::Cow;
use std::io::{Read, Write};

use flate2::{Compression, read::DeflateDecoder, write::DeflateEncoder};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Longest detail kept, in characters (not bytes).
pub const MAX_DETAIL_CHARS: usize = 12_000;
/// Longest HTML detail kept: markup takes more characters for the same article.
pub const MAX_HTML_DETAIL_CHARS: usize = 60_000;

const CODEC_DEFLATE: u8 = 0x01;
const CODEC_DEFLATE_FORMATTED: u8 = 0x02;

/// What a detail body is written in.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DetailFormat {
    #[default]
    Markdown,
    Html,
    Text,
    /// A web address to open, for sources whose detail is a page elsewhere.
    Link,
}

impl DetailFormat {
    const fn byte(self) -> u8 {
        match self {
            Self::Markdown => 0,
            Self::Html => 1,
            Self::Text => 2,
            Self::Link => 3,
        }
    }

    const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Markdown),
            1 => Some(Self::Html),
            2 => Some(Self::Text),
            3 => Some(Self::Link),
            _ => None,
        }
    }

    const fn max_chars(self) -> usize {
        match self {
            Self::Html => MAX_HTML_DETAIL_CHARS,
            _ => MAX_DETAIL_CHARS,
        }
    }
}

/// An item's long-form content: the article, a post's full text, or a link to it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Detail {
    #[serde(default)]
    pub format: DetailFormat,
    pub body: String,
}

impl Detail {
    #[must_use]
    pub fn new(format: DetailFormat, body: impl Into<String>) -> Self {
        Self {
            format,
            body: body.into(),
        }
    }

    #[must_use]
    pub fn markdown(body: impl Into<String>) -> Self {
        Self::new(DetailFormat::Markdown, body)
    }

    #[must_use]
    pub fn html(body: impl Into<String>) -> Self {
        Self::new(DetailFormat::Html, body)
    }

    /// The readable text, for AI input and length checks: HTML without its tags. A link has none.
    #[must_use]
    pub fn text(&self) -> Option<Cow<'_, str>> {
        match self.format {
            DetailFormat::Markdown | DetailFormat::Text => Some(Cow::Borrowed(&self.body)),
            DetailFormat::Html => Some(Cow::Owned(crate::html::body_to_text(&self.body))),
            DetailFormat::Link => None,
        }
    }
}

#[derive(Debug, Error)]
pub enum DetailError {
    #[error("detail blob is empty")]
    Empty,
    #[error("unknown detail codec {0:#04x}")]
    UnknownCodec(u8),
    #[error("unknown detail format {0:#04x}")]
    UnknownFormat(u8),
    #[error("corrupt detail payload")]
    Corrupt(#[source] std::io::Error),
    #[error("detail payload is not UTF-8")]
    NotUtf8(#[source] std::string::FromUtf8Error),
}

/// Truncates to the format's limit ([`MAX_DETAIL_CHARS`], or [`MAX_HTML_DETAIL_CHARS`] for HTML)
/// and compresses.
///
/// # Panics
///
/// Never: the encoder writes to memory.
#[must_use]
pub fn encode(detail: &Detail) -> Vec<u8> {
    let mut text = truncate_chars(&detail.body, detail.format.max_chars());
    if detail.format == DetailFormat::Html && text.len() < detail.body.len() {
        // Cut before a tag the limit split, so the page does not end inside `<a href="…`.
        if let Some(open) = text.rfind('<')
            && text[open..].find('>').is_none()
        {
            text = &text[..open];
        }
    }
    let header = match detail.format {
        DetailFormat::Markdown => vec![CODEC_DEFLATE],
        format => vec![CODEC_DEFLATE_FORMATTED, format.byte()],
    };
    let mut encoder = DeflateEncoder::new(header, Compression::best());
    encoder
        .write_all(text.as_bytes())
        .expect("writing to a Vec cannot fail");
    encoder.finish().expect("writing to a Vec cannot fail")
}

pub fn decode(blob: &[u8]) -> Result<Detail, DetailError> {
    let (&codec, payload) = blob.split_first().ok_or(DetailError::Empty)?;
    let (format, payload) = match codec {
        CODEC_DEFLATE => (DetailFormat::Markdown, payload),
        CODEC_DEFLATE_FORMATTED => {
            let (&byte, payload) = payload.split_first().ok_or(DetailError::Empty)?;
            let format = DetailFormat::from_byte(byte).ok_or(DetailError::UnknownFormat(byte))?;
            (format, payload)
        }
        other => return Err(DetailError::UnknownCodec(other)),
    };
    let mut bytes = Vec::new();
    DeflateDecoder::new(payload)
        .read_to_end(&mut bytes)
        .map_err(DetailError::Corrupt)?;
    let body = String::from_utf8(bytes).map_err(DetailError::NotUtf8)?;
    Ok(Detail { format, body })
}

#[must_use]
pub fn truncate_chars(text: &str, max: usize) -> &str {
    match text.char_indices().nth(max) {
        Some((end, _)) => &text[..end],
        None => text,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct Vectors {
        details: Vec<Case>,
    }

    #[derive(Deserialize)]
    struct Case {
        #[serde(default)]
        format: DetailFormat,
        markdown: String,
        encoded_base64: String,
    }

    #[test]
    fn decodes_shared_vectors() {
        let vectors: Vectors =
            serde_json::from_str(include_str!("../../../testdata/vectors.json")).unwrap();
        for case in vectors.details {
            let blob = base64::engine::general_purpose::STANDARD
                .decode(case.encoded_base64)
                .unwrap();
            assert_eq!(
                decode(&blob).unwrap(),
                Detail::new(case.format, case.markdown)
            );
        }
    }

    #[test]
    fn round_trips() {
        let markdown = Detail::markdown("# 标题\n\nbody **bold**");
        let blob = encode(&markdown);
        assert_eq!(blob[0], CODEC_DEFLATE, "Markdown keeps the original codec");
        assert_eq!(decode(&blob).unwrap(), markdown);

        let html = Detail::html("<p>标题 <img src=\"https://x/1.jpg\"></p>");
        let blob = encode(&html);
        assert_eq!(&blob[..2], &[CODEC_DEFLATE_FORMATTED, 1]);
        assert_eq!(decode(&blob).unwrap(), html);
    }

    #[test]
    fn truncates_on_char_boundary() {
        let text = "汉".repeat(MAX_HTML_DETAIL_CHARS + 5);
        let markdown = decode(&encode(&Detail::markdown(text.clone()))).unwrap();
        assert_eq!(markdown.body.chars().count(), MAX_DETAIL_CHARS);
        let html = decode(&encode(&Detail::html(text))).unwrap();
        assert_eq!(html.body.chars().count(), MAX_HTML_DETAIL_CHARS);

        let cut_tag = format!(
            "{}<a href=\"https://example.com/long\">x</a>",
            "a".repeat(MAX_HTML_DETAIL_CHARS - 5)
        );
        let html = decode(&encode(&Detail::html(cut_tag))).unwrap();
        assert_eq!(
            html.body,
            "a".repeat(MAX_HTML_DETAIL_CHARS - 5),
            "never ends inside a tag"
        );
    }

    #[test]
    fn rejects_bad_blobs() {
        assert!(matches!(decode(&[]), Err(DetailError::Empty)));
        assert!(matches!(
            decode(&[0x7f, 1]),
            Err(DetailError::UnknownCodec(0x7f))
        ));
        assert!(matches!(
            decode(&[CODEC_DEFLATE_FORMATTED, 9, 1]),
            Err(DetailError::UnknownFormat(9))
        ));
    }
}
