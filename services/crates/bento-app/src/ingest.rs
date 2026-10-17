//! Turns raw items from a source into outbox entries.
//!
//! Detail extraction and AI enrichment slot in here as further steps, each behind its own port.

use bento_domain::{RawItem, detail};
use chrono::Duration;
use uuid::Uuid;

use crate::ports::{Clock, Outbox, OutboxEntry, PortError};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct IngestReport {
    /// Raw items received from the source.
    pub fetched: usize,
    /// Raw items dropped for being older than the maximum age.
    pub too_old: usize,
    /// New entries appended to the outbox, including referenced items.
    pub written: usize,
}

pub struct Ingestor<O, C> {
    outbox: O,
    clock: C,
}

impl<O: Outbox, C: Clock> Ingestor<O, C> {
    pub fn new(outbox: O, clock: C) -> Self {
        Self { outbox, clock }
    }

    /// Normalizes, drops items published before `now - max_age` (no limit if that underflows),
    /// and appends the rest.
    /// Items already appended earlier are skipped by the outbox.
    pub fn ingest(
        &self,
        source_id: Uuid,
        raw_items: Vec<RawItem>,
        max_age: Duration,
    ) -> Result<IngestReport, PortError> {
        let fetched_at = self.clock.now();
        let oldest = fetched_at.checked_sub_signed(max_age);
        let fetched = raw_items.len();
        let fresh: Vec<RawItem> = raw_items
            .into_iter()
            .filter(|raw| match (raw.published_at, oldest) {
                (Some(at), Some(oldest)) => at >= oldest,
                _ => true,
            })
            .collect();
        let too_old = fetched - fresh.len();
        let entries: Vec<OutboxEntry> = fresh
            .into_iter()
            .flat_map(|raw| raw.normalize(source_id, fetched_at))
            .map(|normalized| OutboxEntry {
                detail: normalized.body_markdown.as_deref().map(detail::encode),
                item: normalized.item,
            })
            .collect();
        let written = if entries.is_empty() {
            0
        } else {
            self.outbox.append_new(&entries)?
        };
        Ok(IngestReport {
            fetched,
            too_old,
            written,
        })
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::cell::RefCell;
    use std::collections::HashSet;

    use bento_domain::{Reference, ReferenceKind};
    use chrono::{DateTime, TimeZone, Utc};

    use super::*;

    /// In-memory outbox with the same skip-already-appended rule as the SQLite adapter.
    #[derive(Default)]
    pub(crate) struct FakeOutbox {
        pub(crate) entries: RefCell<Vec<OutboxEntry>>,
        seen: RefCell<HashSet<Uuid>>,
        pub(crate) fail: bool,
    }

    impl Outbox for FakeOutbox {
        fn append_new(&self, entries: &[OutboxEntry]) -> Result<usize, PortError> {
            if self.fail {
                return Err(PortError::msg("disk full"));
            }
            let mut appended = 0;
            for entry in entries {
                if self.seen.borrow_mut().insert(entry.item.id) {
                    self.entries.borrow_mut().push(entry.clone());
                    appended += 1;
                }
            }
            Ok(appended)
        }
    }

    pub(crate) struct FixedClock(pub(crate) RefCell<DateTime<Utc>>);

    impl FixedClock {
        pub(crate) fn at(hour: u32) -> Self {
            Self(RefCell::new(
                Utc.with_ymd_and_hms(2026, 10, 16, hour, 0, 0).unwrap(),
            ))
        }
    }

    impl Clock for FixedClock {
        fn now(&self) -> DateTime<Utc> {
            *self.0.borrow()
        }
    }

    fn raw(id: &str) -> RawItem {
        RawItem {
            external_id: id.into(),
            ..Default::default()
        }
    }

    const DAY: Duration = Duration::days(1);

    #[test]
    fn writes_items_with_compressed_detail() {
        let outbox = FakeOutbox::default();
        let clock = FixedClock::at(9);
        let item = RawItem {
            body_markdown: Some("# Body".into()),
            ..raw("1")
        };

        let report = Ingestor::new(&outbox, &clock)
            .ingest(Uuid::from_u128(1), vec![item], DAY)
            .unwrap();

        assert_eq!(
            report,
            IngestReport {
                fetched: 1,
                too_old: 0,
                written: 1
            }
        );
        let entries = outbox.entries.borrow();
        assert_eq!(entries[0].item.fetched_at, clock.now());
        assert_eq!(
            detail::decode(entries[0].detail.as_ref().unwrap()).unwrap(),
            "# Body"
        );
    }

    #[test]
    fn writes_referenced_item_before_its_parent() {
        let outbox = FakeOutbox::default();
        let item = RawItem {
            reference: Some(Box::new(Reference {
                kind: ReferenceKind::Quote,
                item: raw("parent"),
            })),
            ..raw("child")
        };

        let report = Ingestor::new(&outbox, FixedClock::at(9))
            .ingest(Uuid::from_u128(1), vec![item], DAY)
            .unwrap();

        assert_eq!(report.written, 2);
        let entries = outbox.entries.borrow();
        assert_eq!(entries[0].item.external_id, "parent");
        assert_eq!(entries[1].item.reference_item_id, Some(entries[0].item.id));
    }

    #[test]
    fn drops_items_older_than_max_age_but_keeps_undated() {
        let outbox = FakeOutbox::default();
        let clock = FixedClock::at(9);
        let old = RawItem {
            published_at: Some(clock.now() - Duration::days(2)),
            ..raw("old")
        };
        let recent = RawItem {
            published_at: Some(clock.now() - Duration::hours(1)),
            ..raw("new")
        };

        let report = Ingestor::new(&outbox, &clock)
            .ingest(Uuid::from_u128(1), vec![old, recent, raw("undated")], DAY)
            .unwrap();

        assert_eq!(
            report,
            IngestReport {
                fetched: 3,
                too_old: 1,
                written: 2
            }
        );
    }

    #[test]
    fn counts_only_items_not_seen_before() {
        let outbox = FakeOutbox::default();
        let ingestor = Ingestor::new(&outbox, FixedClock::at(9));
        ingestor
            .ingest(Uuid::from_u128(1), vec![raw("a")], DAY)
            .unwrap();

        let report = ingestor
            .ingest(Uuid::from_u128(1), vec![raw("a"), raw("b")], DAY)
            .unwrap();

        assert_eq!(report.written, 1);
    }

    #[test]
    fn skips_outbox_when_nothing_to_write() {
        let outbox = FakeOutbox {
            fail: true,
            ..Default::default()
        };
        let report = Ingestor::new(&outbox, FixedClock::at(9))
            .ingest(Uuid::from_u128(1), vec![], DAY)
            .unwrap();
        assert_eq!(report.written, 0);
    }

    #[test]
    fn surfaces_outbox_failure() {
        let outbox = FakeOutbox {
            fail: true,
            ..Default::default()
        };
        let error = Ingestor::new(&outbox, FixedClock::at(9))
            .ingest(Uuid::from_u128(1), vec![raw("1")], DAY)
            .unwrap_err();
        assert_eq!(error.to_string(), "disk full");
    }
}
