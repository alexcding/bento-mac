use bento_app::{Delivery, DeliveryOutcome, DeliveryStore, PortError};
use bento_domain::FeedItem;
use chrono::{DateTime, Utc};
use rusqlite::{OptionalExtension, params};
use uuid::Uuid;

use crate::{SqliteStore, StoreError};

/// Finished (sent or failed) rows kept in `deliveries`.
const FINISHED_LIMIT: i64 = 5_000;

impl SqliteStore {
    fn outbox_after_delivery_cursor(
        &self,
        limit: usize,
    ) -> Result<Vec<(i64, FeedItem)>, StoreError> {
        let connection = self.connection();
        let mut select = connection.prepare_cached(
            "SELECT seq, payload FROM outbox
             WHERE seq > (SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'delivery_seq')
             ORDER BY seq LIMIT ?1",
        )?;
        let rows = select.query_map([i64::try_from(limit).unwrap_or(i64::MAX)], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        })?;
        rows.map(|row| {
            let (seq, payload) = row?;
            Ok((seq, serde_json::from_str(&payload)?))
        })
        .collect()
    }

    fn insert_deliveries(
        &self,
        through_seq: i64,
        deliveries: &[(Uuid, Uuid, i64)],
        now: DateTime<Utc>,
    ) -> Result<(), StoreError> {
        let mut connection = self.connection();
        let transaction = connection.transaction()?;
        {
            let mut insert = transaction.prepare_cached(
                "INSERT OR IGNORE INTO deliveries (destination_id, item_id, outbox_seq, next_attempt_at)
                 VALUES (?1, ?2, ?3, ?4)",
            )?;
            for (destination_id, item_id, seq) in deliveries {
                insert.execute(params![
                    destination_id.to_string(),
                    item_id.to_string(),
                    seq,
                    now.timestamp_millis()
                ])?;
            }
            transaction
                .prepare_cached("UPDATE meta SET value = ?1 WHERE key = 'delivery_seq'")?
                .execute([through_seq.to_string()])?;
        }
        transaction.commit()?;
        Ok(())
    }

    fn load_next_deliveries(&self) -> Result<Vec<Delivery>, StoreError> {
        let connection = self.connection();
        let mut select = connection.prepare_cached(
            "SELECT d.id, d.destination_id, d.attempts, d.next_attempt_at, o.payload,
                    (SELECT q.payload FROM outbox q
                     WHERE q.item_id = json_extract(o.payload, '$.reference_item_id')
                     ORDER BY q.seq LIMIT 1)
             FROM deliveries d JOIN outbox o ON o.seq = d.outbox_seq
             WHERE d.id IN (SELECT MIN(id) FROM deliveries WHERE state = 'pending' GROUP BY destination_id)
             ORDER BY d.id",
        )?;
        let rows = select.query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, u32>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, Option<String>>(5)?,
            ))
        })?;
        rows.map(|row| {
            let (id, destination_id, attempts, next_attempt_at, payload, referenced) = row?;
            Ok(Delivery {
                id,
                destination_id: Uuid::parse_str(&destination_id).unwrap_or_default(),
                item: serde_json::from_str(&payload)?,
                referenced: referenced
                    .map(|json| serde_json::from_str(&json))
                    .transpose()?,
                attempts,
                next_attempt_at: DateTime::from_timestamp_millis(next_attempt_at)
                    .unwrap_or_default(),
            })
        })
        .collect()
    }

    fn execute(&self, sql: &str, params: impl rusqlite::Params) -> Result<(), StoreError> {
        self.connection().prepare_cached(sql)?.execute(params)?;
        Ok(())
    }

    fn load_last_sent_at(&self, destination_id: Uuid) -> Result<Option<DateTime<Utc>>, StoreError> {
        let millis: Option<i64> = self
            .connection()
            .prepare_cached("SELECT MAX(sent_at) FROM deliveries WHERE destination_id = ?1")?
            .query_row([destination_id.to_string()], |row| row.get(0))
            .optional()?
            .flatten();
        Ok(millis.and_then(DateTime::from_timestamp_millis))
    }

    fn store_delivery_outcome(
        &self,
        id: i64,
        outcome: &DeliveryOutcome,
        now: DateTime<Utc>,
    ) -> Result<(), StoreError> {
        let connection = self.connection();
        match outcome {
            DeliveryOutcome::Sent => connection
                .prepare_cached(
                    "UPDATE deliveries SET state = 'sent', sent_at = ?2, last_error = NULL WHERE id = ?1",
                )?
                .execute(params![id, now.timestamp_millis()])?,
            DeliveryOutcome::Retry { at, error, failed_attempt } => connection
                .prepare_cached(
                    "UPDATE deliveries SET state = 'pending', next_attempt_at = ?2, last_error = ?3,
                       attempts = attempts + ?4
                     WHERE id = ?1",
                )?
                .execute(params![id, at.timestamp_millis(), error, i64::from(*failed_attempt)])?,
            DeliveryOutcome::Failed(error) => connection
                .prepare_cached(
                    "UPDATE deliveries SET state = 'failed', last_error = ?2, attempts = attempts + 1
                     WHERE id = ?1",
                )?
                .execute(params![id, error])?,
        };
        if !matches!(outcome, DeliveryOutcome::Retry { .. }) {
            connection
                .prepare_cached(
                    "DELETE FROM deliveries WHERE state IN ('sent', 'failed') AND id NOT IN
                       (SELECT id FROM deliveries WHERE state IN ('sent', 'failed') ORDER BY id DESC LIMIT ?1)",
                )?
                .execute([FINISHED_LIMIT])?;
        }
        Ok(())
    }
}

