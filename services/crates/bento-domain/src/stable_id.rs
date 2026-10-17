//! Deterministic feed item IDs.
//!
//! An item's ID is a `UUIDv5` of `"<source id>:<external id>"`. The same post therefore gets the
//! same ID on every run and every device, which makes storage and sync idempotent.

use uuid::Uuid;

/// Namespace for feed item IDs. Never change it: every stored ID depends on it.
pub const FEED_ITEM_NAMESPACE: Uuid = Uuid::from_u128(0xf343_3bf7_7680_4fa1_b060_63c0_40a8_6a9a);

#[must_use]
pub fn feed_item_id(source_id: Uuid, external_id: &str) -> Uuid {
    let name = format!("{}:{external_id}", source_id.hyphenated());
    Uuid::new_v5(&FEED_ITEM_NAMESPACE, name.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct Vectors {
        namespace: Uuid,
        stable_ids: Vec<Case>,
    }

    #[derive(Deserialize)]
    struct Case {
        source_id: Uuid,
        external_id: String,
        expected: Uuid,
    }

    fn vectors() -> Vectors {
        serde_json::from_str(include_str!("../../../testdata/vectors.json")).unwrap()
    }

    #[test]
    fn namespace_matches_shared_vectors() {
        assert_eq!(vectors().namespace, FEED_ITEM_NAMESPACE);
    }

    #[test]
    fn ids_match_shared_vectors() {
        for case in vectors().stable_ids {
            assert_eq!(
                feed_item_id(case.source_id, &case.external_id),
                case.expected,
                "{}",
                case.external_id
            );
        }
    }

    #[test]
    fn ids_differ_across_sources() {
        let a = Uuid::from_u128(1);
        let b = Uuid::from_u128(2);
        assert_ne!(feed_item_id(a, "42"), feed_item_id(b, "42"));
    }
}
