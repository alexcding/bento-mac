//! Runs each enabled source when it is due, and records the outcome.

use std::collections::HashMap;
use std::sync::Arc;

use bento_domain::{CollectorConfig, SourceConfig};
use chrono::{DateTime, Datelike, Duration, Utc};
use uuid::Uuid;

use crate::enrich::{EnrichReport, Enricher};
use crate::ingest::{IngestReport, Ingestor, Prepared};
use crate::ports::{
    Clock, Outbox, PortError, RunRecord, SourceFetcher, SourceState, SourceStateStore,
};

/// Fetchers keyed by plugin ID.
pub type FetcherRegistry = HashMap<String, Arc<dyn SourceFetcher>>;

/// Retry delay after the first failure. Doubles per consecutive failure, capped at the source's
/// interval.
const FIRST_RETRY: Duration = Duration::minutes(1);

/// What a run would add, without storing it.
#[derive(Debug)]
pub struct DryRun {
    pub prepared: Prepared,
    pub enrich: EnrichReport,
    /// Posts a first run would mark as seen instead of storing.
    pub backlog_skipped: usize,
}

#[derive(Debug)]
pub struct RunReport {
    pub source_id: Uuid,
    pub outcome: Result<IngestReport, PortError>,
    /// Article and AI results; problems here never fail the run.
    pub enrich: EnrichReport,
}

pub struct Scheduler<S, O, C> {
    fetchers: FetcherRegistry,
    states: S,
    outbox: O,
    clock: C,
    enricher: Option<Arc<dyn Enricher>>,
}

impl<S: SourceStateStore, O: Outbox, C: Clock> Scheduler<S, O, C> {
    pub fn new(fetchers: FetcherRegistry, states: S, outbox: O, clock: C) -> Self {
        Self {
            fetchers,
            states,
            outbox,
            clock,
            enricher: None,
        }
    }

    /// Runs article extraction and AI tasks on new items before they are stored.
    #[must_use]
    pub fn with_enricher(mut self, enricher: Arc<dyn Enricher>) -> Self {
        self.enricher = Some(enricher);
        self
    }

    /// Runs every enabled source whose next run is due, one at a time. Nothing runs on weekends
    /// when the config says so.
    pub async fn run_due(&self, config: &CollectorConfig) -> Result<Vec<RunReport>, PortError> {
        if config.skip_weekends && is_weekend(self.clock.now(), config.utc_offset_minutes) {
            return Ok(Vec::new());
        }
        let mut reports = Vec::new();
        for source in config.sources.iter().filter(|s| s.enabled) {
            let state = self.states.source_state(source.id)?;
            if state
                .as_ref()
                .is_some_and(|s| !is_due(s, source, self.clock.now()))
            {
                continue;
            }
            reports.push(self.run_and_record(source, config, state).await?);
        }
        Ok(reports)
    }

    /// Runs one source now, whatever its schedule (enabled or not), and records the result.
    pub async fn run_now(
        &self,
        source: &SourceConfig,
        config: &CollectorConfig,
    ) -> Result<RunReport, PortError> {
        let state = self.states.source_state(source.id)?;
        self.run_and_record(source, config, state).await
    }

    /// Fetches, filters and enriches one source without storing anything or touching its
    /// schedule: a preview of what the next run would add. A source that would skip its backlog
    /// reports how many posts it would skip instead.
    pub async fn dry_run(
        &self,
        source: &SourceConfig,
        config: &CollectorConfig,
    ) -> Result<DryRun, PortError> {
        let mut prepared = self.fetch_prepared(source, config).await?;
        if source.skip_initial_backlog
            && never_succeeded(self.states.source_state(source.id)?.as_ref())
        {
            let backlog_skipped = prepared.items.len();
            prepared.items.clear();
            return Ok(DryRun {
                prepared,
                enrich: EnrichReport::default(),
                backlog_skipped,
            });
        }
        let enrich = self.enrich(source, config, &mut prepared).await;
        Ok(DryRun {
            prepared,
            enrich,
            backlog_skipped: 0,
        })
    }

    async fn run_and_record(
        &self,
        source: &SourceConfig,
        config: &CollectorConfig,
        state: Option<SourceState>,
    ) -> Result<RunReport, PortError> {
        let started_at = self.clock.now();
        let timer = std::time::Instant::now();
        let mut enrich = EnrichReport::default();
        let outcome = self
            .run(source, config, never_succeeded(state.as_ref()), &mut enrich)
            .await;
        let duration_ms = u64::try_from(timer.elapsed().as_millis()).unwrap_or(u64::MAX);
        self.states
            .record_run(&run_record(source.id, started_at, duration_ms, &outcome))?;
        self.states
            .save_source_state(&next_state(source, state, &outcome, self.clock.now()))?;
        Ok(RunReport {
            source_id: source.id,
            outcome,
            enrich,
        })
    }

