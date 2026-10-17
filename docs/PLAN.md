# Bento — Plan

Bento is a native, open-source (MIT) Mac app that collects posts from social media and RSS 24/7,
translates and summarizes them with an AI CLI, forwards them to Discord and Telegram, and syncs the
results through iCloud. An iOS reader follows later. Notes are out of scope for now.

## Decisions

| Topic | Decision |
|---|---|
| Distribution | Open source, Developer ID–signed and notarized, GitHub Releases + Sparkle. Not on the Mac App Store. |
| Backend | Rust daemon (`bento-collector`). No Bun, no Python. |
| UI | Native SwiftUI, shared between macOS and iOS. No web UI. |
| Database | [sqlite-data](https://github.com/pointfreeco/sqlite-data) with CloudKit `SyncEngine` (needs macOS 14 / iOS 17). |
| Sync scope | One iCloud account, private database. No sharing for now. |
| AI | One reusable AI service; every task is a config (provider, model, prompt, output schema). Providers: CLI (Codex, Claude, any) and OpenAI-compatible HTTP (DeepSeek and others). |
| Sources | Plugins. Everything the previous service supported: RSS (built-in), X, Reddit, YouTube, Bilibili, Telegram, Xiaohongshu. |
| Publishers | Built into the daemon behind the plugin interface: Discord webhook, Telegram bot, Telegram account (`grammers`), X posting. |
| Retention | Feed items: forever (configurable). Article detail: 30 days, bookmarked items forever. Mac archive: forever, never synced. |
| Out of scope | Rates, IPTV, GitHub runner, DB browser. Notes come later, with a third-party native rich-text editor. |

## Architecture

```
 sources ──► bento-collector (Rust LaunchAgent, runs after Quit)
              collector.sqlite: outbox, seen_items, source_state, run_log
              collector.log                       ▲ collector-config.json
                │ outbox                          │ (written by the app)
                ▼                                 │
 Bento.app (macOS) ── CollectorService ───────────┘   start / stop / restart, sync every 5 s
   BentoCollectorClient (Mac only)
   BentoUI + BentoData ── bento.sqlite ◄── iCloud ──► BentoUI + BentoData (iOS, later)
```

- **Two processes, one writer per database.** The daemon owns `collector.sqlite`; only the app
  writes `bento.sqlite`, because sqlite-data's sync triggers live on the app's connection.
- **Daemon → app:** processed items go to the `outbox` with a growing `seq`. The app saves rows
  past its cursor (kept per collector database instance) and is idempotent because item IDs are
  deterministic. The daemon skips items already sent (`seen_items`) before any processing.
- **App → daemon:** the app writes `collector-config.json` from the synced channels and sources
  whenever they change; the daemon reloads it when its modification time changes and keeps the
  last good config, so collection continues while the app is closed.
- **Control:** the app registers the LaunchAgent with `SMAppService`, restarts it with
  `launchctl kickstart -k`, and reads `source_state`, `run_log` and `collector.log` for status,
  run history, performance and logs (Collector window). Quitting the app does not stop the daemon.
- **Shared vs Mac only:** `BentoData` and `BentoUI` build for macOS and iOS. `BentoCollectorClient`
  and the app target's collector service are Mac only; the iOS app never links them.
- Secrets (cookies, Telegram session, webhook URLs, bot token) live in the Keychain.

### SwiftUI layering (same as cascade-mac)

Each layer depends only on the ones below it.

| Layer | Folder | Rule |
|---|---|---|
| Coordinators | `Coordinators/` | Presentation and view model lifetime. `AppCoordinator` handles every `Action`. |
| Container | `Container/` | One `*FeatureFactory` protocol per feature with a `Native*` implementation. Tests substitute these. |
| Scenes | `Scenes/<Area>/` | `<Area>View` + `<Area>ViewModel`. View models are `@MainActor @Observable`, own their sqlite-data queries, and report through an `Action` enum and `onAction`. They never reach for a coordinator. |
| Components | `Components/` | Reusable views with no screen of their own (feed card). |
| Services | `Services/` | Protocols with `Native*` implementations (`LibraryStoring`, `SourceStatusProviding`). |

Reads are sqlite-data queries in view models; writes go through `LibraryStoring` so tests use a fake.

## Item model

### Raw item (plugin output)

```jsonc
{
  "external_id": "1834…",                 // required
  "url": "https://…",
  "title": null,                          // articles and videos; null for tweets
  "text": "post text or excerpt",
  "author": { "name": "…", "handle": "@…", "avatar_url": "https://…" },
  "media": [
    { "type": "image", "url": "…", "width": 1200, "height": 675 },
    { "type": "video", "url": "…", "thumbnail_url": "…", "duration": 312, "embed_url": "…" }
  ],
  "published_at": "2026-10-16T08:12:00Z", // null → fetch time, marked estimated
  "language": "en",
  "body_markdown": null,                  // full content when the platform provides it
  "reference": { "type": "quote", "item": { /* raw item */ } },  // quote tweet, retweet, Bilibili forward
  "extra": { }                            // platform-specific, never required by the UI
}
```

Fetch: request `{ source: { id, query, settings }, cursor, limit }` → response `{ items, cursor }`.

| Field | RSS | X | YouTube | Bilibili |
|---|---|---|---|---|
| `external_id` | entry id / guid, else link | tweet id | video id | dynamic id |
| `title` | ✓ | — | ✓ | video title, else — |
| `text` | summary / content excerpt | tweet text | description | dynamic text / video desc |
| `author` | feed / author | name, handle, avatar | channel | uploader name, face |
| `media` | enclosure | photos / video | thumbnail + video | cover / images |
| `published_at` | published, else updated | created_at | timestamp, else upload_date (estimated) | pub_ts |
| `reference` | — | quote / retweet | — | forward |

### Pipeline

1. ID = UUIDv5 of `source_id + external_id`: dedupe for free, on every device.
2. Filter: max age, incremental window, already stored.
3. Detail: `body_markdown`, else extract from `url` when the source has `fetchDetail` on
   (Readability port → Markdown, capped at 12,000 chars).
4. AI steps, configured per channel or source (see AI service): presets Translate and
   Summarize fill `translatedTitle`, `summary` and translated detail Markdown; custom steps map
   their outputs to item fields.
5. Write to outbox → app syncs → publishers deliver.

Run options carried over: dry run (process, do not store or publish), skip the initial backlog of a
new source, skip weekends.

### AI service

One service (`bento-ai` crate in the daemon) behind one port: prompt + output schema → JSON. Every
use is a task config, not code:

```jsonc
{ "id": "translate-zh", "name": "Translate to Chinese", "provider": "deepseek", "model": "deepseek-chat",
  "prompt": "Translate to Simplified Chinese…\n{{title}}\n{{text}}",
  "outputs": { "title": "translatedTitle", "text": "detailMarkdown" }, "max_input_chars": 6500 }
```

| Provider kind | Examples | Config |
|---|---|---|
| CLI | Codex (`codex exec --output-schema`), Claude (`claude -p --output-format json`), others | command template, model, timeout |
| HTTP | DeepSeek, any OpenAI-compatible endpoint | base URL, model, API key (Keychain) |

Shared by every task: timeout, batching, retry with reduced context, source-text fallback, a
10-minute pause after an auth failure, an ordered fallback list, and usage/latency in `run_log`.
Prompts use `{{title}}`, `{{text}}`, `{{detail}}`, `{{url}}`, `{{language}}`. Tasks and providers sync;
secrets stay in the Mac's Keychain.

### Synced tables (`bento.sqlite`)

Rules from sqlite-data: UUID primary keys (`NOT NULL ON CONFLICT REPLACE`), no `UNIQUE`
constraints, no `RESTRICT`/`NO ACTION` foreign keys, additive migrations only (new columns nullable
or defaulted), last-edit-wins per column, every `BLOB` column syncs as a `CKAsset`.

- `Channel`: name, enabled, maxItems, position.
- `Source`: plugin id, name, query, settings (JSON), interval, translate, summarize, fetchDetail, enabled.
- `ChannelSource`: channel ↔ source, position.
- `Destination`: channel, kind (discord, telegramBot, telegramAccount), display name, chat id,
  post delay, enabled. The secret itself is in the Keychain.
- `FeedItem`: sourceID, externalID, url, title, text, translatedTitle, summary, authorName,
  authorHandle, authorAvatarURL, media (JSON `[Media]`), referenceItemID, publishedAt,
  isPublishedAtEstimated, language, fetchedAt.
- `FeedItemDetail`: feedItemID (primary key), markdown (`BLOB`, deflate with a 1-byte format header).
- `Bookmark`: a full copy of the item (same ID, no foreign key), so bookmarks survive the item
  being purged or its source deleted; `createdAt`.
- `BookmarkDetail`: bookmarkID (primary key), markdown copied from the item's detail.
- `ReadState`: feedItemID, readAt. Same database, so unread counts and filters are plain joins.

Local only: `outboxCursors` in `bento.sqlite` (Mac); `collector.sqlite` (outbox, seen items,
source state, run log) owned by Rust; `archive.sqlite` (every item forever, FTS) arrives with
retention purging.

### App layout

Slack/Discord style, three columns. Sidebar: All items and Bookmarks (with counts) and channels
(name, source count, Enabled/Paused, unread badge; context menu Settings / Pause / Delete; "New
channel" row). Feed: cards grouped by day, search, Unread only, Mark all as read, per-item Mark as
read/unread, Bookmark, Share; keys j/k move, s bookmark, m read/unread, o open original. Detail: full
text, media, quoted item, article Markdown; opening marks read. Mac only: menu bar (collector status
and controls) and the Collector window (sources with performance, run history, live log).

### Card

| Part | Content |
|---|---|
| Header | avatar, author or source name, platform icon, relative time (`~` when estimated) |
| Title | `translatedTitle` ?? `title` ?? first line of `text` |
| Body | `summary` ?? `text` (3–4 lines) |
| Media | first image, 2×2 grid, or video thumbnail with play badge |
| Reference | inset card for the quoted/forwarded item |
| Detail | full text, all media, inline video via `embedURL`, detail Markdown, open original, bookmark |

## Plugins

Each plugin is a self-contained folder:

```
plugins/<id>/
  plugin.json            manifest (required)
  settings.schema.json   JSON Schema (2020-12) for the plugin's source settings
  mapping.json           CLI output → raw item, as RFC 9535 JSONPath expressions (CLI plugins)
  src/ + Cargo.toml      code, for protocol plugins
  bin/                   built executable, for protocol plugins
  README.md
```

- `plugin.json` declares id, name, version, protocol version, capabilities (`source`,
  `publisher`, `auth`), required external binaries with check and install commands, auth kind
  (secret fields, QR, phone code) and default fetch interval. Its own JSON Schema lives in
  `plugins/plugin.schema.json`, so manifests are validated in CI and at load.
- **CLI plugins** (YouTube via `yt-dlp`, X via `twitter-cli`): `plugin.json` maps each operation
  to a command template, and `mapping.json` maps the command's JSON output to raw-item fields.
  No code.
- **Protocol plugins** (Bilibili with QR login): an executable speaking JSON-RPC 2.0 over
  stdin/stdout, like LSP and MCP. Methods: `initialize`, `configure`, `auth/begin`, `auth/step`,
  `source/fetch`, `publisher/send`, `health`.
- **Built-in** (RSS, publishers): Rust code in the daemon behind the same port.
- The daemon enforces timeouts, concurrency, rate limits and backoff, passes only that plugin's
  Keychain secrets, validates output against the raw-item schema, and checks the protocol version.
- Settings forms and login flows in the app are generated from `settings.schema.json` and the
  auth declaration; required binaries appear on a Dependencies screen. External tools are never
  bundled.

Publishers take `FeedItem + detail + destination` and return `{ remote_message_id }` or an error
marked retryable or not. Delivery rules: per-destination post delay (20 s), 429
`Retry-After`, 5 attempts with 30 s → 900 s backoff, Telegram flood wait pauses all Telegram
destinations, rejected photo falls back to text, a timed-out send is never retried.

## Repo layout

```
Apps/        Bento.xcodeproj (macOS; iOS later), Local.xcconfig.template
             Bento/App, Bento/Scenes (Collector, MenuBar), Bento/Services/Collector
Packages/    BentoData (+ BentoCollectorClient, Mac only), BentoUI
services/    Cargo workspace (below)
plugins/     one folder per plugin
docs/        PLAN.md
```

The Rust workspace is ports and adapters:

| Crate | Layer | Depends on | Tested with |
|---|---|---|---|
| `bento-domain` | item model, stable IDs, detail codec; no I/O | — | unit tests |
| `bento-app` | use cases (ingest, scheduler) and the ports they need (outbox, clock, source fetchers, source state and run log) | domain | in-memory fakes |
| `bento-store-sqlite` | `collector.sqlite` adapter | app, domain | temporary databases |
| `bento-source-rss` | built-in RSS/Atom fetcher | app, domain | fixtures, mock HTTP server |
| `bento-plugin-host`, `bento-ai-cli`, `bento-publish-*` | adapters (phase 2+) | app, domain | fixtures, fake processes |
| `bento-collector` | binary: composition root, config reload, logging, runtime | all | unit tests, smoke runs |

`services/testdata/vectors.json` holds ID and codec vectors that both the Rust and Swift tests check.

Builds from source use `Local.xcconfig` (git-ignored) for team and iCloud container IDs, or run
with sync off.

## Phases

| # | Deliverable | Done when |
|---|---|---|
| 0 | Project, packages, Cargo workspace, daemon skeleton as LaunchAgent, news tables, iCloud sync | A row Rust writes to the outbox reaches a second device through the app; first-sync time measured with a year of synthetic items |
| 1 | RSS end to end: scheduler, task queue, built-in RSS, outbox → app; native reader (feed by day, filters, search, detail, bookmarks) | A subscribed RSS feed shows up on the Mac and on a second device; bookmarks sync |
| 2 | Plugin host + test kit; X, Reddit, YouTube, Bilibili, Telegram, Xiaohongshu; detail extraction; AI service with CLI and HTTP providers and configurable steps; run options; Mac settings screens | Every source runs unattended for a week with no duplicates or crashes |
| 3 | Discord, Telegram bot, Telegram account (`grammers`), X posting | A week with no duplicate or missed sends |
| Later | iOS reader, read-only local JSON API, notes | — |

## Open items

- Measure real volume in phase 2 (current estimate: ~500 items/day → ~270 MB/year of slim items).
- Confirm CloudKit works for the Developer ID build in phase 0.
