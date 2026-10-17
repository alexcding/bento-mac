//! `collector.sqlite`: the Rust daemon's own database. Never synced.
//!
//! The Mac app reads the `outbox` and `source_state` tables (see `migrations/`). Their column
//! layout and the JSON payload are a contract with `Packages/BentoData/Sources/BentoData/`
//! (`Outbox.swift`, `CollectorStatus.swift`).

mod ai_calls;
mod outbox;
mod plugins;
mod source_state;

use std::path::Path;
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

use rusqlite::{Connection, TransactionBehavior};
use thiserror::Error;

pub use outbox::OutboxRow;
pub use plugins::PluginCatalogEntry;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error("database schema version {found} is newer than this build supports ({supported})")]
    SchemaTooNew { found: i64, supported: i64 },
}

/// Ordered migrations. Index + 1 is the resulting `user_version`. Append only.
const MIGRATIONS: &[&str] = &[
    include_str!("migrations/001_outbox.sql"),
    include_str!("migrations/002_scheduling.sql"),
    include_str!("migrations/003_run_log.sql"),
    include_str!("migrations/004_plugins.sql"),
    include_str!("migrations/005_ai_calls.sql"),
    include_str!("migrations/006_last_success.sql"),
];

pub struct SqliteStore {
    connection: Mutex<Connection>,
}

impl SqliteStore {
    pub fn open(path: &Path) -> Result<Self, StoreError> {
        Self::with_connection(Connection::open(path)?, true)
    }

    pub fn open_in_memory() -> Result<Self, StoreError> {
        Self::with_connection(Connection::open_in_memory()?, false)
    }

    fn with_connection(mut connection: Connection, wal: bool) -> Result<Self, StoreError> {
        // Set first: every later statement, including the journal mode switch, may need to wait
        // for another process.
        connection.busy_timeout(Duration::from_secs(5))?;
        if wal {
            enable_wal(&connection)?;
        }
        connection.pragma_update(None, "foreign_keys", true)?;
        migrate(&mut connection)?;
        Ok(Self {
            connection: Mutex::new(connection),
        })
    }

    fn connection(&self) -> MutexGuard<'_, Connection> {
        // A panic while holding the lock cannot leave SQLite in a half-written state
        // (transactions roll back on drop), so a poisoned lock is safe to reuse.
        self.connection
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// Switching to WAL needs an exclusive lock, and SQLite skips the busy handler when two
/// connections race for it (waiting could deadlock), so retry here instead.
fn enable_wal(connection: &Connection) -> Result<(), StoreError> {
    const ATTEMPTS: u32 = 50;
    for attempt in 1..=ATTEMPTS {
        match connection.pragma_update(None, "journal_mode", "WAL") {
            Err(rusqlite::Error::SqliteFailure(error, _))
                if error.code == rusqlite::ErrorCode::DatabaseBusy && attempt < ATTEMPTS =>
            {
                std::thread::sleep(Duration::from_millis(100));
            }
            result => return Ok(result?),
        }
    }
    unreachable!("the last attempt always returns")
}

fn migrate(connection: &mut Connection) -> Result<(), StoreError> {
    let supported = i64::try_from(MIGRATIONS.len()).expect("migration count fits in i64");
    // IMMEDIATE takes the write lock before reading the version, so two processes opening a
    // fresh database at once cannot both run the same migration.
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let found: i64 = transaction.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if found > supported {
        return Err(StoreError::SchemaTooNew { found, supported });
    }
    for (version, sql) in (1_i64..)
        .zip(MIGRATIONS)
        .skip(usize::try_from(found).unwrap_or(0))
    {
        transaction.execute_batch(sql)?;
        transaction.pragma_update(None, "user_version", version)?;
    }
    transaction.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrates_fresh_database() {
        let store = SqliteStore::open_in_memory().unwrap();
        let version: i64 = store
            .connection()
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(version, 6);
    }

    #[test]
    fn creates_instance_id() {
        let store = SqliteStore::open_in_memory().unwrap();
        let id: String = store
            .connection()
            .query_row(
                "SELECT value FROM meta WHERE key = 'instance_id'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(id.len(), 32);
    }

    #[test]
    fn reopening_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("collector.sqlite");
        drop(SqliteStore::open(&path).unwrap());
        SqliteStore::open(&path).unwrap();
    }

    #[test]
    fn concurrent_opens_of_fresh_database_succeed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("collector.sqlite");
        let handles: Vec<_> = (0..8)
            .map(|_| {
                let path = path.clone();
                std::thread::spawn(move || SqliteStore::open(&path).map(drop))
            })
            .collect();
        for handle in handles {
            handle.join().unwrap().unwrap();
        }
    }

    /// Sources that ran before `last_success_at` existed keep counting as having succeeded.
    #[test]
    fn migration_6_backfills_last_success_from_history() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("collector.sqlite");
        let mut connection = Connection::open(&path).unwrap();
        let transaction = connection.transaction().unwrap();
        for sql in &MIGRATIONS[..5] {
            transaction.execute_batch(sql).unwrap();
        }
        transaction.pragma_update(None, "user_version", 5).unwrap();
        transaction
            .execute_batch(
                "INSERT INTO source_state (source_id, last_run_at, next_run_at, consecutive_failures)
                   VALUES ('ok', 300, 900, 0), ('failing-now', 400, 900, 2), ('never-ran-ok', 500, 900, 1);
                 INSERT INTO run_log (source_id, started_at, duration_ms, fetched, too_old, new_items, error)
                   VALUES ('failing-now', 200, 1, 1, 0, 1, NULL), ('failing-now', 400, 1, 0, 0, 0, 'timeout'),
                          ('never-ran-ok', 500, 1, 0, 0, 0, 'login');",
            )
            .unwrap();
        transaction.commit().unwrap();
        drop(connection);

        let store = SqliteStore::open(&path).unwrap();

        let success = |id: &str| -> Option<i64> {
            store
                .connection()
                .query_row(
                    "SELECT last_success_at FROM source_state WHERE source_id = ?1",
                    [id],
                    |r| r.get(0),
                )
                .unwrap()
        };
        assert_eq!(
            success("ok"),
            Some(300),
            "no history, last run did not fail"
        );
        assert_eq!(success("failing-now"), Some(200), "latest successful run");
        assert_eq!(success("never-ran-ok"), None, "still on its first run");
    }

    #[test]
    fn refuses_newer_schema() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("collector.sqlite");
        Connection::open(&path)
            .unwrap()
            .pragma_update(None, "user_version", 99)
            .unwrap();
        assert!(matches!(
            SqliteStore::open(&path),
            Err(StoreError::SchemaTooNew { found: 99, .. })
        ));
    }
}