    async fn run(
        &self,
        source: &SourceConfig,
        config: &CollectorConfig,
        first_run: bool,
        enrich: &mut EnrichReport,
    ) -> Result<IngestReport, PortError> {
        let mut prepared = self.fetch_prepared(source, config).await?;
        let ingestor = Ingestor::new(&self.outbox, &self.clock);
        if first_run && source.skip_initial_backlog {
            let backlog_skipped = ingestor.skip(&prepared.items)?;
            return Ok(IngestReport {
                fetched: prepared.fetched,
                too_old: prepared.too_old,
                written: 0,
                backlog_skipped,
            });
        }
        *enrich = self.enrich(source, config, &mut prepared).await;
        let written = ingestor.append(prepared.items)?;
        Ok(IngestReport {
            fetched: prepared.fetched,
            too_old: prepared.too_old,
            written,
            backlog_skipped: 0,
        })
    }

    async fn fetch_prepared(
        &self,
        source: &SourceConfig,
        config: &CollectorConfig,
    ) -> Result<Prepared, PortError> {
        let fetcher = self
            .fetchers
            .get(&source.plugin_id)
            .ok_or_else(|| PortError::msg(format!("no plugin named '{}'", source.plugin_id)))?;
        let items = fetcher.fetch(source).await?;
        let max_age = Duration::hours(i64::from(config.max_item_age_hours));
        Ingestor::new(&self.outbox, &self.clock).prepare(source.id, items, max_age)
    }

    async fn enrich(
        &self,
        source: &SourceConfig,
        config: &CollectorConfig,
        prepared: &mut Prepared,
    ) -> EnrichReport {
        match &self.enricher {
            Some(enricher) if !prepared.items.is_empty() => {
                enricher
                    .enrich(source, &config.ai, &mut prepared.items)
                    .await
            }
            _ => EnrichReport::default(),
        }
    }
}

/// A source's first run, for skipping its backlog: no run has ever succeeded (a failed first
/// attempt still counts as not yet run).
fn never_succeeded(state: Option<&SourceState>) -> bool {
    state.is_none_or(|s| s.last_success_at.is_none())
}

/// Saturday or Sunday at `utc_offset_minutes` from UTC.
fn is_weekend(now: DateTime<Utc>, utc_offset_minutes: i32) -> bool {
    let local = now + Duration::minutes(i64::from(utc_offset_minutes));
    matches!(local.weekday(), chrono::Weekday::Sat | chrono::Weekday::Sun)
}

/// Due at `next_run_at`, or sooner when the interval was shortened since the last run: the wait
/// is recomputed from the last run with the current interval (and backoff, after failures).
fn is_due(state: &SourceState, source: &SourceConfig, now: DateTime<Utc>) -> bool {
    let wait = if state.consecutive_failures == 0 {
        interval(source)
    } else {
        backoff(state.consecutive_failures).min(interval(source))
    };
    state.next_run_at <= now || state.last_run_at.is_some_and(|last| last + wait <= now)
}

/// Retry delay after `failures` consecutive failures: 1, 2, 4, … minutes.
fn backoff(failures: u32) -> Duration {
    FIRST_RETRY * 2_i32.saturating_pow(failures.saturating_sub(1).min(16))
}

