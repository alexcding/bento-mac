//! Plugin secrets in the macOS Keychain, as generic passwords owned by `bento-collector`.
//!
//! The app never reads values: it hands them to `bento-collector secrets set` on stdin, so the
//! daemon's own binary creates (and can read back) every item without access prompts.

use bento_app::{PortError, SecretStore};
use security_framework::passwords::{
    delete_generic_password, get_generic_password, set_generic_password,
};

/// `errSecItemNotFound`.
const ITEM_NOT_FOUND: i32 = -25300;

pub struct KeychainSecrets {
    service: String,
}

impl Default for KeychainSecrets {
    fn default() -> Self {
        Self {
            service: "io.github.alexcding.bento.plugin-secrets".into(),
        }
    }
}

impl KeychainSecrets {
    /// A store under a different service name, for tests.
    #[must_use]
    pub fn with_service(service: impl Into<String>) -> Self {
        Self {
            service: service.into(),
        }
    }

    fn account(plugin_id: &str, key: &str) -> String {
        format!("{plugin_id}.{key}")
    }

    pub fn set(&self, plugin_id: &str, key: &str, value: &str) -> Result<(), PortError> {
        set_generic_password(
            &self.service,
            &Self::account(plugin_id, key),
            value.as_bytes(),
        )
        .map_err(PortError::new)
    }

    /// Removes a secret; removing one that is not set is not an error.
    pub fn delete(&self, plugin_id: &str, key: &str) -> Result<(), PortError> {
        match delete_generic_password(&self.service, &Self::account(plugin_id, key)) {
            Err(error) if error.code() != ITEM_NOT_FOUND => Err(PortError::new(error)),
            _ => Ok(()),
        }
    }
}

impl SecretStore for KeychainSecrets {
    fn secret(&self, plugin_id: &str, key: &str) -> Result<Option<String>, PortError> {
        match get_generic_password(&self.service, &Self::account(plugin_id, key)) {
            Ok(bytes) => String::from_utf8(bytes).map(Some).map_err(PortError::new),
            Err(error) if error.code() == ITEM_NOT_FOUND => Ok(None),
            Err(error) => Err(PortError::new(error)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Touches the real login keychain, so it only runs on request:
    /// `cargo test -p bento-secrets-keychain -- --ignored`.
    #[test]
    #[ignore = "uses the login keychain"]
    fn round_trips_through_the_keychain() {
        let store = KeychainSecrets::with_service("io.github.alexcding.bento.tests");
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
