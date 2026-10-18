//! Minimal HTML-to-text for feed titles and bodies: drops tags, decodes common entities, collapses
//! whitespace. Full article extraction is a separate step.
//!
//! Feed parsers hand back already-decoded text labelled as HTML, so a literal `<` (`Vec<T>`,
//! `1 < 2`) is common. Bodies are real HTML and drop every well-formed tag; titles are mostly plain
//! text and drop only common inline tags written with quoted attributes.

/// Item bodies and summaries.
#[must_use]
pub fn body_to_text(html: &str) -> String {
    to_text(html, Mode::Body)
}

/// Item and feed titles.
#[must_use]
pub fn title_to_text(html: &str) -> String {
    to_text(html, Mode::Title)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Body,
    Title,
}

/// Elements whose content is never text.
const SKIPPED_ELEMENTS: &[&str] = &["script", "style"];

/// Inline elements stripped from titles.
const TITLE_TAGS: &[&str] = &[
    "a", "abbr", "b", "br", "cite", "code", "em", "font", "i", "mark", "q", "s", "small", "span",
    "strong", "sub", "sup", "u",
];

fn to_text(html: &str, mode: Mode) -> String {
    let mut text = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(start) = rest.find('<') {
        text.push_str(&rest[..start]);
        let tail = &rest[start..];
        if let Some(tag) = parse_tag(tail, mode) {
            text.push(' ');
            rest = &tail[tag.len..];
            if mode == Mode::Body && !tag.closing && SKIPPED_ELEMENTS.contains(&tag.name.as_str()) {
                rest = skip_past_closing(rest, &tag.name);
            }
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

struct Tag {
    /// Bytes from `<` through `>`.
    len: usize,
    /// Lowercased element name; empty for comments and declarations.
    name: String,
    closing: bool,
}

/// The tag, comment or declaration at the start of `text`, if `mode` strips it.
fn parse_tag(text: &str, mode: Mode) -> Option<Tag> {
    if let Some(comment) = text.strip_prefix("<!--") {
        let end = comment.find("-->")?;
        return Some(Tag {
            len: 4 + end + 3,
            name: String::new(),
            closing: false,
        });
    }
    let end = text.find('>')?;
    let inner = &text[1..end];
    if mode == Mode::Body && inner.starts_with('!') {
        return Some(Tag {
            len: end + 1,
            name: String::new(),
            closing: false,
        });
    }
    let (closing, inner) = match inner.strip_prefix('/') {
        Some(rest) => (true, rest),
        None => (false, inner),
    };
    let name_len = inner
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == ':'))
        .unwrap_or(inner.len());
    let name = &inner[..name_len];
    if !name.starts_with(|c: char| c.is_ascii_alphabetic()) {
        return None;
    }
    let attributes = inner[name_len..].trim_end_matches('/');
    if !(attributes.is_empty() || attributes.starts_with(char::is_whitespace)) {
        return None;
    }
    let name = name.to_ascii_lowercase();
    let strips = match mode {
        Mode::Body => true,
        Mode::Title => TITLE_TAGS.contains(&name.as_str()) && quoted_attributes_only(attributes),
    };
    strips.then_some(Tag {
        len: end + 1,
        name,
        closing,
    })
}

/// True for `""` or ` key="v" other='w'`: every attribute has a quoted value. Rejects text such as
/// ` and b` in `a<b and b>c`.
fn quoted_attributes_only(attributes: &str) -> bool {
    let mut rest = attributes.trim();
    while !rest.is_empty() {
        let Some(eq) = rest.find('=') else {
            return false;
        };
        let key = &rest[..eq];
        if key.is_empty()
            || !key
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == ':')
        {
            return false;
        }
        let value = &rest[eq + 1..];
        let Some(quote) = value.chars().next().filter(|c| *c == '"' || *c == '\'') else {
            return false;
        };
        let Some(close) = value[1..].find(quote) else {
            return false;
        };
        rest = value[close + 2..].trim_start();
    }
    true
}