impl DeliveryStore for SqliteStore {
    fn undelivered_outbox(&self, limit: usize) -> Result<Vec<(i64, FeedItem)>, PortError> {
        self.outbox_after_delivery_cursor(limit)
            .map_err(PortError::new)
    }

    fn queue_deliveries(
        &self,
        through_seq: i64,
        deliveries: &[(Uuid, Uuid, i64)],
        now: DateTime<Utc>,
    ) -> Result<(), PortError> {
        self.insert_deliveries(through_seq, deliveries, now)
            .map_err(PortError::new)
    }

    fn next_deliveries(&self) -> Result<Vec<Delivery>, PortError> {
        self.load_next_deliveries().map_err(PortError::new)
    }

    fn start_delivery(&self, id: i64) -> Result<(), PortError> {
        self.execute(
            "UPDATE deliveries SET state = 'sending' WHERE id = ?1",
            [id],
        )
        .map_err(PortError::new)
    }

    fn fail_interrupted_deliveries(&self, error: &str) -> Result<(), PortError> {
        self.execute(
            "UPDATE deliveries SET state = 'failed', last_error = ?1, attempts = attempts + 1
             WHERE state = 'sending'",
            [error],
        )
        .map_err(PortError::new)
    }

    fn telegram_paused_until(&self) -> Result<Option<DateTime<Utc>>, PortError> {
        let millis: Option<String> = self
            .connection()
            .query_row(
                "SELECT value FROM meta WHERE key = 'telegram_paused_until'",
                [],
                |row| row.get(0),
            )
            .optional()
            .map_err(PortError::new)?;
        Ok(millis
            .and_then(|value| value.parse().ok())
            .and_then(DateTime::from_timestamp_millis))
    }

    fn pause_telegram(&self, until: DateTime<Utc>) -> Result<(), PortError> {
        self.execute(
            "INSERT INTO meta (key, value) VALUES ('telegram_paused_until', ?1)
             ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            [until.timestamp_millis().to_string()],
        )
        .map_err(PortError::new)
    }

    fn last_sent_at(&self, destination_id: Uuid) -> Result<Option<DateTime<Utc>>, PortError> {
        self.load_last_sent_at(destination_id)
            .map_err(PortError::new)
    }

    fn finish_delivery(
        &self,
        id: i64,
        outcome: &DeliveryOutcome,
        now: DateTime<Utc>,
    ) -> Result<(), PortError> {
        self.store_delivery_outcome(id, outcome, now)
            .map_err(PortError::new)
    }
}

#[cfg(test)]
mod tests {
    use bento_app::{Outbox, OutboxEntry};
    use bento_domain::RawItem;

    use super::*;

    fn entry(external_id: &str, reference: Option<Uuid>) -> OutboxEntry {
        let raw = RawItem {
            external_id: external_id.into(),
            text: format!("text {external_id}"),
            ..RawItem::default()
        };
        let mut item = raw.normalize(Uuid::from_u128(9), Utc::now()).remove(0).item;
        item.reference_item_id = reference;
        OutboxEntry { item, detail: None }
    }

