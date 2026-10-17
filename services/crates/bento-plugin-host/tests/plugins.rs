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
    assert_eq!(
        ids,
        [
            "bilibili",
            "reddit",
            "telegram",
            "x",
            "xiaohongshu",
            "youtube"
        ]
    );
    assert_eq!(registry.fetchers().len(), 6);
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
        ["twitter", "search", "-n", "20", "--json", "--", "rust lang"]
    );
    assert_eq!(argv(&r, "x", "https://x.com/home")[1], "feed");
    assert_eq!(
        argv(&r, "x", "rust release"),
        [
            "twitter",
            "search",
            "-n",
            "20",
            "--json",
            "--",
            "rust release"
        ]
    );
    assert_eq!(
        argv(&r, "x", "-filter:replies rust").last().unwrap(),
        "-filter:replies rust",
        "a leading dash is still the query, after `--`"
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
    assert_eq!(
        items.len(),
        2,
        "a quoted post is the item's reference, not a separate item"
    );

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

/// A single post wrapped in `data` (the single-post route) is that post, with its quote as a
/// reference; nested objects never become items of their own.
#[test]
fn x_single_post_envelope_keeps_the_main_post() {
    let r = registry();
    let items = r
        .plugin("x")
        .unwrap()
        .fetcher
        .as_ref()
        .unwrap()
        .map_output(&fixture("x", "single.json"));

    assert_eq!(items.len(), 1);
    assert_eq!(items[0].external_id, "100");
    assert_eq!(items[0].reference.as_ref().unwrap().item.external_id, "50");
}

#[test]
fn reddit_crosspost_is_one_item() {
    let r = registry();
    let items = r
        .plugin("reddit")
        .unwrap()
        .fetcher
        .as_ref()
        .unwrap()
        .map_output(&fixture("reddit", "crosspost.json"));

    assert_eq!(
        items
            .iter()
            .map(|i| i.external_id.as_str())
            .collect::<Vec<_>>(),
        ["p1"]
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
        )[6],
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
fn reserved_ids_are_refused() {
    let dir = tempfile::tempdir().unwrap();
    let rss = dir.path().join("myrss");
    std::fs::create_dir(&rss).unwrap();
    std::fs::write(
        rss.join("plugin.json"),
        r#"{"id":"rss","name":"R","version":"1","protocol":1,"capabilities":[]}"#,
    )
    .unwrap();
    let secrets: Arc<dyn SecretStore> = Arc::new(Secrets(vec![]));

    let registry = PluginRegistry::load(&[dir.path().to_owned()], &secrets);

    assert!(registry.plugins.is_empty());
    assert!(registry.errors[0].message.contains("reserved"));
}

/// Writes a one-command source plugin into a temporary directory and returns its fetcher input.
fn shell_plugin(
    id: &str,
    script: &str,
    cli_extra: &serde_json::Value,
) -> (tempfile::TempDir, PluginRegistry, SourceConfig) {
    let dir = tempfile::tempdir().unwrap();
    let plugin = dir.path().join(id);
    std::fs::create_dir(&plugin).unwrap();
    let mut cli = serde_json::json!({
        "commands": [{"match": "^.*$", "args": ["/bin/sh", "-c", script]}],
        "output": "json-lines"
    });
    cli.as_object_mut()
        .unwrap()
        .extend(cli_extra.as_object().unwrap().clone());
    let manifest = serde_json::json!({
        "id": id, "name": id, "version": "1", "protocol": 1, "capabilities": ["source"],
        "source": {"default_interval_minutes": 5, "cli": cli}
    });
    std::fs::write(plugin.join("plugin.json"), manifest.to_string()).unwrap();
    std::fs::write(
        plugin.join("mapping.json"),
        r#"{"external_id":"$.id","url":"$.url"}"#,
    )
    .unwrap();
    let secrets: Arc<dyn SecretStore> = Arc::new(Secrets(vec![]));
    let registry = PluginRegistry::load(&[dir.path().to_owned()], &secrets);
    assert!(registry.errors.is_empty(), "{:?}", registry.errors);
    let source: SourceConfig = serde_json::from_value(serde_json::json!({
        "id": uuid::Uuid::from_u128(1), "plugin_id": id, "name": id, "query": "",
        "interval_minutes": 5, "enabled": true
    }))
    .unwrap();
    (dir, registry, source)
}

/// A command that prints more than the output limit is killed; its output is kept only when the
/// plugin allows partial output, and either way the fetch stops at the limit, not the timeout.
#[tokio::test]
async fn oversized_output_is_cut_not_timed_out() {
    let script = r#"echo '{"id":"1","url":"https://e.com/1"}'; exec yes '{"pad":1}'"#;
    for (partial, expect_items) in [(true, true), (false, false)] {
        let (_dir, registry, source) = shell_plugin(
            "big",
            script,
            &serde_json::json!({"timeout_seconds": 30, "partial_output_ok": partial}),
        );
        let started = std::time::Instant::now();

        let result = registry.fetchers()["big"].fetch(&source).await;

        assert!(
            started.elapsed() < std::time::Duration::from_secs(15),
            "stopped at the limit"
        );
        if expect_items {
            assert_eq!(result.unwrap().len(), 1);
        } else {
            assert!(result.unwrap_err().to_string().contains("more than"));
        }
    }
}

/// On timeout, a plugin that allows partial output keeps what was printed.
#[tokio::test]
async fn timeout_keeps_partial_output_when_allowed() {
    let (_dir, registry, source) = shell_plugin(
        "slow",
        r#"echo '{"id":"1","url":"https://e.com/1"}'; exec sleep 30"#,
        &serde_json::json!({"timeout_seconds": 1, "partial_output_ok": true}),
    );

    let items = registry.fetchers()["slow"].fetch(&source).await.unwrap();

    assert_eq!(items.len(), 1);
}

/// Without partial output allowed, a timeout is an error.
#[tokio::test]
async fn timeout_fails_without_partial_output() {
    let (_dir, registry, source) = shell_plugin(
        "slow",
        r#"echo '{"id":"1","url":"https://e.com/1"}'; exec sleep 30"#,
        &serde_json::json!({"timeout_seconds": 1}),
    );

    let error = registry.fetchers()["slow"]
        .fetch(&source)
        .await
        .unwrap_err();

    assert!(error.to_string().contains("timed out"), "{error}");
}

/// A child that floods stderr does not block: stderr is drained even past the kept size.
#[tokio::test]
async fn noisy_stderr_does_not_block() {
    let (_dir, registry, source) = shell_plugin(
        "noisy",
        r#"head -c 2000000 /dev/zero | tr '\0' 'x' >&2; echo '{"id":"1","url":"https://e.com/1"}'"#,
        &serde_json::json!({"timeout_seconds": 10}),
    );

    let items = registry.fetchers()["noisy"].fetch(&source).await.unwrap();

    assert_eq!(items.len(), 1);
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

/// Writes a protocol plugin whose executable is a shell script answering every request with
/// `response` (after checking the request contains `expect`).
fn protocol_plugin(expect: &str, response: &str) -> (tempfile::TempDir, PluginRegistry) {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let plugin = dir.path().join("proto");
    std::fs::create_dir_all(plugin.join("bin")).unwrap();
    let script = plugin.join("bin/proto-plugin");
    std::fs::write(
        &script,
        format!("#!/bin/sh\nrequest=$(cat)\ncase \"$request\" in *'{expect}'*) echo '{response}' ;; *) echo '{{\"error\":{{\"code\":-32600,\"message\":\"unexpected\"}}}}' ;; esac\n"),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let manifest = serde_json::json!({
        "id": "proto", "name": "Proto", "version": "1", "protocol": 1, "capabilities": ["source", "auth"],
        "auth": {"kind": "interactive", "secrets": ["session"]},
        "source": {"default_interval_minutes": 5, "protocol": {"executable": "proto-plugin", "timeout_seconds": 10}}
    });
    std::fs::write(plugin.join("plugin.json"), manifest.to_string()).unwrap();
    let secrets: Arc<dyn SecretStore> = Arc::new(Secrets(vec![("proto", "session", "abc")]));
    let registry = PluginRegistry::load(&[dir.path().to_owned()], &secrets);
    assert!(registry.errors.is_empty(), "{:?}", registry.errors);
    (dir, registry)
}

fn proto_source() -> SourceConfig {
    serde_json::from_value(serde_json::json!({
        "id": uuid::Uuid::from_u128(1), "plugin_id": "proto", "name": "p", "query": "q",
        "interval_minutes": 5, "enabled": true
    }))
    .unwrap()
}

#[tokio::test]
async fn protocol_fetch_passes_secrets_and_returns_items() {
    let (_dir, registry) = protocol_plugin(
        r#""secrets":{"session":"abc"}"#,
        r#"{"jsonrpc":"2.0","id":1,"result":{"items":[{"external_id":"1","url":"https://e.com/1","text":"hi"}]}}"#,
    );

    let items = registry.fetchers()["proto"]
        .fetch(&proto_source())
        .await
        .unwrap();

    assert_eq!(items[0].text, "hi");
}

#[tokio::test]
async fn protocol_auth_required_becomes_a_clear_error() {
    let (_dir, registry) = protocol_plugin(
        "source/fetch",
        r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"log in"}}"#,
    );

    let error = registry.fetchers()["proto"]
        .fetch(&proto_source())
        .await
        .unwrap_err();

    assert!(error.to_string().contains("sign in"), "{error}");
}

#[tokio::test]
async fn protocol_auth_steps_round_trip() {
    let (_dir, registry) = protocol_plugin(
        "auth/begin",
        r#"{"jsonrpc":"2.0","id":1,"result":{"status":"pending","state":"s1","prompt":{"kind":"qr","message":"Scan","qr":"https://q"},"poll_after_ms":2000}}"#,
    );
    let plugin = registry.plugin("proto").unwrap().protocol.clone().unwrap();

    let step = plugin.auth_begin().await.unwrap();

    assert_eq!(
        step.status,
        bento_plugin_host::protocol::AuthStatus::Pending
    );
    assert_eq!(step.prompt.unwrap().qr.as_deref(), Some("https://q"));
}

#[tokio::test]
async fn protocol_oversized_response_fails_fast() {
    let (_dir, registry) = protocol_plugin("source/fetch", "x");
    let plugin = registry.plugin("proto").unwrap();
    let script = plugin.directory.join("bin/proto-plugin");
    std::fs::write(
        &script,
        "#!/bin/sh\ncat >/dev/null\nexec yes '{\"pad\":1}'\n",
    )
    .unwrap();
    let started = std::time::Instant::now();

    let error = registry.fetchers()["proto"]
        .fetch(&proto_source())
        .await
        .unwrap_err();

    assert!(error.to_string().contains("larger than"), "{error}");
    assert!(
        started.elapsed() < std::time::Duration::from_secs(8),
        "not the 10 s timeout"
    );
}

#[tokio::test]
async fn protocol_publish_sends_the_post_and_reports_flood_waits() {
    let (_dir, registry) = protocol_plugin(
        r#""method":"publish/send","params":{"caption":"c","chat":"me","html":"<b>h</b>","image_url":null,"secrets":{"session":"abc"}}"#,
        r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"wait","data":{"retry_after":42}}}"#,
    );
    let plugin = registry.plugin("proto").unwrap().protocol.clone().unwrap();

    let error = plugin
        .publish("me", "<b>h</b>", "c", None)
        .await
        .unwrap_err();

    assert!(
        matches!(
            error,
            bento_plugin_host::protocol::ProtocolError::RateLimited(42)
        ),
        "{error}"
    );
}
