//! Minimal HTML-to-text for feed titles and summaries: drops tags, decodes common entities,
//! collapses whitespace. Full article extraction is a separate step.

pub fn to_text(html: &str) -> String {
    let mut text = String::with_capacity(html.len());
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' if in_tag => {
                in_tag = false;
                text.push(' ');
            }
            _ if !in_tag => text.push(c),
            _ => {}
        }
    }
    let decoded = decode_entities(&text);
    let mut out = String::with_capacity(decoded.len());
    for word in decoded.split_whitespace() {
        if !out.is_empty() && !starts_with_closing_punctuation(word) {
            out.push(' ');
        }
        out.push_str(word);
    }
    out
}

/// Tags are replaced by spaces, so `Hello <b>world</b>.` would read `Hello world .`.
fn starts_with_closing_punctuation(word: &str) -> bool {
    word.starts_with(['.', ',', ';', ':', '!', '?', ')'])
}

fn decode_entities(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find('&') {
        out.push_str(&rest[..start]);
        let tail = &rest[start..];
        if let Some((decoded, end)) = tail
            .find(';')
            .filter(|&end| end <= 10)
            .and_then(|end| Some((decode_entity(&tail[1..end])?, end)))
        {
            out.push(decoded);
            rest = &tail[end + 1..];
        } else {
            out.push('&');
            rest = &tail[1..];
        }
    }
    out.push_str(rest);
    out
}

fn decode_entity(name: &str) -> Option<char> {
    match name {
        "amp" => Some('&'),
        "lt" => Some('<'),
        "gt" => Some('>'),
        "quot" => Some('"'),
        "apos" => Some('\''),
        "nbsp" => Some(' '),
        _ => {
            let code = name.strip_prefix('#')?;
            let value = match code.strip_prefix(['x', 'X']) {
                Some(hex) => u32::from_str_radix(hex, 16).ok()?,
                None => code.parse().ok()?,
            };
            char::from_u32(value)
        }
    }
}

pub fn truncate_chars(text: &str, max: usize) -> String {
    match text.char_indices().nth(max) {
        Some((end, _)) => format!("{}…", text[..end].trim_end()),
        None => text.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_tags_and_collapses_whitespace() {
        assert_eq!(
            to_text("<p>Hello <b>world</b>.</p>\n\n<p>Next</p>"),
            "Hello world. Next"
        );
    }

    #[test]
    fn decodes_entities() {
        assert_eq!(
            to_text("Fish &amp; chips &lt;3 &#8217; &#x4e2d; &nbsp;x"),
            "Fish & chips <3 ’ 中 x"
        );
    }

    #[test]
    fn leaves_unknown_or_bare_ampersands() {
        assert_eq!(to_text("AT&T &bogus; a & b"), "AT&T &bogus; a & b");
    }

    #[test]
    fn truncates_with_ellipsis() {
        assert_eq!(truncate_chars("abcdef", 3), "abc…");
        assert_eq!(truncate_chars("abc", 3), "abc");
        assert_eq!(truncate_chars("汉字汉字", 2), "汉字…");
    }
}
