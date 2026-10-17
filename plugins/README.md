# Plugins

Each folder is one plugin. The daemon loads bundled plugins from the app (`Contents/Resources/plugins`) and user plugins from
`~/Library/Application Support/Bento/Plugins` (a user plugin with the same `id` replaces the bundled one).

| File | Purpose |
|---|---|
| `plugin.json` | Manifest: id, capabilities, required programs, secrets, and for sources the commands to run. Schema: `plugin.schema.json`. |
| `mapping.json` | How the command's output becomes items: RFC 9535 JSONPath expressions, each a single path or an ordered list of fallbacks. A value without a leading `$` is a template where `{$.path}` is substituted. |
| `settings.schema.json` | JSON Schema for the per-source settings the app shows (for example `limit`). |
| `fixtures/` | Sample command output, used by the tests and by `bento-collector plugin test <folder> <fixture>`. |
| `src/`, `Cargo.toml` | Code, for protocol plugins (see [PROTOCOL.md](PROTOCOL.md)). |

## Bundled plugins

| Plugin | Kind | Notes |
|---|---|---|
| `x` | CLI (`twitter-cli`) | timeline, `@user`, post links, search; posts as you; cookies in Settings |
| `reddit` | CLI (`rdt-cli`) | popular, all, `r/sub`, threads, search |
| `youtube` | CLI (`yt-dlp`) | channel, playlist or video URLs, search |
| `xiaohongshu` | CLI (`xhs`) | trending, search |
| `bilibili` | protocol | following feed; sign in with a QR code |
| `telegram` | protocol | public channels via `t.me/s` with no login; after signing in with your account, private channels (`t.me/c/<id>`) and posting as you |

## Source commands

`source.cli.commands` is tried in order; the first whose `match` regex matches the trimmed query runs.
Arguments may use `{query}`, `{limit}` and the regex's named groups, optionally `{name|urldecode}`.
`env` values may use `{secret.<key>}` for secrets declared under `auth`; the user enters them in Settings
and they are stored in the Keychain. A secret that is not set leaves its variable out.

`output` is `json` (one document, falling back to JSON Lines), `json-lines`, or `text-lines` (each line
with a URL becomes `{"text", "url"}`).

## Posting commands

A CLI plugin with the `publisher` capability posts as the user through `publish.cli`: `args` may use
`{text}` (the post, cut to fit `text`: `max_chars`, with links counting `url_chars` and wide characters
such as CJK counting `wide_char_weight`), and `image_args` with `{image}` (a downloaded local file) are
added before a `--` argument. The command's error output decides what happens: a rate limit waits, an
expired login or invalid post is not retried, "duplicate" counts as already posted, and a timeout is
never retried.

## Status

The X, Reddit and Xiaohongshu mappings follow the field names these CLIs have used, with fallbacks; they
have not yet been checked against live output. Run `bento-collector plugin test` with real output to
verify, and adjust `mapping.json` if a field is missing.
