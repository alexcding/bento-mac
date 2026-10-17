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

/// Runs until `shutdown` turns true. A post in flight finishes first, so it is recorded as sent
/// and never posted again.
pub fn spawn(
    data_dir: &Path,
    store: Arc<SqliteStore>,
    secrets: Arc<dyn SecretStore>,
    mut shutdown: watch::Receiver<bool>,
) -> JoinHandle<()> {
    let mut config_file = ConfigFile::new(data_dir.join("collector-config.json"));
    let publishers = Arc::new(Publishers::new(secrets, TELEGRAM_API, SEND_TIMEOUT));
    let deliverer = Deliverer::new(store, publishers, SystemClock);
    tokio::spawn(async move {
        let mut config = CollectorConfig::default();
        while !*shutdown.borrow() {
            crate::reload(&mut config_file, &mut config);
            if let Err(error) = deliverer.plan(&config) {
                tracing::error!(%error, "queuing posts failed");
            }
            match deliverer.send_due(&config).await {
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
