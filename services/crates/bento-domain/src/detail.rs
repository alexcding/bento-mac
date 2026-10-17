//! Compressed article detail.
//!
//! Format: one header byte naming the codec, then the payload. `0x01` is raw DEFLATE (RFC 1951),
//! which Apple's Compression framework reads as `COMPRESSION_ZLIB`.

use std::io::{Read, Write};

use flate2::{Compression, read::DeflateDecoder, write::DeflateEncoder};
use thiserror::Error;

/// Longest detail kept, in characters (not bytes).
pub const MAX_DETAIL_CHARS: usize = 12_000;

const CODEC_DEFLATE: u8 = 0x01;

#[derive(Debug, Error)]
pub enum DetailError {
    #[error("detail blob is empty")]
    Empty,
    #[error("unknown detail codec {0:#04x}")]
    UnknownCodec(u8),
    #[error("corrupt detail payload")]
    Corrupt(#[source] std::io::Error),
    #[error("detail payload is not UTF-8")]
    NotUtf8(#[source] std::string::FromUtf8Error),
}

/// Truncates to [`MAX_DETAIL_CHARS`] and compresses.
///
/// # Panics
///
/// Never: the encoder writes to memory.
#[must_use]
pub fn encode(markdown: &str) -> Vec<u8> {
    let text = truncate_chars(markdown, MAX_DETAIL_CHARS);
    let mut encoder = DeflateEncoder::new(vec![CODEC_DEFLATE], Compression::best());
    encoder
        .write_all(text.as_bytes())
        .expect("writing to a Vec cannot fail");
    encoder.finish().expect("writing to a Vec cannot fail")
}

pub fn decode(blob: &[u8]) -> Result<String, DetailError> {
    let (&codec, payload) = blob.split_first().ok_or(DetailError::Empty)?;
    match codec {
        CODEC_DEFLATE => {
            let mut bytes = Vec::new();
            DeflateDecoder::new(payload)
                .read_to_end(&mut bytes)
                .map_err(DetailError::Corrupt)?;
            String::from_utf8(bytes).map_err(DetailError::NotUtf8)
        }
        other => Err(DetailError::UnknownCodec(other)),
    }
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
            assert_eq!(decode(&blob).unwrap(), case.markdown);
        }
    }

    #[test]
    fn round_trips() {
        let text = "# 标题\n\nbody **bold**";
        let blob = encode(text);
        assert_eq!(blob[0], CODEC_DEFLATE);
        assert_eq!(decode(&blob).unwrap(), text);
    }

    #[test]
    fn truncates_on_char_boundary() {
        let text = "汉".repeat(MAX_DETAIL_CHARS + 5);
        let decoded = decode(&encode(&text)).unwrap();
        assert_eq!(decoded.chars().count(), MAX_DETAIL_CHARS);
    }

    #[test]
    fn rejects_bad_blobs() {
        assert!(matches!(decode(&[]), Err(DetailError::Empty)));
        assert!(matches!(
            decode(&[0x7f, 1]),
            Err(DetailError::UnknownCodec(0x7f))
        ));
    }
}