fn interval(source: &SourceConfig) -> Duration {
    Duration::minutes(i64::from(source.interval_minutes.max(1)))
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
    let interval = interval(source);
    match outcome {
        Ok(report) => SourceState {
            source_id: source.id,
            last_run_at: Some(now),
            next_run_at: now + interval,
            consecutive_failures: 0,
            last_error: None,
            last_new_items: report.written,
            last_success_at: Some(now),
        },
        Err(error) => {
            let failures = previous.as_ref().map_or(0, |s| s.consecutive_failures) + 1;
            SourceState {
                source_id: source.id,
                last_run_at: Some(now),
                next_run_at: now + backoff(failures).min(interval),
                consecutive_failures: failures,
                last_error: Some(error.to_string()),
                last_new_items: previous.as_ref().map_or(0, |s| s.last_new_items),
                last_success_at: previous.and_then(|s| s.last_success_at),
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
            ai_tasks: Vec::new(),
            skip_initial_backlog: false,
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
    fn shortened_interval_applies_without_waiting_for_the_old_one() {
        let fetcher = FakeFetcher::new(vec![Ok(items(&["a"])), Ok(items(&["b"]))]);
        let (states, outbox, clock) = (
            FakeStates::default(),
            FakeOutbox::default(),
            FixedClock::at(9),
        );
        let scheduler = Scheduler::new(registry(fetcher.clone()), &states, &outbox, &clock);
        let mut slow = source(1, "rss", true);
        slow.interval_minutes = 360;
        block_on(scheduler.run_due(&config(vec![slow.clone()]))).unwrap();

        *clock.0.borrow_mut() += Duration::minutes(10);
        slow.interval_minutes = 10;
        block_on(scheduler.run_due(&config(vec![slow]))).unwrap();

        assert_eq!(fetcher.calls(), 2);
    }

    #[test]
    fn shortened_interval_also_cuts_a_long_failure_backoff() {
        let fetcher = FakeFetcher::new(vec![Err("offline".into()); 12]);
        let (states, outbox, clock) = (
            FakeStates::default(),
            FakeOutbox::default(),
            FixedClock::at(9),
        );
        let scheduler = Scheduler::new(registry(fetcher.clone()), &states, &outbox, &clock);
        let mut slow = source(1, "rss", true);
        slow.interval_minutes = 360;
        for _ in 0..10 {
            block_on(scheduler.run_due(&config(vec![slow.clone()]))).unwrap();
            *clock.0.borrow_mut() = states.source_state(slow.id).unwrap().unwrap().next_run_at;
        }
        let calls = fetcher.calls();

        *clock.0.borrow_mut() += Duration::minutes(10) - Duration::minutes(360);
        slow.interval_minutes = 10;
        block_on(scheduler.run_due(&config(vec![slow]))).unwrap();

        assert_eq!(fetcher.calls(), calls + 1);
    }

    #[test]
    fn skips_weekends_in_the_configured_time_zone() {
        let fetcher = FakeFetcher::new(vec![Ok(items(&["a"]))]);
        let (states, outbox) = (FakeStates::default(), FakeOutbox::default());
        // Friday 2026-10-16 23:00 UTC is Saturday 07:00 at UTC+8.
        let clock = FixedClock::at(23);
        let scheduler = Scheduler::new(registry(fetcher.clone()), &states, &outbox, &clock);
        let mut cfg = config(vec![source(1, "rss", true)]);
        cfg.skip_weekends = true;

        cfg.utc_offset_minutes = 8 * 60;
        assert!(block_on(scheduler.run_due(&cfg)).unwrap().is_empty());
        cfg.utc_offset_minutes = 0;
        assert_eq!(
            block_on(scheduler.run_due(&cfg)).unwrap().len(),
            1,
            "still Friday in UTC"
        );
    }

    #[test]
    fn skips_the_initial_backlog_then_collects_new_items() {
        let fetcher = FakeFetcher::new(vec![
            Ok(items(&["old1", "old2"])),
            Ok(items(&["old1", "new"])),
        ]);
        let (states, outbox, clock) = (
            FakeStates::default(),
            FakeOutbox::default(),
            FixedClock::at(9),
        );
        let scheduler = Scheduler::new(registry(fetcher), &states, &outbox, &clock);
        let mut skipping = source(1, "rss", true);
        skipping.skip_initial_backlog = true;
        let cfg = config(vec![skipping]);

        let first = block_on(scheduler.run_due(&cfg)).unwrap();
        assert_eq!(first[0].outcome.as_ref().unwrap().backlog_skipped, 2);
        assert!(outbox.entries.borrow().is_empty());

        *clock.0.borrow_mut() += Duration::minutes(30);
        let second = block_on(scheduler.run_due(&cfg)).unwrap();
        assert_eq!(second[0].outcome.as_ref().unwrap().written, 1);
        assert_eq!(outbox.entries.borrow()[0].item.external_id, "new");
    }

    #[test]
    fn a_failed_first_fetch_still_skips_the_backlog_later_and_preview_says_so() {
        let fetcher = FakeFetcher::new(vec![
            Err("not signed in".into()),
            Ok(items(&["a", "b"])),
            Ok(items(&["a", "b"])),
        ]);
        let (states, outbox, clock) = (
            FakeStates::default(),
            FakeOutbox::default(),
            FixedClock::at(9),
        );
        let scheduler = Scheduler::new(registry(fetcher), &states, &outbox, &clock);
        let mut src = source(1, "rss", true);
        src.skip_initial_backlog = true;
        let cfg = config(vec![src.clone()]);
        block_on(scheduler.run_due(&cfg)).unwrap();

        let preview = block_on(scheduler.dry_run(&src, &cfg)).unwrap();
        assert_eq!(
            (preview.prepared.items.len(), preview.backlog_skipped),
            (0, 2)
        );

        let run = block_on(scheduler.run_now(&src, &cfg)).unwrap();
        assert_eq!(
            run.outcome.unwrap().backlog_skipped,
            2,
            "the failed attempt was not a first run"
        );
        assert!(outbox.entries.borrow().is_empty());
    }

    #[test]
    fn run_now_ignores_the_schedule_and_dry_run_stores_nothing() {
        let fetcher = FakeFetcher::new(vec![
            Ok(items(&["a"])),
            Ok(items(&["b"])),
            Ok(items(&["c"])),
        ]);
        let (states, outbox, clock) = (
            FakeStates::default(),
            FakeOutbox::default(),
            FixedClock::at(9),
        );
        let scheduler = Scheduler::new(registry(fetcher), &states, &outbox, &clock);
        let src = source(1, "rss", true);
        let cfg = config(vec![src.clone()]);
        block_on(scheduler.run_due(&cfg)).unwrap();

        let now = block_on(scheduler.run_now(&src, &cfg)).unwrap();
        assert_eq!(now.outcome.unwrap().written, 1, "not due, ran anyway");

        let runs_before = states.1.borrow().len();
        let preview = block_on(scheduler.dry_run(&src, &cfg)).unwrap();
        assert_eq!(preview.prepared.items[0].item.external_id, "c");
        assert_eq!(outbox.entries.borrow().len(), 2, "dry run stored nothing");
        assert_eq!(states.1.borrow().len(), runs_before, "and recorded no run");
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
