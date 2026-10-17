//! Checks the bundled plugins in `plugins/`: they load, route queries to the right commands, and
//! map their fixtures.

use std::path::PathBuf;
use std::sync::Arc;

use bento_app::{PortError, SecretStore};
use bento_domain::{MediaKind, ReferenceKind, SourceConfig};
use bento_plugin_host::PluginRegistry;
use chrono::{TimeZone, Utc};

struct Secrets(Vec<(&'static str, &'static str, &'static str)>);

impl SecretStore for Secrets {
    fn secret(&self, plugin: &str, key: &str) -> Result<Option<String>, PortError> {
        Ok(self
            .0
            .iter()
            .find(|(p, k, _)| *p == plugin && *k == key)
            .map(|(_, _, v)| (*v).to_owned()))
    }
}

fn plugins_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../plugins")
}

fn registry() -> PluginRegistry {
    let secrets: Arc<dyn SecretStore> = Arc::new(Secrets(vec![]));
    PluginRegistry::load(&[plugins_dir()], &secrets)
}

fn fixture(plugin: &str, name: &str) -> String {
    std::fs::read_to_string(plugins_dir().join(plugin).join("fixtures").join(name)).unwrap()
}

fn argv(registry: &PluginRegistry, plugin: &str, query: &str) -> Vec<String> {
    registry
        .plugin(plugin)
        .unwrap()
        .fetcher
        .as_ref()
        .unwrap()
        .command_for(query, 20)
        .unwrap()
}

#[test]
fn every_bundled_plugin_loads() {
    let registry = registry();
    assert!(registry.errors.is_empty(), "{:?}", registry.errors);
    let mut ids: Vec<_> = registry
        .plugins
        .iter()
        .map(|p| p.manifest.id.as_str())
        .collect();
    ids.sort_unstable();
    assert_eq!(ids, ["reddit", "x", "xiaohongshu", "youtube"]);
    assert_eq!(registry.fetchers().len(), 4);
}

#[test]
fn x_routes_queries() {
    let r = registry();
    assert_eq!(argv(&r, "x", ""), ["twitter", "feed", "-n", "20", "--json"]);
    assert_eq!(
        argv(&r, "x", "@rustlang"),
        ["twitter", "user-posts", "rustlang", "-n", "20", "--json"]
    );
    assert_eq!(
        argv(&r, "x", "https://x.com/rustlang"),
        ["twitter", "user-posts", "rustlang", "-n", "20", "--json"]
    );
    assert_eq!(argv(&r, "x", "twitter.com/rustlang/status/123")[1], "tweet");
    assert_eq!(
        argv(&r, "x", "https://x.com/search?q=rust%20lang&src=typed"),
        ["twitter", "search", "rust lang", "-n", "20", "--json"]
    );
    assert_eq!(argv(&r, "x", "https://x.com/home")[1], "feed");
    assert_eq!(
        argv(&r, "x", "rust release"),
        ["twitter", "search", "rust release", "-n", "20", "--json"]
    );
}

#[test]
fn x_maps_posts_media_and_quotes() {
    let r = registry();
    let items = r
        .plugin("x")
        .unwrap()
        .fetcher
        .as_ref()
        .unwrap()
        .map_output(&fixture("x", "feed.json"));

    let first = items
        .iter()
        .find(|i| i.external_id == "1834567890123456789")
        .unwrap();
    assert_eq!(
        first.url.as_deref(),
        Some("https://x.com/rustlang/status/1834567890123456789")
    );
    assert_eq!(first.text, "Rust 2.0 & beyond <3");
    assert_eq!(
        first.author.as_ref().unwrap().handle.as_deref(),
        Some("rustlang")
    );
    assert_eq!(
        first.published_at,
        Some(Utc.with_ymd_and_hms(2026, 10, 14, 20, 19, 24).unwrap())
    );
    assert_eq!(first.media[0].url, "https://pbs.twimg.com/m1.jpg");
    let quote = first.reference.as_ref().unwrap();
    assert_eq!(
        (quote.kind, quote.item.external_id.as_str()),
        (ReferenceKind::Quote, "1834567890000000000")
    );

    let second = items
        .iter()
        .find(|i| i.external_id == "1834567890123456790")
        .unwrap();
    assert_eq!(
        second.url.as_deref(),
        Some("https://x.com/bob/status/1834567890123456790")
    );
}

#[test]
fn youtube_routes_and_maps() {
    let r = registry();
    let fetcher = r.plugin("youtube").unwrap().fetcher.clone().unwrap();
    assert_eq!(
        fetcher
            .command_for("rust talks", 5)
            .unwrap()
            .last()
            .unwrap(),
        "ytsearch5:rust talks"
    );
    assert!(
        fetcher
            .command_for("https://www.youtube.com/@chan", 5)
            .unwrap()
            .contains(&"--playlist-end".to_owned())
    );

    let items = fetcher.map_output(&fixture("youtube", "channel.jsonl"));

    assert_eq!(items.len(), 2);
    assert_eq!(items[0].title.as_deref(), Some("A video"));
    assert_eq!(
        items[0].published_at,
        Some(Utc.with_ymd_and_hms(2026, 10, 15, 0, 0, 0).unwrap())
    );
    let video = &items[0].media[0];
    assert_eq!(
        (video.kind, video.duration),
        (MediaKind::Video, Some(212.0))
    );
    assert_eq!(
        video.embed_url.as_deref(),
        Some("https://www.youtube.com/embed/dQw4w9WgXcQ")
    );
    assert_eq!(
        items[1].url.as_deref(),
        Some("https://www.youtube.com/watch?v=abc123"),
        "URL from id"
    );
}

#[test]
fn reddit_routes_and_maps() {
    let r = registry();
    assert_eq!(argv(&r, "reddit", "")[1], "popular");
    assert_eq!(
        argv(&r, "reddit", "r/rust"),
        ["rdt", "sub", "rust", "--limit", "20", "--json"]
    );
    assert_eq!(
        argv(
            &r,
            "reddit",
            "https://www.reddit.com/r/rust/comments/1abcde/show/"
        ),
        ["rdt", "read", "1abcde", "--json"]
    );
    assert_eq!(
        argv(
            &r,
            "reddit",
            "https://reddit.com/r/rust/search?q=async+await"
        )[2],
        "async await"
    );

    let items = r
        .plugin("reddit")
        .unwrap()
        .fetcher
        .as_ref()
        .unwrap()
        .map_output(&fixture("reddit", "sub.json"));

    assert_eq!(items.len(), 2);
    assert_eq!(
        items[0].url.as_deref(),
        Some("https://www.reddit.com/r/rust/comments/1abcde/show/")
    );
    assert_eq!(items[0].text, "Body text");
    assert!(
        items[0].media.is_empty(),
        "thumbnail \"self\" is not an image"
    );
    assert_eq!(
        items[1].media[0].url,
        "https://b.thumbs.redditmedia.com/t.jpg"
    );
}

#[test]
fn xiaohongshu_maps_text_lines() {
    let r = registry();
    assert_eq!(argv(&r, "xiaohongshu", ""), ["xhs", "hot"]);

    let items = r
        .plugin("xiaohongshu")
        .unwrap()
        .fetcher
        .as_ref()
        .unwrap()
        .map_output(&fixture("xiaohongshu", "hot.txt"));

    assert_eq!(items.len(), 2);
    assert_eq!(items[0].text, "1. 成都美食推荐");
    assert_eq!(
        items[1].url.as_deref(),
        Some("https://www.xiaohongshu.com/explore/64a1b2c4")
    );
}

/// Runs a real process: a temporary plugin whose command prints its output only when the secret
/// reached it through the environment.
#[tokio::test]
async fn fetch_runs_the_command_with_secrets_in_its_environment() {
    let dir = tempfile::tempdir().unwrap();
    let plugin = dir.path().join("echo");
    std::fs::create_dir(&plugin).unwrap();
    let out = plugin.join("out.json");
    std::fs::write(&out, r#"[{"id":"1","url":"https://e.com/1","t":"hi"}]"#).unwrap();
    let manifest = serde_json::json!({
        "id": "echo", "name": "Echo", "version": "1", "protocol": 1, "capabilities": ["source"],
        "auth": {"kind": "secrets", "fields": [{"key": "token", "label": "Token"}]},
        "source": {"default_interval_minutes": 5, "cli": {
            "commands": [{"match": "^(?<q>.*)$",
                          "args": ["/bin/sh", "-c", format!("test \"$TOKEN\" = s3cret && cat '{}'", out.display())]}],
            "env": {"TOKEN": "{secret.token}"}, "output": "json"}}
    });
    std::fs::write(plugin.join("plugin.json"), manifest.to_string()).unwrap();
    std::fs::write(
        plugin.join("mapping.json"),
        r#"{"external_id":"$.id","url":"$.url","text":"$.t"}"#,
    )
    .unwrap();
    let secrets: Arc<dyn SecretStore> = Arc::new(Secrets(vec![("echo", "token", "s3cret")]));
    let registry = PluginRegistry::load(&[dir.path().to_owned()], &secrets);
    assert!(registry.errors.is_empty(), "{:?}", registry.errors);
    let source: SourceConfig = serde_json::from_value(serde_json::json!({
        "id": uuid::Uuid::from_u128(1), "plugin_id": "echo", "name": "e", "query": "",
        "interval_minutes": 5, "enabled": true
    }))
    .unwrap();

    let items = registry.fetchers()["echo"].fetch(&source).await.unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0].text, "hi");
}

#[test]
fn broken_plugins_are_reported_not_loaded() {
    let dir = tempfile::tempdir().unwrap();
    let bad = dir.path().join("bad");
    std::fs::create_dir(&bad).unwrap();
    std::fs::write(
        bad.join("plugin.json"),
        r#"{"id":"bad","name":"B","version":"1","protocol":9,"capabilities":[]}"#,
    )
    .unwrap();
    let secrets: Arc<dyn SecretStore> = Arc::new(Secrets(vec![]));

    let registry = PluginRegistry::load(&[dir.path().to_owned()], &secrets);

    assert!(registry.plugins.is_empty());
    assert!(registry.errors[0].message.contains("protocol 9"));
}
