//! `collector.sqlite`: the Rust daemon's own database. Never synced.
//!
//! The Mac app reads the `outbox` table (see `schema.sql`) and saves its rows to the synced
//! database. The column layout and the JSON payload are a contract with
//! `Packages/BentoData/Sources/BentoData/Outbox.swift`.

mod outbox;

use std::path::Path;
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

use rusqlite::Connection;
use thiserror::Error;

pub use outbox::OutboxRow;

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
const MIGRATIONS: &[&str] = &[include_str!("schema.sql")];

pub struct SqliteStore {
    connection: Mutex<Connection>,
}

impl SqliteStore {
    pub fn open(path: &Path) -> Result<Self, StoreError> {
        let connection = Connection::open(path)?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        Self::with_connection(connection)
    }

    pub fn open_in_memory() -> Result<Self, StoreError> {
        Self::with_connection(Connection::open_in_memory()?)
    }

    fn with_connection(mut connection: Connection) -> Result<Self, StoreError> {
        connection.busy_timeout(Duration::from_secs(5))?;
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

fn migrate(connection: &mut Connection) -> Result<(), StoreError> {
    let supported = i64::try_from(MIGRATIONS.len()).expect("migration count fits in i64");
    let found: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if found > supported {
        return Err(StoreError::SchemaTooNew { found, supported });
    }
    let transaction = connection.transaction()?;
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
        assert_eq!(version, 1);
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
