//! Enrichment between `prepare` and `append`: article text for sources that want it, then the
//! source's AI tasks. Failures never drop items; an item keeps whatever it already had.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use async_trait::async_trait;
use bento_domain::{
    AiConfig, AiProfile, AiTask, NormalizedItem, OutputTarget, SourceConfig, detail,
};
use chrono::{DateTime, Duration, Utc};
use serde_json::{Value, json};

use crate::ports::{
    AiCall, AiCallRecorder, AiError, AiProvider, AiRequest, Clock, DetailExtractor,
};

/// How long a profile is skipped after an authentication failure.
const AUTH_PAUSE: Duration = Duration::minutes(10);
/// Detail length used when a batch is retried with less context.
const REDUCED_DETAIL_CHARS: usize = 1_500;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EnrichReport {
    pub details_extracted: usize,
    pub detail_failures: usize,
    /// `task: error` for each batch no profile could complete.
    pub ai_failures: Vec<String>,
}

#[async_trait]
pub trait Enricher: Send + Sync {
    async fn enrich(
        &self,
        source: &SourceConfig,
        ai: &AiConfig,
        items: &mut [NormalizedItem],
    ) -> EnrichReport;
}

pub struct Enrichment {
    extractor: Option<Arc<dyn DetailExtractor>>,
    ai: AiRunner,
}

impl Enrichment {
    pub fn new(
        extractor: Option<Arc<dyn DetailExtractor>>,
        provider: Arc<dyn AiProvider>,
        recorder: Arc<dyn AiCallRecorder>,
        clock: Arc<dyn Clock + Send + Sync>,
    ) -> Self {
        Self {
            extractor,
            ai: AiRunner {
                provider,
                recorder,
                clock,
                paused: Mutex::default(),
            },
        }
    }
}

#[async_trait]
impl Enricher for Enrichment {
    async fn enrich(
        &self,
        source: &SourceConfig,
        ai: &AiConfig,
        items: &mut [NormalizedItem],
    ) -> EnrichReport {
        let mut report = EnrichReport::default();
        if source.fetch_detail
            && let Some(extractor) = &self.extractor
        {
            for item in items.iter_mut().filter(|i| i.body_markdown.is_none()) {
                let Some(url) = item.item.url.clone() else {
                    continue;
                };
                match extractor.extract(&url).await {
                    Ok(Some(markdown)) => {
                        item.body_markdown = Some(markdown);
                        report.details_extracted += 1;
                    }
                    Ok(None) => {}
                    Err(_) => report.detail_failures += 1,
                }
            }
        }
        for task_id in source.task_ids() {
            let Some(task) = ai.task(task_id) else {
                report.ai_failures.push(format!("{task_id}: no such task"));
                continue;
            };
            let profiles = ai.profiles_for(&task);
            if profiles.is_empty() {
                report
                    .ai_failures
                    .push(format!("{task_id}: no AI profile configured"));
                continue;
            }
            report
                .ai_failures
                .extend(self.ai.run(&task, &profiles, items).await);
        }
        report
    }
}

/// Runs AI tasks over items in batches, trying each profile in order.
struct AiRunner {
    provider: Arc<dyn AiProvider>,
    recorder: Arc<dyn AiCallRecorder>,
    clock: Arc<dyn Clock + Send + Sync>,
    /// Profile ID → skipped until.
    paused: Mutex<HashMap<String, DateTime<Utc>>>,
}

