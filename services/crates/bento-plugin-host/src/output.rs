//! Turns a command's stdout into JSON documents for the mapping.

use serde_json::{Value, json};

use crate::manifest::OutputFormat;

#[must_use]
pub fn documents(stdout: &str, format: OutputFormat) -> Vec<Value> {
    match format {
        OutputFormat::Json => {
            serde_json::from_str(stdout).map_or_else(|_| json_lines(stdout), |v| vec![v])
        }
        OutputFormat::JsonLines => json_lines(stdout),
        OutputFormat::TextLines => vec![Value::Array(text_lines(stdout))],
    }
}

fn json_lines(stdout: &str) -> Vec<Value> {
    stdout
        .lines()
        .map(str::trim)
        .filter(|line| line.starts_with(['{', '[']))
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}

/// Each line with an http(s) URL becomes `{"text", "url"}`; the first URL per line counts.
fn text_lines(stdout: &str) -> Vec<Value> {
    stdout
        .lines()
        .filter_map(|line| {
            let start = line.find("https://").or_else(|| line.find("http://"))?;
            let end = line[start..]
                .find(char::is_whitespace)
                .map_or(line.len(), |n| start + n);
            let url = line[start..end].trim_end_matches(['.', ',', ')', ']']);
            let text = format!("{} {}", &line[..start], &line[end..]);
            let text = text
                .trim()
                .trim_matches(|c: char| "-:| ".contains(c))
                .trim();
            Some(json!({"text": text, "url": url}))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_falls_back_to_lines() {
        assert_eq!(
            documents(r#"{"a":1}"#, OutputFormat::Json),
            vec![json!({"a": 1})]
        );
        assert_eq!(
            documents("log line\n{\"a\":1}\n{\"a\":2}\n", OutputFormat::Json),
            vec![json!({"a": 1}), json!({"a": 2})]
        );
    }

    #[test]
    fn text_lines_extract_url_and_text() {
        let docs = documents(
            "Hot posts\n1. Great noodles - https://www.xiaohongshu.com/explore/abc.\nno url here\n",
            OutputFormat::TextLines,
        );
        assert_eq!(
            docs,
            vec![
                json!([{"text": "1. Great noodles", "url": "https://www.xiaohongshu.com/explore/abc"}])
            ]
        );
    }
}
