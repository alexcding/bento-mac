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
| AI | CLI only (Codex first). No HTTP providers. |
| Sources | Plugins. First set: RSS (built-in), YouTube, X, Bilibili. |
| Publishers | Built into the daemon behind the plugin interface: Discord webhook, Telegram bot, Telegram account (`grammers`). |
| Retention | Feed items: forever (configurable). Article detail: 30 days, bookmarked items forever. Mac archive: forever, never synced. |
| Out of scope | X auto-posting, rates, IPTV, GitHub runner, DB browser, notes (later, with a third-party native rich-text editor). |

## Architecture

```
               ┌──────────────── Bento.app (Swift, macOS) ────────────────┐
 sources ──►  bento-collector (Rust, LaunchAgent)       BentoUI (SwiftUI)  │
 (plugins)     collector.sqlite: tasks, runs,            BentoData         │
               outbox, deliveries, logs     ── socket ─► (sqlite-data)     │
                 │                                        bento.sqlite ◄──►│── iCloud ──► iOS (later)
                 └──► Discord / Telegram                  archive.sqlite   │
               └───────────────────────────────────────────────────────────┘
```

- **Only the Swift app writes `bento.sqlite`.** sqlite-data's sync triggers live on the app's
  connection, so writes from another process would not sync.
- Rust writes processed items to an `outbox` table with a sequence number. The app reads past its
  cursor, upserts into `bento.sqlite` and `archive.sqlite`, and acks. Upserts are idempotent
  because item IDs are deterministic.
- Config (channels, sources, destinations) is edited in the app, stored in `bento.sqlite`, and
  pushed to the daemon, which caches it so collection continues while the app is closed.
- Control API (run, dry run, status, live logs) over a Unix socket.
- Secrets (cookies, Telegram session, webhook URLs, bot token) live in the Keychain.

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
4. AI via CLI: `translatedTitle`, `summary`, translated detail Markdown. Batching, retry ladder,
   source-text fallback and a 10-minute pause after an auth failure.
5. Write to outbox → app syncs → publishers deliver.

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
- `Bookmark`: feedItemID, createdAt.
- `ReadState`: feedItemID, readAt.

Local only: `archive.sqlite` (every item and detail forever, plain-text FTS index) on the Mac;
`collector.sqlite` (tasks, schedules, outbox, deliveries, logs) owned by Rust.

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

A plugin is a folder with `plugin.toml` and optionally an executable, run by the daemon as a child
process with JSON over stdin/stdout.

- **Manifest-only**: map operations to CLI commands and JSON paths to raw-item fields
  (YouTube via `yt-dlp`, X via `twitter-cli`).
- **Protocol**: an executable implementing `describe`, `configure`, `auth.begin`/`auth.step`,
  `fetch`, `publish`, `health` (Bilibili with QR login).
- **Built-in**: Rust code in the daemon with the same contract (RSS, publishers).
- The daemon enforces timeouts, concurrency, rate limits and backoff, passes only that plugin's
  Keychain secrets, validates output, and checks the protocol version.
- Settings forms and login flows in the app are generated from the manifest; required binaries
  appear on a Dependencies screen. External tools are never bundled.
- First-party CLI-wrapping plugins live in a separate `bento-plugins` repo.

Publishers take `FeedItem + detail + destination` and return `{ remote_message_id }` or an error
marked retryable or not. Delivery rules: per-destination post delay (20 s), 429
`Retry-After`, 5 attempts with 30 s → 900 s backoff, Telegram flood wait pauses all Telegram
destinations, rejected photo falls back to text, a timed-out send is never retried.

## Repo layout

```
Apps/        Bento.xcodeproj (macOS; iOS later), Local.xcconfig.template
Packages/    BentoData, BentoUI
services/    Cargo workspace: collector-core, plugins, publishers, bento-collector
docs/        PLAN.md
```

Builds from source use `Local.xcconfig` (git-ignored) for team and iCloud container IDs, or run
with sync off.

## Phases

| # | Deliverable | Done when |
|---|---|---|
| 0 | Project, packages, Cargo workspace, daemon skeleton as LaunchAgent, news tables, iCloud sync | A row Rust writes to the outbox reaches a second device through the app; first-sync time measured with a year of synthetic items |
| 1 | RSS end to end: scheduler, task queue, built-in RSS, outbox → app; native reader (feed by day, filters, search, detail, bookmarks) | A subscribed RSS feed shows up on the Mac and on a second device; bookmarks sync |
| 2 | Plugin host + test kit; YouTube, X, Bilibili; detail extraction; Codex CLI translation and summary; Mac settings screens | All four sources run unattended for a week with no duplicates or crashes |
| 3 | Discord, Telegram bot, Telegram account (`grammers`) | A week with no duplicate or missed sends |
| Later | iOS reader, read-only local JSON API, notes, Reddit / Xiaohongshu / Telegram sources | — |

## Open items

- Measure real volume in phase 2 (current estimate: ~500 items/day → ~270 MB/year of slim items).
- Confirm CloudKit works for the Developer ID build in phase 0.
