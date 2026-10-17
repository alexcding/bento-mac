use bento_app::{PortError, RunRecord, SourceState, SourceStateStore};
use chrono::{DateTime, Utc};
use rusqlite::{OptionalExtension, params};
use uuid::Uuid;

use crate::{SqliteStore, StoreError};

impl SqliteStore {
    fn load_source_state(&self, source_id: Uuid) -> Result<Option<SourceState>, StoreError> {
        let connection = self.connection();
        let mut select = connection.prepare_cached(
            "SELECT last_run_at, next_run_at, consecutive_failures, last_error, last_new_items
             FROM source_state WHERE source_id = ?1",
        )?;
        let state = select
            .query_row([source_id.to_string()], |row| {
                Ok(SourceState {
                    source_id,
                    last_run_at: row.get::<_, Option<i64>>(0)?.map(from_millis),
                    next_run_at: from_millis(row.get(1)?),
                    consecutive_failures: row.get(2)?,
                    last_error: row.get(3)?,
                    last_new_items: usize::try_from(row.get::<_, i64>(4)?).unwrap_or(0),
                })
            })
            .optional()?;
        Ok(state)
    }

    fn store_source_state(&self, state: &SourceState) -> Result<(), StoreError> {
        self.connection()
            .prepare_cached(
                "INSERT INTO source_state
                   (source_id, last_run_at, next_run_at, consecutive_failures, last_error, last_new_items)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT (source_id) DO UPDATE SET
                   last_run_at = excluded.last_run_at,
                   next_run_at = excluded.next_run_at,
                   consecutive_failures = excluded.consecutive_failures,
                   last_error = excluded.last_error,
                   last_new_items = excluded.last_new_items",
            )?
            .execute(params![
                state.source_id.to_string(),
                state.last_run_at.map(|at| at.timestamp_millis()),
                state.next_run_at.timestamp_millis(),
                state.consecutive_failures,
                state.last_error,
                i64::try_from(state.last_new_items).unwrap_or(i64::MAX),
            ])?;
        Ok(())
    }
}

/// Rows kept in `run_log`.
const RUN_LOG_LIMIT: i64 = 2_000;

impl SqliteStore {
    fn insert_run(&self, run: &RunRecord) -> Result<(), StoreError> {
        let connection = self.connection();
        connection
            .prepare_cached(
                "INSERT INTO run_log
                   (source_id, started_at, duration_ms, fetched, too_old, new_items, error)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            )?
            .execute(params![
                run.source_id.to_string(),
                run.started_at.timestamp_millis(),
                i64::try_from(run.duration_ms).unwrap_or(i64::MAX),
                i64::try_from(run.fetched).unwrap_or(i64::MAX),
                i64::try_from(run.too_old).unwrap_or(i64::MAX),
                i64::try_from(run.new_items).unwrap_or(i64::MAX),
                run.error,
            ])?;
        connection
            .prepare_cached("DELETE FROM run_log WHERE id <= (SELECT MAX(id) FROM run_log) - ?1")?
            .execute([RUN_LOG_LIMIT])?;
        Ok(())
    }
}

fn from_millis(millis: i64) -> DateTime<Utc> {
    DateTime::from_timestamp_millis(millis).unwrap_or_default()
}

impl SourceStateStore for SqliteStore {
    fn source_state(&self, source_id: Uuid) -> Result<Option<SourceState>, PortError> {
        self.load_source_state(source_id).map_err(PortError::new)
    }

    fn save_source_state(&self, state: &SourceState) -> Result<(), PortError> {
        self.store_source_state(state).map_err(PortError::new)
    }

    fn record_run(&self, run: &RunRecord) -> Result<(), PortError> {
        self.insert_run(run).map_err(PortError::new)
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use super::*;

    fn state(failures: u32, error: Option<&str>) -> SourceState {
        SourceState {
            source_id: Uuid::from_u128(1),
            last_run_at: Some(Utc.with_ymd_and_hms(2026, 10, 16, 9, 0, 0).unwrap()),
            next_run_at: Utc.with_ymd_and_hms(2026, 10, 16, 9, 30, 0).unwrap(),
            consecutive_failures: failures,
            last_error: error.map(Into::into),
            last_new_items: 3,
        }
    }

    #[test]
    fn missing_state_is_none() {
        let store = SqliteStore::open_in_memory().unwrap();
        assert_eq!(store.source_state(Uuid::from_u128(1)).unwrap(), None);
    }

    #[test]
    fn saves_and_overwrites() {
        let store = SqliteStore::open_in_memory().unwrap();
        store.save_source_state(&state(2, Some("timeout"))).unwrap();
        store.save_source_state(&state(0, None)).unwrap();

        assert_eq!(
            store.source_state(Uuid::from_u128(1)).unwrap(),
            Some(state(0, None))
        );
    }

    #[test]
    fn records_runs_and_keeps_only_the_newest() {
        let store = SqliteStore::open_in_memory().unwrap();
        let run = |n: i64| RunRecord {
            source_id: Uuid::from_u128(1),
            started_at: DateTime::from_timestamp_millis(n).unwrap(),
            duration_ms: 120,
            fetched: 20,
            too_old: 1,
            new_items: 3,
            error: None,
        };
        for n in 0..(RUN_LOG_LIMIT + 5) {
            store.record_run(&run(n)).unwrap();
        }

        let (count, oldest): (i64, i64) = store
            .connection()
            .query_row("SELECT COUNT(*), MIN(started_at) FROM run_log", [], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })
            .unwrap();

        assert_eq!(count, RUN_LOG_LIMIT);
        assert_eq!(oldest, 5);
    }
}
