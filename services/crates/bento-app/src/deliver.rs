//! Posts new items to their channel's destinations: queues a delivery per destination for each
//! new outbox item, then sends them one at a time per destination, spaced by its post delay.

use std::collections::HashSet;
use std::sync::Arc;

use bento_domain::{CollectorConfig, DestinationKind, Message};
use chrono::{DateTime, Duration, Utc};

use crate::ports::{
    Clock, Delivery, DeliveryOutcome, DeliveryStore, PortError, PublishError, Publisher,
};

/// Attempts before a delivery that keeps failing is given up.
const MAX_ATTEMPTS: u32 = 5;
const FIRST_RETRY_SECONDS: i64 = 30;
const MAX_RETRY_SECONDS: i64 = 900;
/// Outbox rows queued per pass.
const PLAN_BATCH: usize = 500;

/// How one delivery attempt went, for the log.
#[derive(Debug)]
pub struct SendReport {
    pub delivery_id: i64,
    pub destination: String,
    pub outcome: DeliveryOutcome,
}

pub struct Deliverer<S, C> {
    store: S,
    publisher: Arc<dyn Publisher>,
    clock: C,
}

impl<S: DeliveryStore, C: Clock> Deliverer<S, C> {
    /// Posts left half-sent by a previous run are marked failed, never sent again: they may have
    /// gone out.
    pub fn new(store: S, publisher: Arc<dyn Publisher>, clock: C) -> Result<Self, PortError> {
        store.fail_interrupted_deliveries(
            "interrupted while sending (not retried: it may have been posted)",
        )?;
        Ok(Self {
            store,
            publisher,
            clock,
        })
    }

    /// Queues deliveries for outbox items appended since the last pass. An item that another new
    /// item quotes is posted inside that item, not on its own. Returns how many were queued.
    pub fn plan(&self, config: &CollectorConfig) -> Result<usize, PortError> {
        let mut rows = self.store.undelivered_outbox(PLAN_BATCH)?;
        // A quoted item is appended just before the item quoting it, so a full batch leaves its
        // last row for the next pass, where it is read together with what follows.
        if rows.len() == PLAN_BATCH {
            rows.pop();
        }
        let Some(&(through_seq, _)) = rows.last() else {
            return Ok(0);
        };
        let quoted: HashSet<_> = rows
            .iter()
            .filter_map(|(_, item)| item.reference_item_id)
            .collect();
        let destinations: Vec<_> = config
            .destinations
            .iter()
            .filter(|d| d.enabled && d.kind != DestinationKind::Unsupported)
            .collect();
        let queued: Vec<_> = rows
            .iter()
            .filter(|(_, item)| !quoted.contains(&item.id))
            .flat_map(|(seq, item)| {
                destinations
                    .iter()
                    .filter(|d| d.source_ids.contains(&item.source_id))
                    .map(move |d| (d.id, item.id, *seq))
            })
            .collect();
        self.store
            .queue_deliveries(through_seq, &queued, self.clock.now())?;
        Ok(queued.len())
    }

