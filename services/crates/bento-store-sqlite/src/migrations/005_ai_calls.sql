-- Version 5.

-- Recent AI calls for the app's usage and latency view. Times are Unix milliseconds. Trimmed to the
-- newest rows on every insert (see `ai_calls.rs`).
CREATE TABLE ai_calls (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at  INTEGER NOT NULL,
  profile_id  TEXT    NOT NULL,
  task_id     TEXT    NOT NULL,
  duration_ms INTEGER NOT NULL,
  items       INTEGER NOT NULL,
  input_chars INTEGER NOT NULL,
  error       TEXT
) STRICT;
CREATE INDEX ai_calls_profile_started ON ai_calls (profile_id, started_at);
