//! Runs each enabled source when it is due, and records the outcome.

use std::collections::HashMap;
use std::sync::Arc;

use bento_domain::{CollectorConfig, SourceConfig};
use chrono::{DateTime, Duration, Utc};
use uuid::Uuid;

use crate::ingest::{IngestReport, Ingestor};
use crate::ports::{
    Clock, Outbox, PortError, RunRecord, SourceFetcher, SourceState, SourceStateStore,
};

/// Fetchers keyed by plugin ID.
pub type FetcherRegistry = HashMap<String, Arc<dyn SourceFetcher>>;

/// Retry delay after the first failure. Doubles per consecutive failure, capped at the source's
/// interval.
const FIRST_RETRY: Duration = Duration::minutes(1);

#[derive(Debug)]
pub struct RunReport {
    pub source_id: Uuid,
    pub outcome: Result<IngestReport, PortError>,
}

pub struct Scheduler<S, O, C> {
    fetchers: FetcherRegistry,
    states: S,
    outbox: O,
    clock: C,
}

impl<S: SourceStateStore, O: Outbox, C: Clock> Scheduler<S, O, C> {
    pub fn new(fetchers: FetcherRegistry, states: S, outbox: O, clock: C) -> Self {
        Self {
            fetchers,
            states,
            outbox,
            clock,
        }
    }

    /// Runs every enabled source whose next run is due, one at a time.
    pub async fn run_due(&self, config: &CollectorConfig) -> Result<Vec<RunReport>, PortError> {
        let mut reports = Vec::new();
        for source in config.sources.iter().filter(|s| s.enabled) {
            let state = self.states.source_state(source.id)?;
            if state
                .as_ref()
                .is_some_and(|s| s.next_run_at > self.clock.now())
            {
                continue;
            }
            let started_at = self.clock.now();
            let timer = std::time::Instant::now();
            let outcome = self.run(source, config).await;
            let duration_ms = u64::try_from(timer.elapsed().as_millis()).unwrap_or(u64::MAX);
            self.states
                .record_run(&run_record(source.id, started_at, duration_ms, &outcome))?;
            self.states.save_source_state(&next_state(
                source,
                state,
                &outcome,
                self.clock.now(),
            ))?;
            reports.push(RunReport {
                source_id: source.id,
                outcome,
            });
        }
        Ok(reports)
    }

    async fn run(
        &self,
        source: &SourceConfig,
        config: &CollectorConfig,
    ) -> Result<IngestReport, PortError> {
        let fetcher = self
            .fetchers
            .get(&source.plugin_id)
            .ok_or_else(|| PortError::msg(format!("no plugin named '{}'", source.plugin_id)))?;
        let items = fetcher.fetch(source).await?;
        let max_age = Duration::hours(i64::from(config.max_item_age_hours));
        Ingestor::new(&self.outbox, &self.clock).ingest(source.id, items, max_age)
    }
}

fn run_record(
    source_id: Uuid,
    started_at: DateTime<Utc>,
    duration_ms: u64,
    outcome: &Result<IngestReport, PortError>,
) -> RunRecord {
    let (fetched, too_old, new_items, error) = match outcome {
        Ok(report) => (report.fetched, report.too_old, report.written, None),
        Err(error) => (0, 0, 0, Some(error.to_string())),
    };
    RunRecord {
        source_id,
        started_at,
        duration_ms,
        fetched,
        too_old,
        new_items,
        error,
    }
}