impl AiRunner {
    /// Fills `task`'s outputs on `items`. Returns one `task: error` per batch that failed.
    async fn run(
        &self,
        task: &AiTask,
        profiles: &[&AiProfile],
        items: &mut [NormalizedItem],
    ) -> Vec<String> {
        let mut failures = Vec::new();
        for range in batches(task, items) {
            let batch = &mut items[range];
            let first = self
                .complete(task, profiles, &request(task, batch, None))
                .await;
            let error = match first {
                Ok(answer) => {
                    apply(task, &answer, batch, Context::Full);
                    continue;
                }
                Err(error) => error,
            };
            let has_long_detail = batch.iter().any(|i| {
                i.body_markdown
                    .as_ref()
                    .is_some_and(|d| d.chars().count() > REDUCED_DETAIL_CHARS)
            });
            // Authentication failures and paused profiles would fail again; shorter input cannot help.
            if has_long_detail
                && error.retryable
                && let Ok(answer) = self
                    .complete(
                        task,
                        profiles,
                        &request(task, batch, Some(REDUCED_DETAIL_CHARS)),
                    )
                    .await
            {
                apply(task, &answer, batch, Context::Reduced);
                continue;
            }
            failures.push(format!("{}: {}", task.id, error.message));
        }
        failures
    }

    async fn complete(
        &self,
        task: &AiTask,
        profiles: &[&AiProfile],
        request: &AiRequest,
    ) -> Result<Value, Failure> {
        let mut failure = Failure {
            message: "every profile is paused after an authentication failure".into(),
            retryable: false,
        };
        let mut first_error = None;
        for profile in profiles {
            let now = self.clock.now();
            if self
                .paused
                .lock()
                .expect("not poisoned")
                .get(&profile.id)
                .is_some_and(|until| *until > now)
            {
                continue;
            }
            let timer = Instant::now();
            let result = self.provider.complete(profile, request).await;
            let call = AiCall {
                started_at: now,
                profile_id: profile.id.clone(),
                task_id: task.id.clone(),
                duration_ms: u64::try_from(timer.elapsed().as_millis()).unwrap_or(u64::MAX),
                items: request.input.matches("\"id\":").count(),
                input_chars: request.input.chars().count(),
                error: result.as_ref().err().map(ToString::to_string),
            };
            let _ = self.recorder.record_ai_call(&call);
            match result {
                Ok(answer) => return Ok(answer),
                Err(error) => {
                    if matches!(error, AiError::Auth(_)) {
                        self.paused
                            .lock()
                            .expect("not poisoned")
                            .insert(profile.id.clone(), now + AUTH_PAUSE);
                    } else {
                        failure.retryable = true;
                    }
                    first_error.get_or_insert_with(|| format!("{}: {error}", profile.name));
                }
            }
        }
        if let Some(message) = first_error {
            failure.message = message;
        }
        Err(failure)
    }
}

/// Why no profile completed a request.
struct Failure {
    /// The first profile error, which is the most informative one.
    message: String,
    /// At least one profile failed for a reason other than authentication.
    retryable: bool,
}

/// Whether the request carried the full detail or a shortened one.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Context {
    Full,
    Reduced,
}

/// Consecutive index ranges holding at most `batch_size` items and, beyond the first item,
/// `max_input_chars` characters of input.
fn batches(task: &AiTask, items: &[NormalizedItem]) -> Vec<std::ops::Range<usize>> {
    let mut ranges = Vec::new();
    let mut start = 0;
    let mut chars = 0;
    for (index, item) in items.iter().enumerate() {
        let size = input_entry(item, None).to_string().chars().count();
        let full = index - start >= task.batch_size.max(1)
            || (index > start && chars + size > task.max_input_chars);
        if full {
            ranges.push(start..index);
            start = index;
            chars = 0;
        }
        chars += size;
    }
    if start < items.len() {
        ranges.push(start..items.len());
    }
    ranges
}

fn input_entry(item: &NormalizedItem, detail_limit: Option<usize>) -> Value {
    let detail = item.body_markdown.as_deref().map(|d| match detail_limit {
        Some(limit) => detail::truncate_chars(d, limit).to_owned(),
        None => d.to_owned(),
    });
    json!({
        "id": item.item.id.to_string(),
        "title": item.item.title,
        "text": item.item.text,
        "detail": detail,
        "url": item.item.url,
        "language": item.item.language,
    })
}

