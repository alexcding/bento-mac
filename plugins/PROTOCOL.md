# Bento plugin protocol

A protocol plugin is an executable that answers **one JSON-RPC 2.0 request per run**: the daemon
writes the request to its stdin and reads the response from its stdout. Use it when a source needs
code (signed APIs, HTML scraping, interactive login); for programs that already print JSON, a CLI
plugin with `mapping.json` needs no code.

```json
// plugin.json
"auth": { "kind": "interactive", "secrets": ["session"] },
"source": {
  "default_interval_minutes": 30,
  "protocol": { "executable": "my-plugin", "timeout_seconds": 60 }
}
```

The executable is looked up in the plugin's `bin/`, next to `bento-collector` (bundled plugins live in
`Bento.app/Contents/MacOS`), then on `PATH`.

## Methods

### `source/fetch`

```json
{"jsonrpc": "2.0", "id": 1, "method": "source/fetch",
 "params": {"query": "@channel", "settings": {"limit": 20}, "secrets": {"session": "…"}}}
```

Result: `{"items": [raw item, …]}`. A raw item has `external_id` (required), `url`, `title`, `text`,
`author {name, handle, avatar_url}`, `media [{type: image|video, url, thumbnail_url, duration,
embed_url, width, height}]`, `published_at` (RFC 3339), `language`, `body_markdown`, and
`reference {type: quote|repost, item}`.

### `auth/begin` and `auth/step`

```json
{"method": "auth/begin", "params": {"secrets": {}}}
{"method": "auth/step",  "params": {"state": "…", "input": "123456", "secrets": {}}}
```

Both return a step:

```json
{"status": "pending" | "done" | "failed",
 "state": "opaque, sent back with the next auth/step",
 "prompt": {"kind": "qr" | "text" | "password", "message": "Scan with the app", "qr": "text to encode"},
 "poll_after_ms": 2000,
 "save_secrets": {"session": "…"},
 "error": "shown when failed"}
```

For `qr` prompts the host polls `auth/step` after `poll_after_ms` without input; for `text` and
`password` it sends what the user typed as `input`. On `done` the host stores `save_secrets` in the
Keychain under the plugin's ID and passes them back in `params.secrets` on every call. Plugins never
read or write the Keychain themselves.

### `publish/send`

For plugins with the `publisher` capability (the Telegram plugin posts as the signed-in account):

```json
{"method": "publish/send",
 "params": {"chat": "me", "html": "<b>Title</b>\n\nText", "caption": "…", "image_url": null,
            "secrets": {"session": "…"}}}
```

`html` and `caption` are Telegram-style HTML, already cut to 4096 and 1024 visible characters. With
`image_url`, post a photo with `caption`; if the service refuses the image, post `html` alone.
Result: `{}`. A request that times out is never retried, so send at most once per run.

## Errors

Return a JSON-RPC error. Code **-32001** means the user must sign in again (an expired session); the
app then shows the plugin's Sign In button. **-32002** asks the host to wait `data.retry_after`
seconds (a flood wait). **-32003** means the request can never succeed (unknown chat, no
permission), so it is not retried. **-32004** means the outcome is unknown (the connection dropped
while sending), so it is not retried either. Any other code is shown as the source's error and retried.

## Testing

`bento-collector plugin auth <id>` runs a login in the terminal (`--json` prints one JSON line per step,
as the app uses it). Pipe a request to the executable to test a method directly:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"source/fetch","params":{"query":"@telegram"}}' | bento-plugin-telegram
```