/// The text after `</name>`, or nothing if it never closes.
fn skip_past_closing<'a>(text: &'a str, name: &str) -> &'a str {
    let closing = format!("</{name}");
    let lower = text.to_ascii_lowercase();
    match lower.find(&closing) {
        Some(start) => text[start..]
            .find('>')
            .map_or("", |end| &text[start + end + 1..]),
        None => "",
    }
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

#[must_use]
pub fn truncate_chars(text: &str, max: usize) -> String {
    match text.char_indices().nth(max) {
        Some((end, _)) => format!("{}…", text[..end].trim_end()),
        None => text.to_owned(),
    }
}

/// The first real picture in an item body, for feeds that put it in the description rather than
/// as media: an `<img>` with an `https` (or protocol-relative) `src`, skipping tracking pixels and
/// icons declared 16px or smaller. Relative sources are skipped (no base to resolve against).
#[must_use]
pub fn first_image_src(html: &str) -> Option<String> {
    let lower = html.to_ascii_lowercase();
    let mut from = 0;
    while let Some(found) = lower[from..].find("<img") {
        let start = from + found + 4;
        from = start;
        if !lower[start..].starts_with(|c: char| c.is_ascii_whitespace() || c == '/') {
            continue; // `<image>`, `<imgx>`
        }
        let attrs = tag_attributes(&html[start..]);
        let value = |name: &str| {
            attrs
                .iter()
                .find(|(key, _)| key.eq_ignore_ascii_case(name))
                .map(|(_, v)| v.as_str())
        };
        let tiny = ["width", "height"].iter().any(|name| {
            value(name)
                .and_then(|v| v.trim_end_matches("px").parse::<u32>().ok())
                .is_some_and(|px| px <= 16)
        });
        let Some(src) = value("src").map(|src| src.trim().replace("&amp;", "&")) else {
            continue;
        };
        if tiny {
            continue;
        }
        if src.starts_with("https://") {
            return Some(src);
        }
        if let Some(path) = src.strip_prefix("//") {
            return Some(format!("https://{path}"));
        }
    }
    None
}