fn request(task: &AiTask, batch: &[NormalizedItem], detail_limit: Option<usize>) -> AiRequest {
    let input: Vec<Value> = batch.iter().map(|i| input_entry(i, detail_limit)).collect();
    AiRequest {
        instructions: format!(
            "{}\n\nThe input is a JSON array of items. Answer with JSON that matches the schema: one entry \
             per input item, with the item's id.",
            task.instructions
        ),
        input: Value::Array(input).to_string(),
        schema: schema(task),
    }
}

/// `{"items": [{"id", <output names>…}]}`, every field required, no others.
fn schema(task: &AiTask) -> Value {
    let mut properties = serde_json::Map::from_iter([("id".to_owned(), json!({"type": "string"}))]);
    let mut required = vec![json!("id")];
    for output in &task.outputs {
        properties.insert(
            output.name.clone(),
            json!({"type": "string", "description": output.description}),
        );
        required.push(json!(output.name));
    }
    json!({
        "type": "object",
        "properties": {"items": {"type": "array", "items": {
            "type": "object", "properties": properties, "required": required, "additionalProperties": false
        }}},
        "required": ["items"],
        "additionalProperties": false
    })
}

/// Writes answers into the batch. A `Detail` output from a shortened request is dropped, so the
/// full detail is never replaced by a version of its first part.
fn apply(task: &AiTask, answer: &Value, batch: &mut [NormalizedItem], context: Context) {
    let Some(entries) = answer.get("items").and_then(Value::as_array) else {
        return;
    };
    for entry in entries {
        let Some(item) = entry
            .get("id")
            .and_then(Value::as_str)
            .and_then(|id| batch.iter_mut().find(|i| i.item.id.to_string() == id))
        else {
            continue;
        };
        for output in &task.outputs {
            let Some(value) = entry
                .get(&output.name)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|v| !v.is_empty())
            else {
                continue;
            };
            let value = value.to_owned();
            match output.target {
                OutputTarget::TranslatedTitle => item.item.translated_title = Some(value),
                OutputTarget::Summary => item.item.summary = Some(value),
                OutputTarget::Text => item.item.text = value,
                OutputTarget::Detail if context == Context::Reduced => {}
                OutputTarget::Detail => item.body_markdown = Some(value),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use bento_domain::ai::{
        SUMMARIZE_TASK as SUMMARIZE_TASK_ID, TRANSLATE_TASK as TRANSLATE_TASK_ID,
    };
    use bento_domain::{AiProfileKind, RawItem};
    use futures::executor::block_on;
    use uuid::Uuid;

    use super::*;
    use crate::ingest::tests::FixedClock;
    use crate::ports::PortError;

    /// Scripted provider: answers per profile ID, records requests.
    #[derive(Default)]
    struct FakeProvider {
        failures: HashMap<String, AiError>,
        requests: Mutex<Vec<(String, AiRequest)>>,
        /// Fail every request whose input is longer than this.
        max_input: Option<usize>,
    }

    #[async_trait]
    impl AiProvider for FakeProvider {
        async fn complete(
            &self,
            profile: &AiProfile,
            request: &AiRequest,
        ) -> Result<Value, AiError> {
            self.requests
                .lock()
                .unwrap()
                .push((profile.id.clone(), request.clone()));
            if let Some(error) = self.failures.get(&profile.id) {
                return Err(match error {
                    AiError::Auth(m) => AiError::Auth(m.clone()),
                    AiError::Failed(m) => AiError::Failed(m.clone()),
                });
            }
            if self.max_input.is_some_and(|max| request.input.len() > max) {
                return Err(AiError::Failed("context too long".into()));
            }
            let input: Vec<Value> = serde_json::from_str(&request.input).unwrap();
            let items: Vec<Value> = input
                .iter()
                .map(|i| {
                    let detail = if i["detail"].is_null() {
                        ""
                    } else {
                        "translated detail"
                    };
                    json!({"id": i["id"], "title": format!("T:{}", i["text"].as_str().unwrap()),
                                "detail": detail, "summary": format!("S by {}", profile.id)})
                })
                .collect();
            Ok(json!({"items": items}))
        }
    }

    #[derive(Default)]
    struct Calls(Mutex<Vec<AiCall>>);

    impl AiCallRecorder for Calls {
        fn record_ai_call(&self, call: &AiCall) -> Result<(), PortError> {
            self.0.lock().unwrap().push(call.clone());
            Ok(())
        }
    }

    struct SyncClock(DateTime<Utc>);
    impl Clock for SyncClock {
        fn now(&self) -> DateTime<Utc> {
            self.0
        }
    }

    fn profile(id: &str) -> AiProfile {
        AiProfile {
            id: id.into(),
            name: id.into(),
            kind: AiProfileKind::Http {
                base_url: "https://x".into(),
            },
            model: None,
            timeout_seconds: 5,
        }
    }

    fn items(texts: &[&str]) -> Vec<NormalizedItem> {
        let at = FixedClock::at(9).now();
        texts
            .iter()
            .flat_map(|t| {
                RawItem {
                    external_id: (*t).into(),
                    text: (*t).into(),
                    ..Default::default()
                }
                .normalize(Uuid::from_u128(1), at)
            })
            .collect()
    }

    fn source(translate: bool, summarize: bool) -> SourceConfig {
        serde_json::from_value(json!({
            "id": Uuid::from_u128(1), "plugin_id": "rss", "name": "s", "query": "q", "interval_minutes": 30,
            "enabled": true, "translate": translate, "summarize": summarize
        }))
        .unwrap()
    }

    fn enrichment(provider: Arc<FakeProvider>, calls: Arc<Calls>) -> Enrichment {
        Enrichment::new(
            None,
            provider,
            calls,
            Arc::new(SyncClock(FixedClock::at(9).now())),
        )
    }

    fn ai(profiles: &[&str]) -> AiConfig {
        AiConfig {
            profiles: profiles.iter().map(|p| profile(p)).collect(),
            tasks: vec![],
        }
    }

    #[test]
    fn runs_switched_on_presets_and_fills_fields() {
        let provider = Arc::new(FakeProvider::default());
        let calls = Arc::new(Calls::default());
        let mut batch = items(&["a", "b", "c"]);

        let report = block_on(enrichment(provider.clone(), calls.clone()).enrich(
            &source(true, true),
            &ai(&["p"]),
            &mut batch,
        ));

        assert!(report.ai_failures.is_empty(), "{:?}", report.ai_failures);
        assert_eq!(batch[2].item.translated_title.as_deref(), Some("T:c"));
        assert_eq!(batch[0].item.summary.as_deref(), Some("S by p"));
        assert_eq!(
            batch[0].body_markdown, None,
            "empty answers leave fields unchanged"
        );
        // translate: batches of 2 → 2 calls; summarize: batch of 4 → 1 call.
        assert_eq!(calls.0.lock().unwrap().len(), 3);
        let first = &provider.requests.lock().unwrap()[0].1;
        assert_eq!(
            first.schema["properties"]["items"]["items"]["required"],
            json!(["id", "title", "detail"])
        );
    }

    #[test]
    fn falls_back_and_pauses_profiles_after_auth_failure() {
        let provider = Arc::new(FakeProvider {
            failures: HashMap::from([("main".to_owned(), AiError::Auth("401".into()))]),
            ..Default::default()
        });
        let calls = Arc::new(Calls::default());
        let mut config = ai(&["main", "backup"]);
        let mut task = config.task(SUMMARIZE_TASK_ID).unwrap();
        task.profile = "main".into();
        task.fallback = vec!["backup".into()];
        task.batch_size = 1;
        config.tasks.push(task);
        let mut batch = items(&["a", "b"]);

        block_on(enrichment(provider.clone(), calls).enrich(
            &source(false, true),
            &config,
            &mut batch,
        ));

        assert_eq!(batch[1].item.summary.as_deref(), Some("S by backup"));
        let tried: Vec<String> = provider
            .requests
            .lock()
            .unwrap()
            .iter()
            .map(|(p, _)| p.clone())
            .collect();
        assert_eq!(
            tried,
            ["main", "backup", "backup"],
            "main is paused after its auth failure"
        );
    }

    #[test]
    fn retries_with_reduced_detail_then_keeps_source_text_on_failure() {
        let provider = Arc::new(FakeProvider {
            max_input: Some(2_000),
            ..Default::default()
        });
        let mut batch = items(&["a"]);
        batch[0].body_markdown = Some("x".repeat(5_000));

        let report = block_on(
            enrichment(provider.clone(), Arc::new(Calls::default())).enrich(
                &source(true, false),
                &ai(&["p"]),
                &mut batch,
            ),
        );

        assert!(report.ai_failures.is_empty());
        assert_eq!(batch[0].item.translated_title.as_deref(), Some("T:a"));
        assert_eq!(
            provider.requests.lock().unwrap().len(),
            2,
            "full context, then reduced"
        );

        let failing = Arc::new(FakeProvider {
            failures: HashMap::from([("p".to_owned(), AiError::Failed("down".into()))]),
            ..Default::default()
        });
        let mut batch = items(&["a"]);
        let report = block_on(enrichment(failing, Arc::new(Calls::default())).enrich(
            &source(true, false),
            &ai(&["p"]),
            &mut batch,
        ));
        assert_eq!(report.ai_failures, ["translate: p: down"]);
        assert_eq!(batch[0].item.translated_title, None);
    }

    #[test]
    fn full_answers_replace_the_detail() {
        let provider = Arc::new(FakeProvider::default());
        let mut batch = items(&["a"]);
        batch[0].body_markdown = Some("short original".into());

        block_on(enrichment(provider, Arc::new(Calls::default())).enrich(
            &source(true, false),
            &ai(&["p"]),
            &mut batch,
        ));

        assert_eq!(batch[0].body_markdown.as_deref(), Some("translated detail"));
    }

    #[test]
    fn auth_failures_skip_the_retry_and_report_the_real_error() {
        let provider = Arc::new(FakeProvider {
            failures: HashMap::from([("p".to_owned(), AiError::Auth("HTTP 401: bad key".into()))]),
            ..Default::default()
        });
        let mut batch = items(&["a"]);
        batch[0].body_markdown = Some("x".repeat(5_000));

        let report = block_on(
            enrichment(provider.clone(), Arc::new(Calls::default())).enrich(
                &source(true, false),
                &ai(&["p"]),
                &mut batch,
            ),
        );

        assert_eq!(
            report.ai_failures,
            ["translate: p: authentication failed: HTTP 401: bad key"]
        );
        assert_eq!(
            provider.requests.lock().unwrap().len(),
            1,
            "no reduced retry after an auth failure"
        );
    }

    #[test]
    fn reports_missing_profiles_without_calling_anything() {
        let provider = Arc::new(FakeProvider::default());
        let mut batch = items(&["a"]);

        let report = block_on(
            enrichment(provider.clone(), Arc::new(Calls::default())).enrich(
                &source(true, false),
                &ai(&[]),
                &mut batch,
            ),
        );

        assert_eq!(
            report.ai_failures,
            [format!("{TRANSLATE_TASK_ID}: no AI profile configured")]
        );
        assert!(provider.requests.lock().unwrap().is_empty());
    }

    #[test]
    fn batches_respect_size_and_characters() {
        let mut task = ai(&[]).task(SUMMARIZE_TASK_ID).unwrap();
        task.batch_size = 3;
        task.max_input_chars = 250;
        let mut batch = items(&["a", "b", "c", "d"]);
        batch[1].body_markdown = Some("y".repeat(400));

        let ranges = batches(&task, &batch);

        assert_eq!(
            ranges,
            vec![0..1, 1..2, 2..4],
            "an oversized item travels alone"
        );
    }
}
