//! Turns raw items from a source into outbox entries.
//!
//! Phase 0 only normalizes and stores. Filtering, detail extraction and AI enrichment slot in
//! here as further steps, each behind its own port.

use bento_domain::{RawItem, detail};
use uuid::Uuid;

use crate::ports::{Clock, Outbox, OutboxEntry, PortError};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct IngestReport {
    /// Entries written, including referenced items.
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

    pub fn ingest(
        &self,
        source_id: Uuid,
        raw_items: Vec<RawItem>,
    ) -> Result<IngestReport, PortError> {
        let fetched_at = self.clock.now();
        let entries: Vec<OutboxEntry> = raw_items
            .into_iter()
            .flat_map(|raw| raw.normalize(source_id, fetched_at))
            .map(|normalized| OutboxEntry {
                detail: normalized.body_markdown.as_deref().map(detail::encode),
                item: normalized.item,
            })
            .collect();
        if !entries.is_empty() {
            self.outbox.append(&entries)?;
        }
        Ok(IngestReport {
            written: entries.len(),
        })
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use bento_domain::{Reference, ReferenceKind};
    use chrono::{DateTime, TimeZone, Utc};

    use super::*;

    #[derive(Default)]
    struct FakeOutbox {
        entries: RefCell<Vec<OutboxEntry>>,
        fail: bool,
    }

    impl Outbox for &FakeOutbox {
        fn append(&self, entries: &[OutboxEntry]) -> Result<(), PortError> {
            if self.fail {
                return Err(PortError::new(std::io::Error::other("disk full")));
            }
            self.entries.borrow_mut().extend_from_slice(entries);
            Ok(())
        }
    }

    struct FixedClock(DateTime<Utc>);

    impl Clock for FixedClock {
        fn now(&self) -> DateTime<Utc> {
            self.0
        }
    }

    fn clock() -> FixedClock {
        FixedClock(Utc.with_ymd_and_hms(2026, 10, 16, 9, 0, 0).unwrap())
    }

    #[test]
    fn writes_items_with_compressed_detail() {
        let outbox = FakeOutbox::default();
        let ingestor = Ingestor::new(&outbox, clock());
        let raw = RawItem {
            external_id: "1".into(),
            body_markdown: Some("# Body".into()),
            ..Default::default()
        };

        let report = ingestor.ingest(Uuid::from_u128(1), vec![raw]).unwrap();

        assert_eq!(report.written, 1);
        let entries = outbox.entries.borrow();
        assert_eq!(entries[0].item.fetched_at, clock().0);
        assert_eq!(
            detail::decode(entries[0].detail.as_ref().unwrap()).unwrap(),
            "# Body"
        );
    }

    #[test]
    fn writes_referenced_item_before_its_parent() {
        let outbox = FakeOutbox::default();
        let raw = RawItem {
            external_id: "child".into(),
            reference: Some(Box::new(Reference {
                kind: ReferenceKind::Quote,
                item: RawItem {
                    external_id: "parent".into(),
                    ..Default::default()
                },
            })),
            ..Default::default()
        };

        let report = Ingestor::new(&outbox, clock())
            .ingest(Uuid::from_u128(1), vec![raw])
            .unwrap();

        assert_eq!(report.written, 2);
        let entries = outbox.entries.borrow();
        assert_eq!(entries[0].item.external_id, "parent");
        assert_eq!(entries[1].item.reference_item_id, Some(entries[0].item.id));
    }

    #[test]
    fn skips_outbox_when_nothing_to_write() {
        let outbox = FakeOutbox {
            fail: true,
            ..Default::default()
        };
        let report = Ingestor::new(&outbox, clock())
            .ingest(Uuid::from_u128(1), vec![])
            .unwrap();
        assert_eq!(report.written, 0);
    }

    #[test]
    fn surfaces_outbox_failure() {
        let outbox = FakeOutbox {
            fail: true,
            ..Default::default()
        };
        let raw = RawItem {
            external_id: "1".into(),
            ..Default::default()
        };
        let error = Ingestor::new(&outbox, clock())
            .ingest(Uuid::from_u128(1), vec![raw])
            .unwrap_err();
        assert_eq!(error.to_string(), "disk full");
    }
}