fn next_state(
    source: &SourceConfig,
    previous: Option<SourceState>,
    outcome: &Result<IngestReport, PortError>,
    now: DateTime<Utc>,
) -> SourceState {
    let interval = Duration::minutes(i64::from(source.interval_minutes.max(1)));
    match outcome {
        Ok(report) => SourceState {
            source_id: source.id,
            last_run_at: Some(now),
            next_run_at: now + interval,
            consecutive_failures: 0,
            last_error: None,
            last_new_items: report.written,
        },
        Err(error) => {
            let failures = previous.as_ref().map_or(0, |s| s.consecutive_failures) + 1;
            let backoff = FIRST_RETRY * 2_i32.saturating_pow(failures.saturating_sub(1).min(16));
            SourceState {
                source_id: source.id,
                last_run_at: Some(now),
                next_run_at: now + backoff.min(interval),
                consecutive_failures: failures,
                last_error: Some(error.to_string()),
                last_new_items: previous.map_or(0, |s| s.last_new_items),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::sync::Mutex;

    use async_trait::async_trait;
    use bento_domain::RawItem;
    use futures::executor::block_on;

    use super::*;
    use crate::ingest::tests::{FakeOutbox, FixedClock};

    #[derive(Default)]
    struct FakeStates(RefCell<HashMap<Uuid, SourceState>>, RefCell<Vec<RunRecord>>);

    impl SourceStateStore for FakeStates {
        fn source_state(&self, id: Uuid) -> Result<Option<SourceState>, PortError> {
            Ok(self.0.borrow().get(&id).cloned())
        }
        fn save_source_state(&self, state: &SourceState) -> Result<(), PortError> {
            self.0.borrow_mut().insert(state.source_id, state.clone());
            Ok(())
        }
        fn record_run(&self, run: &RunRecord) -> Result<(), PortError> {
            self.1.borrow_mut().push(run.clone());
            Ok(())
        }
    }

    /// Returns queued results in order; counts calls.
    struct FakeFetcher {
        results: Mutex<Vec<Result<Vec<RawItem>, String>>>,
        calls: Mutex<usize>,
    }

    impl FakeFetcher {
        fn new(results: Vec<Result<Vec<RawItem>, String>>) -> Arc<Self> {
            Arc::new(Self {
                results: Mutex::new(results),
                calls: Mutex::new(0),
            })
        }
        fn calls(&self) -> usize {
            *self.calls.lock().unwrap()
        }
    }

    #[async_trait]
    impl SourceFetcher for FakeFetcher {
        async fn fetch(&self, _: &SourceConfig) -> Result<Vec<RawItem>, PortError> {
            *self.calls.lock().unwrap() += 1;
            self.results
                .lock()
                .unwrap()
                .remove(0)
                .map_err(PortError::msg)
        }
    }

    fn source(id: u128, plugin: &str, enabled: bool) -> SourceConfig {
        SourceConfig {
            id: Uuid::from_u128(id),
            plugin_id: plugin.into(),
            name: format!("s{id}"),
            query: "q".into(),
            settings: serde_json::Map::new(),
            interval_minutes: 30,
            enabled,
            translate: false,
            summarize: false,
            fetch_detail: false,
        }
    }

    fn config(sources: Vec<SourceConfig>) -> CollectorConfig {
        CollectorConfig {
            sources,
            ..CollectorConfig::default()
        }
    }

    fn items(ids: &[&str]) -> Vec<RawItem> {
        ids.iter()
            .map(|id| RawItem {
                external_id: (*id).into(),
                ..Default::default()
            })
            .collect()
    }

    fn registry(fetcher: Arc<FakeFetcher>) -> FetcherRegistry {
        HashMap::from([("rss".to_string(), fetcher as Arc<dyn SourceFetcher>)])
    }

    #[test]
    fn runs_new_source_then_waits_for_its_interval() {
        let fetcher = FakeFetcher::new(vec![Ok(items(&["a", "b"])), Ok(items(&["b", "c"]))]);
        let (states, outbox, clock) = (
            FakeStates::default(),
            FakeOutbox::default(),
            FixedClock::at(9),
        );
        let scheduler = Scheduler::new(registry(fetcher.clone()), &states, &outbox, &clock);
        let cfg = config(vec![source(1, "rss", true)]);

        let first = block_on(scheduler.run_due(&cfg)).unwrap();
        assert_eq!(first[0].outcome.as_ref().unwrap().written, 2);
        let run = states.1.borrow()[0].clone();
        assert_eq!((run.fetched, run.new_items, run.error), (2, 2, None));

        *clock.0.borrow_mut() += Duration::minutes(29);
        assert!(block_on(scheduler.run_due(&cfg)).unwrap().is_empty());

        *clock.0.borrow_mut() += Duration::minutes(1);
        let third = block_on(scheduler.run_due(&cfg)).unwrap();
        assert_eq!(
            third[0].outcome.as_ref().unwrap().written,
            1,
            "only c is new"
        );
        assert_eq!(fetcher.calls(), 2);
    }

    #[test]
    fn skips_disabled_sources() {
        let fetcher = FakeFetcher::new(vec![]);
        let (states, outbox) = (FakeStates::default(), FakeOutbox::default());
        let scheduler = Scheduler::new(
            registry(fetcher.clone()),
            &states,
            &outbox,
            FixedClock::at(9),
        );

        let reports = block_on(scheduler.run_due(&config(vec![source(1, "rss", false)]))).unwrap();

        assert!(reports.is_empty());
        assert_eq!(fetcher.calls(), 0);
    }

    #[test]
    fn backs_off_after_failures_up_to_the_interval() {
        let fetcher = FakeFetcher::new(vec![Err("timeout".into()); 8]);
        let (states, outbox, clock) = (
            FakeStates::default(),
            FakeOutbox::default(),
            FixedClock::at(9),
        );
        let scheduler = Scheduler::new(registry(fetcher), &states, &outbox, &clock);
        let cfg = config(vec![source(1, "rss", true)]);

        let mut delays = Vec::new();
        for _ in 0..7 {
            block_on(scheduler.run_due(&cfg)).unwrap();
            let state = states.source_state(Uuid::from_u128(1)).unwrap().unwrap();
            delays.push((state.next_run_at - clock.now()).num_minutes());
            *clock.0.borrow_mut() = state.next_run_at;
        }

        assert_eq!(delays, [1, 2, 4, 8, 16, 30, 30]);
        let state = states.source_state(Uuid::from_u128(1)).unwrap().unwrap();
        assert_eq!(state.consecutive_failures, 7);
        assert_eq!(state.last_error.as_deref(), Some("timeout"));
        let runs = states.1.borrow();
        assert_eq!(runs.len(), 7);
        assert_eq!(runs[0].error.as_deref(), Some("timeout"));
        assert_eq!(
            runs[1].started_at - runs[0].started_at,
            Duration::minutes(1)
        );
    }

    #[test]
    fn success_clears_failures() {
        let fetcher = FakeFetcher::new(vec![Err("x".into()), Ok(items(&["a"]))]);
        let (states, outbox, clock) = (
            FakeStates::default(),
            FakeOutbox::default(),
            FixedClock::at(9),
        );
        let scheduler = Scheduler::new(registry(fetcher), &states, &outbox, &clock);
        let cfg = config(vec![source(1, "rss", true)]);
        block_on(scheduler.run_due(&cfg)).unwrap();
        *clock.0.borrow_mut() += Duration::minutes(1);

        block_on(scheduler.run_due(&cfg)).unwrap();

        let state = states.source_state(Uuid::from_u128(1)).unwrap().unwrap();
        assert_eq!(
            (
                state.consecutive_failures,
                state.last_error,
                state.last_new_items
            ),
            (0, None, 1)
        );
    }

    #[test]
    fn unknown_plugin_is_recorded_as_a_failure() {
        let (states, outbox) = (FakeStates::default(), FakeOutbox::default());
        let scheduler = Scheduler::new(FetcherRegistry::new(), &states, &outbox, FixedClock::at(9));

        let reports = block_on(scheduler.run_due(&config(vec![source(1, "x", true)]))).unwrap();

        assert_eq!(
            reports[0].outcome.as_ref().unwrap_err().to_string(),
            "no plugin named 'x'"
        );
        assert!(
            states
                .source_state(Uuid::from_u128(1))
                .unwrap()
                .unwrap()
                .last_error
                .is_some()
        );
    }
}
