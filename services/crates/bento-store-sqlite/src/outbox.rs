use std::collections::HashSet;

use bento_app::{Outbox, OutboxEntry, PortError};
use bento_domain::FeedItem;
use rusqlite::params;
use uuid::Uuid;

use crate::{SqliteStore, StoreError};

/// One stored outbox row.
#[derive(Clone, Debug, PartialEq)]
pub struct OutboxRow {
    pub seq: i64,
    pub item: FeedItem,
    pub detail: Option<Vec<u8>>,
}

impl SqliteStore {
    fn append_new_to_outbox(&self, entries: &[OutboxEntry]) -> Result<usize, StoreError> {
        let mut connection = self.connection();
        let transaction = connection.transaction()?;
        let mut appended = 0;
        {
            let mut mark_seen = transaction.prepare_cached(
                "INSERT INTO seen_items (item_id) VALUES (?1) ON CONFLICT DO NOTHING",
            )?;
            let mut insert = transaction.prepare_cached(
                "INSERT INTO outbox (item_id, payload, detail) VALUES (?1, ?2, ?3)",
            )?;
            for entry in entries {
                let id = entry.item.id.to_string();
                if mark_seen.execute([&id])? == 0 {
                    continue;
                }
                insert.execute(params![
                    id,
                    serde_json::to_string(&entry.item)?,
                    entry.detail
                ])?;
                appended += 1;
            }
        }
        transaction.commit()?;
        Ok(appended)
    }

    fn mark_items_seen(&self, ids: &[Uuid]) -> Result<(), StoreError> {
        let mut connection = self.connection();
        let transaction = connection.transaction()?;
        {
            let mut insert = transaction.prepare_cached(
                "INSERT INTO seen_items (item_id) VALUES (?1) ON CONFLICT DO NOTHING",
            )?;
            for id in ids {
                insert.execute([id.to_string()])?;
            }
        }
        transaction.commit()?;
        Ok(())
    }

    fn unseen_items(&self, ids: &[Uuid]) -> Result<HashSet<Uuid>, StoreError> {
        let connection = self.connection();
        let mut seen = connection.prepare_cached("SELECT 1 FROM seen_items WHERE item_id = ?1")?;
        let mut unseen = HashSet::new();
        for id in ids {
            if !seen.exists([id.to_string()])? {
                unseen.insert(*id);
            }
        }
        Ok(unseen)
    }

    /// Rows with `seq` greater than `after`, oldest first.
    pub fn outbox_after(&self, after: i64, limit: usize) -> Result<Vec<OutboxRow>, StoreError> {
        let connection = self.connection();
        let mut select = connection.prepare_cached(
            "SELECT seq, payload, detail FROM outbox WHERE seq > ?1 ORDER BY seq LIMIT ?2",
        )?;
        let rows = select.query_map(
            params![after, i64::try_from(limit).unwrap_or(i64::MAX)],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<Vec<u8>>>(2)?,
                ))
            },
        )?;
        rows.map(|row| {
            let (seq, payload, detail) = row?;
            Ok(OutboxRow {
                seq,
                item: serde_json::from_str(&payload)?,
                detail,
            })
        })
        .collect()
    }
}

impl Outbox for SqliteStore {
    fn unseen(&self, ids: &[Uuid]) -> Result<HashSet<Uuid>, PortError> {
        self.unseen_items(ids).map_err(PortError::new)
    }

    fn append_new(&self, entries: &[OutboxEntry]) -> Result<usize, PortError> {
        self.append_new_to_outbox(entries).map_err(PortError::new)
    }

    fn mark_seen(&self, ids: &[Uuid]) -> Result<(), PortError> {
        self.mark_items_seen(ids).map_err(PortError::new)
    }
}

#[cfg(test)]
mod tests {
    use bento_domain::RawItem;
    use chrono::{TimeZone, Utc};
    use uuid::Uuid;

    use super::*;

    fn entry(external_id: &str, detail: Option<Vec<u8>>) -> OutboxEntry {
        let fetched_at = Utc.with_ymd_and_hms(2026, 10, 16, 9, 0, 0).unwrap();
        let item = RawItem {
            external_id: external_id.into(),
            ..Default::default()
        }
        .normalize(Uuid::from_u128(1), fetched_at)
        .pop()
        .unwrap()
        .item;
        OutboxEntry { item, detail }
    }

    #[test]
    fn appends_and_reads_back_in_order() {
        let store = SqliteStore::open_in_memory().unwrap();
        store
            .append_new(&[entry("a", Some(vec![1, 2])), entry("b", None)])
            .unwrap();

        let rows = store.outbox_after(0, 10).unwrap();

        assert_eq!(rows.len(), 2);
        assert!(rows[0].seq < rows[1].seq);
        assert_eq!(rows[0].item, entry("a", None).item);
        assert_eq!(rows[0].detail, Some(vec![1, 2]));
        assert_eq!(rows[1].detail, None);
    }

    #[test]
    fn reads_only_after_cursor() {
        let store = SqliteStore::open_in_memory().unwrap();
        store
            .append_new(&[entry("a", None), entry("b", None), entry("c", None)])
            .unwrap();
        let first = store.outbox_after(0, 1).unwrap();

        let rest = store.outbox_after(first[0].seq, 10).unwrap();

        assert_eq!(
            rest.iter()
                .map(|r| r.item.external_id.as_str())
                .collect::<Vec<_>>(),
            ["b", "c"]
        );
    }

    #[test]
    fn skips_items_appended_before() {
        let store = SqliteStore::open_in_memory().unwrap();
        assert_eq!(store.append_new(&[entry("a", None)]).unwrap(), 1);

        let appended = store
            .append_new(&[entry("a", None), entry("b", None), entry("b", None)])
            .unwrap();

        assert_eq!(appended, 1);
        let ids: Vec<_> = store
            .outbox_after(0, 10)
            .unwrap()
            .into_iter()
            .map(|r| r.item.external_id)
            .collect();
        assert_eq!(ids, ["a", "b"]);
    }

    #[test]
    fn unseen_lists_only_ids_never_appended() {
        let store = SqliteStore::open_in_memory().unwrap();
        let sent = entry("a", None);
        store.append_new(std::slice::from_ref(&sent)).unwrap();
        let fresh = entry("b", None);

        let unseen = store.unseen(&[sent.item.id, fresh.item.id]).unwrap();

        assert_eq!(unseen, HashSet::from([fresh.item.id]));
    }

    #[test]
    fn marked_items_are_seen_but_not_in_the_outbox() {
        let store = SqliteStore::open_in_memory().unwrap();
        let skipped = entry("a", None);

        store.mark_seen(&[skipped.item.id]).unwrap();

        assert!(store.unseen(&[skipped.item.id]).unwrap().is_empty());
        assert!(store.outbox_after(0, 10).unwrap().is_empty());
        assert_eq!(store.append_new(&[skipped]).unwrap(), 0);
    }

    #[test]
    fn payload_uses_milliseconds_and_snake_case() {
        let store = SqliteStore::open_in_memory().unwrap();
        store.append_new(&[entry("a", None)]).unwrap();

        let payload: String = store
            .connection()
            .query_row("SELECT payload FROM outbox", [], |row| row.get(0))
            .unwrap();
        let json: serde_json::Value = serde_json::from_str(&payload).unwrap();

        assert_eq!(json["fetched_at"], 1_792_141_200_000_i64);
        assert_eq!(json["is_published_at_estimated"], true);
    }
}
