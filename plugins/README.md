# Plugins

Each folder is one plugin. The daemon loads bundled plugins from the app (`Contents/Resources/plugins`) and user plugins from
`~/Library/Application Support/Bento/Plugins` (a user plugin with the same `id` replaces the bundled one).

| File | Purpose |
|---|---|
| `plugin.json` | Manifest: id, capabilities, required programs, secrets, and for sources the commands to run. Schema: `plugin.schema.json`. |
| `mapping.json` | How the command's output becomes items: RFC 9535 JSONPath expressions, each a single path or an ordered list of fallbacks. A value without a leading `$` is a template where `{$.path}` is substituted. |
| `settings.schema.json` | JSON Schema for the per-source settings the app shows (for example `limit`). |
| `fixtures/` | Sample command output, used by the tests and by `bento-collector plugin test <folder> <fixture>`. |

## Source commands

`source.cli.commands` is tried in order; the first whose `match` regex matches the trimmed query runs.
Arguments may use `{query}`, `{limit}` and the regex's named groups, optionally `{name|urldecode}`.
`env` values may use `{secret.<key>}` for secrets declared under `auth`; the user enters them in Settings
and they are stored in the Keychain. A secret that is not set leaves its variable out.

`output` is `json` (one document, falling back to JSON Lines), `json-lines`, or `text-lines` (each line
with a URL becomes `{"text", "url"}`).

## Status

The X, Reddit and Xiaohongshu mappings follow the field names these CLIs have used, with fallbacks; they
have not yet been checked against live output. Run `bento-collector plugin test` with real output to
verify, and adjust `mapping.json` if a field is missing.
