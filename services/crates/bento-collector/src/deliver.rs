//! The delivery loop: posts new items to destinations alongside the scheduler, so a slow source
//! run never holds posts back.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use bento_app::{Deliverer, DeliveryOutcome, SecretStore, SystemClock};
use bento_domain::CollectorConfig;
use bento_publish::{Publishers, TELEGRAM_API};
use bento_store_sqlite::SqliteStore;
use tokio::sync::watch;
use tokio::task::JoinHandle;

use crate::config_file::ConfigFile;

const TICK: Duration = Duration::from_secs(2);
const SEND_TIMEOUT: Duration = Duration::from_secs(30);

/// Runs until `shutdown` turns true. No new post starts after that; one already in flight is
/// recorded when it finishes, or, if the process exits first, marked failed on the next start.
pub fn spawn(
    data_dir: &Path,
    store: Arc<SqliteStore>,
    secrets: Arc<dyn SecretStore>,
    mut shutdown: watch::Receiver<bool>,
) -> JoinHandle<()> {
    let mut config_file = ConfigFile::new(data_dir.join("collector-config.json"));
    let publishers = Arc::new(Publishers::new(secrets, TELEGRAM_API, SEND_TIMEOUT));
    tokio::spawn(async move {
        let deliverer = match Deliverer::new(store, publishers, SystemClock) {
            Ok(deliverer) => deliverer,
            Err(error) => {
                tracing::error!(%error, "posting is off: the delivery queue cannot be read");
                return;
            }
        };
        let mut config = CollectorConfig::default();
        // Nothing is sent before a config loads: with none, every destination would look removed.
        let mut loaded = false;
        while !*shutdown.borrow() {
            loaded |= crate::reload(&mut config_file, &mut config);
            if !loaded {
                tokio::select! {
                    _ = shutdown.changed() => {}
                    () = tokio::time::sleep(TICK) => {}
                }
                continue;
            }
            if let Err(error) = deliverer.plan(&config) {
                tracing::error!(%error, "queuing posts failed");
            }
            let stopping = shutdown.clone();
            match deliverer
                .send_due(&config, &move || !*stopping.borrow())
                .await
            {
                Ok(reports) => {
                    for report in reports {
                        match report.outcome {
                            DeliveryOutcome::Sent => {
                                tracing::info!(destination = report.destination, "posted");
                            }
                            DeliveryOutcome::Retry { error, at, .. } => tracing::warn!(
                                destination = report.destination,
                                %error,
                                retry_at = %at,
                                "post failed; will retry"
                            ),
                            DeliveryOutcome::Failed(error) => tracing::error!(
                                destination = report.destination,
                                %error,
                                "post failed"
                            ),
                        }
                    }
                }
                Err(error) => tracing::error!(%error, "sending posts failed"),
            }
            tokio::select! {
                _ = shutdown.changed() => {}
                () = tokio::time::sleep(TICK) => {}
            }
        }
    })
}
