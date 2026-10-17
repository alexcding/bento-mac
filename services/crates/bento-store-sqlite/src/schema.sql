-- Version 1.

-- Processed items waiting for the Mac app. `seq` only grows; the app remembers the last `seq`
-- it saved. `payload` is a JSON `bento_domain::FeedItem`; `detail` is a compressed
-- `bento_domain::detail` blob.
CREATE TABLE outbox (
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id    TEXT    NOT NULL,
  payload    TEXT    NOT NULL,
  detail     BLOB,
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER))
) STRICT;
