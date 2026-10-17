-- Version 3.

-- Recent source runs for the app's history and performance view. Times are Unix milliseconds.
-- Trimmed to the newest rows on every insert (see `source_state.rs`).
CREATE TABLE run_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  source_id   TEXT    NOT NULL,
  started_at  INTEGER NOT NULL,
  duration_ms INTEGER NOT NULL,
  fetched     INTEGER NOT NULL,
  too_old     INTEGER NOT NULL,
  new_items   INTEGER NOT NULL,
  error       TEXT
) STRICT;
CREATE INDEX run_log_source_started ON run_log (source_id, started_at);