    /// Sends each destination's oldest waiting post, once it is due and the destination's post
    /// delay has passed. Posts go out in order: one waiting to retry holds back the rest.
    /// `keep_going` is checked before each send, so shutdown never cuts one short.
    pub async fn send_due(
        &self,
        config: &CollectorConfig,
        keep_going: &(dyn Fn() -> bool + Sync),
    ) -> Result<Vec<SendReport>, PortError> {
        let mut reports = Vec::new();
        // Set by a flood wait in this pass; later passes see it in the postponed rows.
        let mut telegram_waits = false;
        for delivery in self.store.next_deliveries()? {
            let now = self.clock.now();
            let destination = config
                .destinations
                .iter()
                .find(|d| d.id == delivery.destination_id);
            let Some(destination) = destination.filter(|d| d.enabled) else {
                let outcome = DeliveryOutcome::Failed("destination removed or turned off".into());
                self.store.finish_delivery(delivery.id, &outcome, now)?;
                continue;
            };
            let delay = Duration::seconds(i64::from(destination.post_delay_seconds));
            let spaced = self
                .store
                .last_sent_at(destination.id)?
                .is_none_or(|last| now >= last + delay);
            let telegram = destination.kind == DestinationKind::TelegramBot;
            if delivery.next_attempt_at > now || !spaced || (telegram && telegram_waits) {
                continue;
            }
            if !keep_going() {
                break;
            }
            let source_name = config
                .sources
                .iter()
                .find(|s| s.id == delivery.item.source_id)
                .map_or("", |s| s.name.as_str());
            let message = Message::new(&delivery.item, delivery.referenced.as_ref(), source_name);
            self.store.start_delivery(delivery.id)?;
            let result = self.publisher.publish(destination, &message).await;
            let now = self.clock.now();
            let outcome = outcome(&delivery, result, now);
            self.store.finish_delivery(delivery.id, &outcome, now)?;
            if let DeliveryOutcome::Retry {
                at,
                failed_attempt: false,
                ..
            } = &outcome
                && telegram
            {
                telegram_waits = true;
                // A flood wait applies to the bot, so every Telegram destination waits.
                let telegram: Vec<_> = config
                    .destinations
                    .iter()
                    .filter(|d| d.kind == DestinationKind::TelegramBot)
                    .map(|d| d.id)
                    .collect();
                self.store.postpone_deliveries(&telegram, *at)?;
            }
            reports.push(SendReport {
                delivery_id: delivery.id,
                destination: destination.name.clone(),
                outcome,
            });
        }
        Ok(reports)
    }
}

fn outcome(
    delivery: &Delivery,
    result: Result<(), PublishError>,
    now: DateTime<Utc>,
) -> DeliveryOutcome {
    match result {
        Ok(()) => DeliveryOutcome::Sent,
        Err(PublishError::RateLimited(wait)) => DeliveryOutcome::Retry {
            at: now + to_chrono(wait),
            error: format!("rate limited for {}s", wait.as_secs()),
            failed_attempt: false,
        },
        Err(PublishError::TimedOut(error)) => {
            DeliveryOutcome::Failed(format!("{error} (not retried: it may have been posted)"))
        }
        Err(PublishError::Rejected(error)) => DeliveryOutcome::Failed(error),
        Err(PublishError::Failed(error)) => {
            let attempts = delivery.attempts + 1;
            if attempts >= MAX_ATTEMPTS {
                DeliveryOutcome::Failed(format!("{error} (gave up after {attempts} attempts)"))
            } else {
                DeliveryOutcome::Retry {
                    at: now + retry_delay(attempts),
                    error,
                    failed_attempt: true,
                }
            }
        }
    }
}

/// 30 s after the first failure, doubling, at most 15 minutes.
fn retry_delay(attempts: u32) -> Duration {
    let seconds = FIRST_RETRY_SECONDS.saturating_mul(1 << attempts.saturating_sub(1).min(10));
    Duration::seconds(seconds.min(MAX_RETRY_SECONDS))
}

