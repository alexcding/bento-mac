//! Minimal HTML-to-text for feed titles and summaries: drops tags, decodes common entities,
//! collapses whitespace. Full article extraction is a separate step.

pub fn to_text(html: &str) -> String {
    let mut text = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(start) = rest.find('<') {
        text.push_str(&rest[..start]);
        let tail = &rest[start..];
        if let Some(len) = tag_len(tail) {
            text.push(' ');
            rest = &tail[len..];
        } else {
            text.push('<');
            rest = &tail[1..];
        }
    }
    text.push_str(rest);
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

/// HTML elements stripped from feed text. Anything else in angle brackets (`Vec<T>`, `1 < 2`) is
/// kept, because feed parsers hand back decoded text labelled as HTML.
const TAGS: &[&str] = &[
    "a",
    "abbr",
    "b",
    "blockquote",
    "br",
    "cite",
    "code",
    "dd",
    "del",
    "div",
    "dl",
    "dt",
    "em",
    "figcaption",
    "figure",
    "font",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "hr",
    "i",
    "img",
    "ins",
    "li",
    "mark",
    "ol",
    "p",
    "picture",
    "pre",
    "q",
    "s",
    "small",
    "source",
    "span",
    "strike",
    "strong",
    "sub",
    "sup",
    "table",
    "tbody",
    "td",
    "th",
    "thead",
    "tr",
    "u",
    "ul",
    "video",
];

/// Length of the HTML tag or comment at the start of `text`, if it is one.
fn tag_len(text: &str) -> Option<usize> {
    if let Some(comment) = text.strip_prefix("<!--") {
        return comment.find("-->").map(|end| 4 + end + 3);
    }
    let end = text.find('>')?;
    let inner = text[1..end].trim_start_matches('/');
    let name: String = inner
        .chars()
        .take_while(char::is_ascii_alphanumeric)
        .collect();
    let after_name = &inner[name.len()..];
    let well_formed = after_name.is_empty() || after_name.starts_with([' ', '\t', '\n', '/']);
    (well_formed && TAGS.contains(&name.to_ascii_lowercase().as_str())).then_some(end + 1)
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
    fn keeps_angle_brackets_that_are_not_html() {
        assert_eq!(
            to_text("Why Vec<T> beats arrays & 1 < 2"),
            "Why Vec<T> beats arrays & 1 < 2"
        );
        assert_eq!(
            to_text("<a href=\"x\">link</a><!-- c --><br/>end"),
            "link end"
        );
        assert_eq!(to_text("a <B>bold</B> <unknown>"), "a bold <unknown>");
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
