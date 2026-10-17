-- Version 7.

-- Posts to destinations (Discord, Telegram). Fed from the outbox through `meta.delivery_seq`;
-- the app reads this table for delivery status. Times are Unix milliseconds. `state` is
-- 'pending', 'sent' or 'failed'.
CREATE TABLE deliveries (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  destination_id  TEXT    NOT NULL,
  item_id         TEXT    NOT NULL,
  outbox_seq      INTEGER NOT NULL,
  state           TEXT    NOT NULL DEFAULT 'pending',
  attempts        INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL,
  last_error      TEXT,
  sent_at         INTEGER,
  created_at      INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  UNIQUE (destination_id, item_id)
) STRICT;
CREATE INDEX deliveries_due ON deliveries (state, next_attempt_at);
CREATE INDEX deliveries_sent ON deliveries (destination_id, sent_at);
CREATE INDEX outbox_item_id ON outbox (item_id);

-- Items already in the outbox were never meant to be posted.
INSERT INTO meta (key, value) VALUES ('delivery_seq', (SELECT CAST(COALESCE(MAX(seq), 0) AS TEXT) FROM outbox));
