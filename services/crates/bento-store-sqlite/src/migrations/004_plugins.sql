-- Version 4.

-- Plugins the daemon loaded (or failed to load), with their manifest and the install status of the
-- programs they need. Replaced as a whole on every check; the app reads it for Settings.
CREATE TABLE plugins (
  id           TEXT    PRIMARY KEY NOT NULL,
  name         TEXT    NOT NULL,
  version      TEXT    NOT NULL,
  directory    TEXT    NOT NULL,
  manifest     TEXT    NOT NULL, -- plugin.json as JSON; '{}' when it failed to load
  requirements TEXT    NOT NULL, -- JSON array of {name, installed, detail, install}
  error        TEXT,             -- why the plugin did not load
  updated_at   INTEGER NOT NULL
) STRICT;
