-- Version 2.

-- Every item ID ever appended to the outbox, so re-fetched items are not sent again even after
-- old outbox rows are pruned.
CREATE TABLE seen_items (
  item_id       TEXT    PRIMARY KEY NOT NULL,
  first_seen_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER))
) STRICT;

-- Scheduling state per source. Times are Unix milliseconds. The app reads this table to show
-- source status.
CREATE TABLE source_state (
  source_id            TEXT    PRIMARY KEY NOT NULL,
  last_run_at          INTEGER,
  next_run_at          INTEGER NOT NULL,
  consecutive_failures INTEGER NOT NULL DEFAULT 0,
  last_error           TEXT,
  last_new_items       INTEGER NOT NULL DEFAULT 0
) STRICT;
