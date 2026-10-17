-- Version 6.

-- When a source last ran successfully; NULL until its first success. A source that has never
-- succeeded is still on its first run (for skipping its backlog).
ALTER TABLE source_state ADD COLUMN last_success_at INTEGER;
