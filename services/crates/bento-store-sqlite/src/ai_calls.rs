use bento_app::{AiCall, AiCallRecorder, PortError};
use rusqlite::params;

use crate::{SqliteStore, StoreError};

/// Rows kept in `ai_calls`.
const AI_CALL_LIMIT: i64 = 5_000;

impl SqliteStore {
    fn insert_ai_call(&self, call: &AiCall) -> Result<(), StoreError> {
        let connection = self.connection();
        connection
            .prepare_cached(
                "INSERT INTO ai_calls (started_at, profile_id, task_id, duration_ms, items, input_chars, error)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            )?
            .execute(params![
                call.started_at.timestamp_millis(),
                call.profile_id,
                call.task_id,
                i64::try_from(call.duration_ms).unwrap_or(i64::MAX),
                i64::try_from(call.items).unwrap_or(i64::MAX),
                i64::try_from(call.input_chars).unwrap_or(i64::MAX),
                call.error,
            ])?;
        connection
            .prepare_cached("DELETE FROM ai_calls WHERE id <= (SELECT MAX(id) FROM ai_calls) - ?1")?
            .execute([AI_CALL_LIMIT])?;
        Ok(())
    }
}

impl AiCallRecorder for SqliteStore {
    fn record_ai_call(&self, call: &AiCall) -> Result<(), PortError> {
        self.insert_ai_call(call).map_err(PortError::new)
    }
}

#[cfg(test)]
mod tests {
    use chrono::DateTime;

    use super::*;

    #[test]
    fn records_calls() {
        let store = SqliteStore::open_in_memory().unwrap();
        store
            .record_ai_call(&AiCall {
                started_at: DateTime::from_timestamp_millis(5).unwrap(),
                profile_id: "deepseek".into(),
                task_id: "translate".into(),
                duration_ms: 1200,
                items: 2,
                input_chars: 900,
                error: Some("timeout".into()),
            })
            .unwrap();

        let row: (String, i64, Option<String>) = store
            .connection()
            .query_row(
                "SELECT profile_id, duration_ms, error FROM ai_calls",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();

        assert_eq!(row, ("deepseek".into(), 1200, Some("timeout".into())));
    }
}
