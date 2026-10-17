//! Plugin secrets in the macOS Keychain, as generic passwords owned by `bento-collector`.
//!
//! When the daemon is signed with Bento's keychain access group (a build with a developer team),
//! secrets are iCloud Keychain items: synchronizable, readable after the first unlock so the
//! daemon works while the screen is locked, and shared with the user's other Macs, so any of them
//! can take over collecting without signing in again. Without the entitlement (an ad-hoc build)
//! they stay in the local login keychain.
//!
//! The app never reads values: it hands them to `bento-collector secrets set` on stdin.

use std::sync::OnceLock;

use bento_app::{PortError, SecretStore};
use security_framework::access_control::{ProtectionMode, SecAccessControl};
use security_framework::passwords::{
    delete_generic_password_options, generic_password, set_generic_password_options,
};
use security_framework::passwords_options::PasswordOptions;

/// `errSecItemNotFound`.
const ITEM_NOT_FOUND: i32 = -25300;
/// `errSecMissingEntitlement`: the binary has no keychain access group, so no iCloud Keychain.
const MISSING_ENTITLEMENT: i32 = -34018;

/// Where secrets are kept.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    /// iCloud Keychain, shared with the user's other Macs.
    Synced,
    /// The login keychain on this Mac only.
    Local,
}

pub struct KeychainSecrets {
    service: String,
    backend: OnceLock<Backend>,
}

impl Default for KeychainSecrets {
    fn default() -> Self {
        Self::with_service("io.github.alexcding.bento.plugin-secrets")
    }
}

impl KeychainSecrets {
    /// A store under a different service name, for tests.
    #[must_use]
    pub fn with_service(service: impl Into<String>) -> Self {
        Self {
            service: service.into(),
            backend: OnceLock::new(),
        }
    }

    fn account(plugin_id: &str, key: &str) -> String {
        format!("{plugin_id}.{key}")
    }

    fn local(&self, account: &str) -> PasswordOptions {
        PasswordOptions::new_generic_password(&self.service, account)
    }

    fn synced(&self, account: &str) -> PasswordOptions {
        let mut options = PasswordOptions::new_generic_password(&self.service, account);
        options.use_protected_keychain();
        options.set_access_synchronized(Some(true));
        options
    }

    /// Whether this binary can use iCloud Keychain. A lookup cannot tell (it finds nothing either
    /// way), so the first call writes and removes a probe item in the same protected keychain,
    /// but device-only so the probe never syncs.
    pub fn backend(&self) -> Result<Backend, PortError> {
        if let Some(backend) = self.backend.get() {
            return Ok(*backend);
        }
        let probe = || {
            let mut options = PasswordOptions::new_generic_password(&self.service, "probe");
            options.use_protected_keychain();
            options.set_access_synchronized(Some(false));
            options
        };
        // Readable after the first unlock like the real items, so a daemon restarted while the
        // screen is locked still finds its backend.
        let mut write = probe();
        write.set_access_control(
            SecAccessControl::create_with_protection(
                Some(ProtectionMode::AccessibleAfterFirstUnlockThisDeviceOnly),
                0,
            )
            .map_err(PortError::new)?,
        );
        // A probe left by an interrupted run would turn the add into an update; without the
        // entitlement this delete fails too, which the add then reports.
        let _ = delete_generic_password_options(probe());
        let backend = match set_generic_password_options(b"1", write) {
            Ok(()) => {
                ignore_missing(delete_generic_password_options(probe()))?;
                Backend::Synced
            }
            Err(error) if error.code() == MISSING_ENTITLEMENT => Backend::Local,
            Err(error) => return Err(PortError::new(error)),
        };
        Ok(*self.backend.get_or_init(|| backend))
    }

    pub fn set(&self, plugin_id: &str, key: &str, value: &str) -> Result<(), PortError> {
        let account = Self::account(plugin_id, key);
        match self.backend()? {
            Backend::Local => set_generic_password_options(value.as_bytes(), self.local(&account))
                .map_err(PortError::new),
            Backend::Synced => self.write_synced(&account, value),
        }
    }

    /// Replaces a synced item. Deleting first keeps its accessibility and sync attributes out of
    /// an update query, which the Keychain refuses.
    fn write_synced(&self, account: &str, value: &str) -> Result<(), PortError> {
        ignore_missing(delete_generic_password_options(self.synced(account)))?;
        let mut options = self.synced(account);
        let access = SecAccessControl::create_with_protection(
            Some(ProtectionMode::AccessibleAfterFirstUnlock),
            0,
        )
        .map_err(PortError::new)?;
        options.set_access_control(access);
        set_generic_password_options(value.as_bytes(), options).map_err(PortError::new)
    }

    /// Removes a secret; removing one that is not set is not an error.
    pub fn delete(&self, plugin_id: &str, key: &str) -> Result<(), PortError> {
        let account = Self::account(plugin_id, key);
        ignore_missing(delete_generic_password_options(match self.backend()? {
            Backend::Synced => self.synced(&account),
            Backend::Local => self.local(&account),
        }))
    }
}

fn ignore_missing(result: security_framework::base::Result<()>) -> Result<(), PortError> {
    match result {
        Err(error) if error.code() != ITEM_NOT_FOUND => Err(PortError::new(error)),
        _ => Ok(()),
    }
}

fn found(result: security_framework::base::Result<Vec<u8>>) -> Result<Option<String>, PortError> {
    match result {
        Ok(bytes) => String::from_utf8(bytes).map(Some).map_err(PortError::new),
        Err(error) if error.code() == ITEM_NOT_FOUND => Ok(None),
        Err(error) => Err(PortError::new(error)),
    }
}

impl SecretStore for KeychainSecrets {
    fn secret(&self, plugin_id: &str, key: &str) -> Result<Option<String>, PortError> {
        let account = Self::account(plugin_id, key);
        found(generic_password(match self.backend()? {
            Backend::Synced => self.synced(&account),
            Backend::Local => self.local(&account),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Touches the real keychain, so it only runs on request:
    /// `cargo test -p bento-secrets-keychain -- --ignored`. An unsigned test binary has no
    /// keychain access group, so this exercises the local backend.
    #[test]
    #[ignore = "uses the login keychain"]
    fn round_trips_through_the_keychain() {
        let store = KeychainSecrets::with_service("io.github.alexcding.bento.tests");
        assert_eq!(store.backend().unwrap(), Backend::Local);
        store.delete("p", "k").unwrap();
        assert_eq!(store.secret("p", "k").unwrap(), None);

        store.set("p", "k", "v1").unwrap();
        store.set("p", "k", "v2").unwrap();
        assert_eq!(store.secret("p", "k").unwrap().as_deref(), Some("v2"));

        store.delete("p", "k").unwrap();
        store.delete("p", "k").unwrap();
        assert_eq!(store.secret("p", "k").unwrap(), None);
    }
}
