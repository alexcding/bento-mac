-- Version 6.

-- When a source last ran successfully; NULL until its first success. A source that has never
-- succeeded is still on its first run (for skipping its backlog).
ALTER TABLE source_state ADD COLUMN last_success_at INTEGER;

-- Sources that already ran before this column existed: their latest successful run, else their
-- last run when it did not fail. Without this they would look new and skip real new posts.
UPDATE source_state SET last_success_at = coalesce(
  (SELECT max(started_at) FROM run_log
     WHERE run_log.source_id = source_state.source_id AND run_log.error IS NULL),
  CASE WHEN consecutive_failures = 0 THEN last_run_at END
);