fn to_chrono(wait: std::time::Duration) -> Duration {
    Duration::from_std(wait).unwrap_or(Duration::seconds(MAX_RETRY_SECONDS))
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use async_trait::async_trait;
    use bento_domain::{DestinationConfig, FeedItem, SourceConfig};
    use futures::executor::block_on;
    use uuid::Uuid;

    use super::*;

    #[derive(Default)]
    struct Store {
        outbox: Mutex<Vec<(i64, FeedItem)>>,
        cursor: Mutex<i64>,
        queue: Mutex<Vec<(i64, Uuid, Uuid, DeliveryOutcomeState)>>,
        sent_at: Mutex<Vec<(Uuid, DateTime<Utc>)>>,
    }

    #[derive(Clone, Debug, PartialEq)]
    enum DeliveryOutcomeState {
        Pending { at: DateTime<Utc>, attempts: u32 },
        Done(DeliveryOutcome),
    }

    impl DeliveryStore for Store {
        fn undelivered_outbox(&self, limit: usize) -> Result<Vec<(i64, FeedItem)>, PortError> {
            let cursor = *self.cursor.lock().unwrap();
            let rows = self.outbox.lock().unwrap();
            Ok(rows
                .iter()
                .filter(|(seq, _)| *seq > cursor)
                .take(limit)
                .cloned()
                .collect())
        }
        fn queue_deliveries(
            &self,
            through: i64,
            rows: &[(Uuid, Uuid, i64)],
            now: DateTime<Utc>,
        ) -> Result<(), PortError> {
            let mut queue = self.queue.lock().unwrap();
            for &(destination, item, _) in rows {
                let id = i64::try_from(queue.len()).unwrap() + 1;
                queue.push((
                    id,
                    destination,
                    item,
                    DeliveryOutcomeState::Pending {
                        at: now,
                        attempts: 0,
                    },
                ));
            }
            *self.cursor.lock().unwrap() = through;
            Ok(())
        }
        fn next_deliveries(&self) -> Result<Vec<Delivery>, PortError> {
            let outbox = self.outbox.lock().unwrap();
            let mut seen = HashSet::new();
            Ok(self
                .queue
                .lock()
                .unwrap()
                .iter()
                .filter_map(|(id, destination, item, state)| match state {
                    DeliveryOutcomeState::Pending { at, attempts } if seen.insert(*destination) => {
                        Some(Delivery {
                            id: *id,
                            destination_id: *destination,
                            item: outbox
                                .iter()
                                .find(|(_, i)| i.id == *item)
                                .unwrap()
                                .1
                                .clone(),
                            referenced: None,
                            attempts: *attempts,
                            next_attempt_at: *at,
                        })
                    }
                    _ => None,
                })
                .collect())
        }
        fn start_delivery(&self, _: i64) -> Result<(), PortError> {
            Ok(())
        }
        fn fail_interrupted_deliveries(&self, _: &str) -> Result<(), PortError> {
            Ok(())
        }
        fn postpone_deliveries(
            &self,
            destinations: &[Uuid],
            until: DateTime<Utc>,
        ) -> Result<(), PortError> {
            for entry in self.queue.lock().unwrap().iter_mut() {
                if let DeliveryOutcomeState::Pending { at, .. } = &mut entry.3
                    && destinations.contains(&entry.1)
                {
                    *at = (*at).max(until);
                }
            }
            Ok(())
        }
        fn last_sent_at(&self, destination: Uuid) -> Result<Option<DateTime<Utc>>, PortError> {
            Ok(self
                .sent_at
                .lock()
                .unwrap()
                .iter()
                .rev()
                .find(|(d, _)| *d == destination)
                .map(|(_, at)| *at))
        }
        fn finish_delivery(
            &self,
            id: i64,
            outcome: &DeliveryOutcome,
            now: DateTime<Utc>,
        ) -> Result<(), PortError> {
            let mut queue = self.queue.lock().unwrap();
            let entry = queue.iter_mut().find(|(i, ..)| *i == id).unwrap();
            entry.3 = match (outcome, &entry.3) {
                (
                    DeliveryOutcome::Retry {
                        at, failed_attempt, ..
                    },
                    DeliveryOutcomeState::Pending { attempts, .. },
                ) => DeliveryOutcomeState::Pending {
                    at: *at,
                    attempts: attempts + u32::from(*failed_attempt),
                },
                _ => DeliveryOutcomeState::Done(outcome.clone()),
            };
            if *outcome == DeliveryOutcome::Sent {
                self.sent_at.lock().unwrap().push((entry.1, now));
            }
            Ok(())
        }
    }

    struct Publish(Mutex<Vec<Result<(), PublishError>>>, Mutex<Vec<String>>);

    #[async_trait]
    impl Publisher for Publish {
        async fn publish(
            &self,
            destination: &DestinationConfig,
            message: &Message,
        ) -> Result<(), PublishError> {
            self.1
                .lock()
                .unwrap()
                .push(format!("{}:{}", destination.name, message.text));
            let mut results = self.0.lock().unwrap();
            if results.is_empty() {
                Ok(())
            } else {
                results.remove(0)
            }
        }
    }

    struct Clock(Mutex<DateTime<Utc>>);
    impl crate::ports::Clock for Clock {
        fn now(&self) -> DateTime<Utc> {
            *self.0.lock().unwrap()
        }
    }

    const SOURCE: Uuid = Uuid::from_u128(10);

    fn item(n: u128, text: &str) -> FeedItem {
        let mut item: FeedItem = serde_json::from_value(serde_json::json!({
            "id": Uuid::from_u128(n), "source_id": SOURCE, "external_id": n.to_string(), "url": null,
            "title": null, "text": text, "translated_title": null, "summary": null, "author_name": null,
            "author_handle": null, "author_avatar_url": null, "media": [], "reference_item_id": null,
            "published_at": 0, "is_published_at_estimated": false, "language": null, "fetched_at": 0
        }))
        .unwrap();
        item.text = text.into();
        item
    }

    fn destination(n: u128, kind: DestinationKind) -> DestinationConfig {
        DestinationConfig {
            id: Uuid::from_u128(n),
            kind,
            name: format!("d{n}"),
            chat_id: None,
            post_delay_seconds: 20,
            enabled: true,
            source_ids: vec![SOURCE],
        }
    }

    fn config(destinations: Vec<DestinationConfig>) -> CollectorConfig {
        let source: SourceConfig = serde_json::from_value(serde_json::json!({
            "id": SOURCE, "plugin_id": "rss", "name": "News", "query": "", "interval_minutes": 30, "enabled": true
        }))
        .unwrap();
        CollectorConfig {
            sources: vec![source],
            destinations,
            ..CollectorConfig::default()
        }
    }

    #[allow(clippy::type_complexity)]
    fn deliverer(
        results: Vec<Result<(), PublishError>>,
    ) -> (
        Deliverer<Arc<Store>, Arc<Clock>>,
        Arc<Store>,
        Arc<Publish>,
        Arc<Clock>,
    ) {
        let store = Arc::new(Store::default());
        let publisher = Arc::new(Publish(Mutex::new(results), Mutex::new(Vec::new())));
        let clock = Arc::new(Clock(Mutex::new(
            DateTime::from_timestamp(1_800_000_000, 0).unwrap(),
        )));
        (
            Deliverer::new(store.clone(), publisher.clone(), clock.clone()).unwrap(),
            store,
            publisher,
            clock,
        )
    }

    fn advance(clock: &Clock, seconds: i64) {
        let mut now = clock.0.lock().unwrap();
        *now += Duration::seconds(seconds);
    }

    #[test]
    fn queues_each_new_item_once_and_skips_quoted_ones() {
        let (deliverer, store, _, _) = deliverer(vec![]);
        let quoted = item(1, "orig");
        let mut quote = item(2, "take");
        quote.reference_item_id = Some(quoted.id);
        *store.outbox.lock().unwrap() = vec![(1, quoted), (2, quote)];
        let config = config(vec![
            destination(100, DestinationKind::Discord),
            destination(101, DestinationKind::Unsupported),
        ]);

        assert_eq!(deliverer.plan(&config).unwrap(), 1);
        assert_eq!(deliverer.plan(&config).unwrap(), 0, "the cursor moved");
        assert_eq!(store.queue.lock().unwrap()[0].2, Uuid::from_u128(2));
    }

    #[test]
    fn spaces_posts_by_the_destination_delay() {
        let (deliverer, store, publisher, clock) = deliverer(vec![]);
        *store.outbox.lock().unwrap() = vec![(1, item(1, "a")), (2, item(2, "b"))];
        let config = config(vec![destination(100, DestinationKind::Discord)]);
        deliverer.plan(&config).unwrap();

        block_on(deliverer.send_due(&config, &|| true)).unwrap();
        advance(&clock, 5);
        block_on(deliverer.send_due(&config, &|| true)).unwrap();
        assert_eq!(*publisher.1.lock().unwrap(), ["d100:a"]);
        advance(&clock, 15);
        block_on(deliverer.send_due(&config, &|| true)).unwrap();
        assert_eq!(*publisher.1.lock().unwrap(), ["d100:a", "d100:b"]);
    }

    #[test]
    fn retries_with_backoff_then_gives_up_and_never_retries_timeouts() {
        let failures = (0..5)
            .map(|_| Err(PublishError::Failed("502".into())))
            .collect();
        let (deliverer, store, publisher, clock) = deliverer(failures);
        *store.outbox.lock().unwrap() = vec![(1, item(1, "a"))];
        let config = config(vec![destination(100, DestinationKind::Discord)]);
        deliverer.plan(&config).unwrap();

        for wait in [30, 60, 120, 240] {
            block_on(deliverer.send_due(&config, &|| true)).unwrap();
            advance(&clock, wait - 1);
            block_on(deliverer.send_due(&config, &|| true)).unwrap();
            advance(&clock, 1);
        }
        let reports = block_on(deliverer.send_due(&config, &|| true)).unwrap();
        assert_eq!(publisher.1.lock().unwrap().len(), 5);
        assert!(
            matches!(&reports[0].outcome, DeliveryOutcome::Failed(e) if e.contains("gave up after 5"))
        );

        assert_eq!(retry_delay(10), Duration::seconds(900));
        let now = crate::ports::Clock::now(&clock);
        let delivery = Delivery {
            id: 1,
            destination_id: Uuid::nil(),
            item: item(1, ""),
            referenced: None,
            attempts: 0,
            next_attempt_at: now,
        };
        assert!(matches!(
            outcome(&delivery, Err(PublishError::TimedOut("t".into())), now),
            DeliveryOutcome::Failed(_)
        ));
    }

    #[test]
    fn a_telegram_flood_wait_pauses_every_telegram_destination() {
        let (deliverer, store, publisher, clock) = deliverer(vec![Err(PublishError::RateLimited(
            std::time::Duration::from_secs(60),
        ))]);
        *store.outbox.lock().unwrap() = vec![(1, item(1, "a"))];
        let config = config(vec![
            destination(100, DestinationKind::TelegramBot),
            destination(101, DestinationKind::TelegramBot),
            destination(102, DestinationKind::Discord),
        ]);
        deliverer.plan(&config).unwrap();

        block_on(deliverer.send_due(&config, &|| true)).unwrap();
        assert_eq!(
            *publisher.1.lock().unwrap(),
            ["d100:a", "d102:a"],
            "d101 waits with d100"
        );
        advance(&clock, 60);
        block_on(deliverer.send_due(&config, &|| true)).unwrap();
        assert_eq!(publisher.1.lock().unwrap().len(), 4);
        let attempts = store
            .queue
            .lock()
            .unwrap()
            .iter()
            .filter(|q| matches!(q.3, DeliveryOutcomeState::Done(DeliveryOutcome::Sent)))
            .count();
        assert_eq!(attempts, 3);
    }

    #[test]
    fn a_rate_limit_holds_back_the_destinations_later_posts() {
        let (deliverer, store, publisher, clock) = deliverer(vec![Err(PublishError::RateLimited(
            std::time::Duration::from_secs(60),
        ))]);
        *store.outbox.lock().unwrap() = vec![(1, item(1, "a")), (2, item(2, "b"))];
        let config = config(vec![destination(100, DestinationKind::Discord)]);
        deliverer.plan(&config).unwrap();

        block_on(deliverer.send_due(&config, &|| true)).unwrap();
        advance(&clock, 30);
        block_on(deliverer.send_due(&config, &|| true)).unwrap();
        assert_eq!(*publisher.1.lock().unwrap(), ["d100:a"], "b waits behind a");
        advance(&clock, 30);
        block_on(deliverer.send_due(&config, &|| true)).unwrap();
        assert_eq!(*publisher.1.lock().unwrap(), ["d100:a", "d100:a"]);
    }

    #[test]
    fn stops_before_sending_when_asked() {
        let (deliverer, store, publisher, _) = deliverer(vec![]);
        *store.outbox.lock().unwrap() = vec![(1, item(1, "a"))];
        let config = config(vec![destination(100, DestinationKind::Discord)]);
        deliverer.plan(&config).unwrap();

        block_on(deliverer.send_due(&config, &|| false)).unwrap();

        assert!(publisher.1.lock().unwrap().is_empty());
    }
}