/// A tag's `name=value` pairs, read up to its closing `>` (which may not appear inside quotes).
fn tag_attributes(tag: &str) -> Vec<(String, String)> {
    let mut attrs = Vec::new();
    let mut chars = tag.char_indices().peekable();
    loop {
        while chars
            .next_if(|(_, c)| c.is_ascii_whitespace() || *c == '/')
            .is_some()
        {}
        let Some(&(start, first)) = chars.peek() else {
            break;
        };
        if first == '>' {
            break;
        }
        let mut end = start;
        while let Some((at, c)) =
            chars.next_if(|(_, c)| !c.is_ascii_whitespace() && !matches!(c, '=' | '>' | '/'))
        {
            end = at + c.len_utf8();
        }
        let name = tag[start..end].to_owned();
        if end == start {
            chars.next(); // stray character
            continue;
        }
        while chars.next_if(|(_, c)| c.is_ascii_whitespace()).is_some() {}
        if chars.next_if(|(_, c)| *c == '=').is_none() {
            attrs.push((name, String::new()));
            continue;
        }
        while chars.next_if(|(_, c)| c.is_ascii_whitespace()).is_some() {}
        let value = match chars.peek() {
            Some(&(at, quote @ ('"' | '\''))) => {
                chars.next();
                let close = tag[at + 1..].find(quote).map_or(tag.len(), |i| at + 1 + i);
                while chars.next_if(|(i, _)| *i <= close).is_some() {}
                tag[at + 1..close].to_owned()
            }
            Some(&(at, _)) => {
                let mut end = at;
                while let Some((i, c)) =
                    chars.next_if(|(_, c)| !c.is_ascii_whitespace() && *c != '>')
                {
                    end = i + c.len_utf8();
                }
                tag[at..end].to_owned()
            }
            None => String::new(),
        };
        attrs.push((name, value));
    }
    attrs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_image_src_finds_real_pictures() {
        assert_eq!(
            first_image_src(r#"<a href="x"><img alt="a > b" width="95" src="https://d.example/1.jpg?a=1&amp;b=2"></a><img src="https://d.example/2.jpg">"#).as_deref(),
            Some("https://d.example/1.jpg?a=1&b=2")
        );
        assert_eq!(
            first_image_src("<IMG SRC='//cdn.example/x.png'/>").as_deref(),
            Some("https://cdn.example/x.png")
        );
        assert_eq!(
            first_image_src(r#"<img data-src="/lazy.png" src="https://ok.example/y.gif">"#)
                .as_deref(),
            Some("https://ok.example/y.gif"),
            "data-src is not src"
        );
        assert_eq!(
            first_image_src(r#"<image src="https://no/1.png"><img src="http://insecure/2.png"><img width="1" height="1" src="https://pixel/t.gif"><img src=https://ok.example/z.jpg>"#).as_deref(),
            Some("https://ok.example/z.jpg"),
            "skips <image>, http and tracking pixels"
        );
        assert_eq!(first_image_src("<p>No pictures</p>"), None);
        assert_eq!(
            first_image_src(r#"<img 图 标题="说明" src="https://ok.example/中.jpg">"#).as_deref(),
            Some("https://ok.example/中.jpg"),
            "non-ASCII attribute names do not split a character"
        );
    }

    #[test]
    fn body_strips_every_well_formed_tag() {
        assert_eq!(
            body_to_text(
                r#"<section><header>Hi</header><iframe src="https://y.tube/x"></iframe><time datetime="2026">now</time><o:p>x</o:p><svg><path d="M0"/></svg></section>"#
            ),
            "Hi now x"
        );
        assert_eq!(
            body_to_text("<p>Hello <b>world</b>.</p>\n\n<p>Next</p>"),
            "Hello world. Next"
        );
        assert_eq!(body_to_text(r#"x<br>y<img src="x">z"#), "x y z");
    }

    #[test]
    fn body_drops_script_and_style_contents() {
        assert_eq!(
            body_to_text("a<script>var x = 1 < 2;</script>b<STYLE>p{}</STYLE>c"),
            "a b c"
        );
        assert_eq!(body_to_text("a<script>never closed"), "a");
    }

    #[test]
    fn body_keeps_text_angle_brackets() {
        assert_eq!(body_to_text("1 < 2 and a<b"), "1 < 2 and a<b");
    }

    #[test]
    fn title_keeps_brackets_that_are_not_inline_markup() {
        assert_eq!(
            title_to_text("Why Vec<T> beats arrays & 1 < 2"),
            "Why Vec<T> beats arrays & 1 < 2"
        );
        assert_eq!(title_to_text("if a<b and b>c"), "if a<b and b>c");
        assert_eq!(title_to_text("x <i and j> y"), "x <i and j> y");
    }

    #[test]
    fn title_strips_inline_tags() {
        assert_eq!(
            title_to_text(r#"<a href="x" class='y'>link</a> <b>bold</b><br/>end"#),
            "link bold end"
        );
        assert_eq!(
            title_to_text("<section>kept</section>"),
            "<section>kept</section>"
        );
    }

    #[test]
    fn decodes_entities() {
        assert_eq!(
            body_to_text("Fish &amp; chips &lt;3 &#8217; &#x4e2d; &nbsp;x"),
            "Fish & chips <3 ’ 中 x"
        );
    }

    #[test]
    fn leaves_unknown_or_bare_ampersands() {
        assert_eq!(body_to_text("AT&T &bogus; a & b"), "AT&T &bogus; a & b");
    }

    #[test]
    fn truncates_with_ellipsis() {
        assert_eq!(truncate_chars("abcdef", 3), "abc…");
        assert_eq!(truncate_chars("abc", 3), "abc");
        assert_eq!(truncate_chars("汉字汉字", 2), "汉字…");
    }
}