    #[test]
    fn existing_outbox_rows_are_never_delivered() {
        let path = tempfile::NamedTempFile::new().unwrap();
        {
            let store = SqliteStore::open(path.path()).unwrap();
            store.append_new(&[entry("old", None)]).unwrap();
            store.connection().execute_batch("PRAGMA user_version = 6; DROP TABLE deliveries; DELETE FROM meta WHERE key = 'delivery_seq'; DROP INDEX outbox_item_id;").unwrap();
        }
        let store = SqliteStore::open(path.path()).unwrap();
        assert!(store.undelivered_outbox(10).unwrap().is_empty());

        store.append_new(&[entry("new", None)]).unwrap();
        assert_eq!(store.undelivered_outbox(10).unwrap().len(), 1);
    }

    #[test]
    fn queues_once_loads_due_with_the_quoted_item_and_records_outcomes() {
        let store = SqliteStore::open_in_memory().unwrap();
        let quoted = entry("q", None);
        let quote = entry("p", Some(quoted.item.id));
        store.append_new(&[quoted.clone(), quote.clone()]).unwrap();
        let rows = store.undelivered_outbox(10).unwrap();
        let destination = Uuid::from_u128(5);
        let now = Utc::now();
        let queued = [(destination, quote.item.id, rows[1].0)];

        store.queue_deliveries(rows[1].0, &queued, now).unwrap();
        store.queue_deliveries(rows[1].0, &queued, now).unwrap();
        assert!(store.undelivered_outbox(10).unwrap().is_empty());

        let due = store.next_deliveries().unwrap();
        assert_eq!(due.len(), 1, "queued once");
        assert_eq!(
            due[0].referenced.as_ref().map(|i| i.id),
            Some(quoted.item.id)
        );

        let later = now + chrono::Duration::seconds(30);
        let retry = DeliveryOutcome::Retry {
            at: later,
            error: "502".into(),
            failed_attempt: true,
        };
        store.start_delivery(due[0].id).unwrap();
        store.finish_delivery(due[0].id, &retry, now).unwrap();
        let waiting = store.next_deliveries().unwrap();
        assert_eq!(
            (
                waiting[0].attempts,
                waiting[0].next_attempt_at.timestamp_millis()
            ),
            (1, later.timestamp_millis())
        );

        store
            .finish_delivery(due[0].id, &DeliveryOutcome::Sent, later)
            .unwrap();
        assert!(store.next_deliveries().unwrap().is_empty());
        assert_eq!(
            store
                .last_sent_at(destination)
                .unwrap()
                .map(|at| at.timestamp_millis()),
            Some(later.timestamp_millis())
        );
    }

    #[test]
    fn heads_per_destination_telegram_pause_and_interrupted_sends() {
        let store = SqliteStore::open_in_memory().unwrap();
        let items = [entry("a", None), entry("b", None)];
        store.append_new(&items).unwrap();
        let rows = store.undelivered_outbox(10).unwrap();
        let (first, second) = (Uuid::from_u128(1), Uuid::from_u128(2));
        let now = Utc::now();
        let queued = [
            (first, items[0].item.id, rows[0].0),
            (first, items[1].item.id, rows[1].0),
            (second, items[1].item.id, rows[1].0),
        ];
        store.queue_deliveries(rows[1].0, &queued, now).unwrap();

        let heads = store.next_deliveries().unwrap();
        assert_eq!(
            heads
                .iter()
                .map(|d| (d.destination_id, d.item.id))
                .collect::<Vec<_>>(),
            [(first, items[0].item.id), (second, items[1].item.id)]
        );

        let until = now + chrono::Duration::seconds(60);
        assert_eq!(store.telegram_paused_until().unwrap(), None);
        store.pause_telegram(until).unwrap();
        assert_eq!(
            store
                .telegram_paused_until()
                .unwrap()
                .map(|at| at.timestamp_millis()),
            Some(until.timestamp_millis())
        );

        store.start_delivery(heads[0].id).unwrap();
        store.fail_interrupted_deliveries("interrupted").unwrap();
        let heads = store.next_deliveries().unwrap();
        assert_eq!(
            heads[0].item.id, items[1].item.id,
            "the interrupted post is never sent again"
        );
    }
}
