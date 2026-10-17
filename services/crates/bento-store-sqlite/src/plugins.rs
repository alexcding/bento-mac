use rusqlite::params;

use crate::{SqliteStore, StoreError};

/// One row of the `plugins` table.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PluginCatalogEntry {
    pub id: String,
    pub name: String,
    pub version: String,
    pub directory: String,
    /// `plugin.json` as JSON.
    pub manifest: String,
    /// JSON array of requirement statuses.
    pub requirements: String,
    pub error: Option<String>,
}

impl SqliteStore {
    /// Replaces the whole catalog in one transaction.
    pub fn replace_plugin_catalog(
        &self,
        entries: &[PluginCatalogEntry],
        updated_at_ms: i64,
    ) -> Result<(), StoreError> {
        let mut connection = self.connection();
        let transaction = connection.transaction()?;
        transaction.execute("DELETE FROM plugins", [])?;
        {
            let mut insert = transaction.prepare_cached(
                "INSERT INTO plugins (id, name, version, directory, manifest, requirements, error, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            )?;
            for e in entries {
                insert.execute(params![
                    e.id,
                    e.name,
                    e.version,
                    e.directory,
                    e.manifest,
                    e.requirements,
                    e.error,
                    updated_at_ms
                ])?;
            }
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn plugin_catalog(&self) -> Result<Vec<PluginCatalogEntry>, StoreError> {
        let connection = self.connection();
        let mut select = connection.prepare_cached(
            "SELECT id, name, version, directory, manifest, requirements, error FROM plugins ORDER BY name",
        )?;
        let rows = select.query_map([], |row| {
            Ok(PluginCatalogEntry {
                id: row.get(0)?,
                name: row.get(1)?,
                version: row.get(2)?,
                directory: row.get(3)?,
                manifest: row.get(4)?,
                requirements: row.get(5)?,
                error: row.get(6)?,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str) -> PluginCatalogEntry {
        PluginCatalogEntry {
            id: id.into(),
            name: id.to_uppercase(),
            version: "1".into(),
            directory: format!("/p/{id}"),
            manifest: "{}".into(),
            requirements: "[]".into(),
            error: None,
        }
    }

    #[test]
    fn replaces_the_whole_catalog() {
        let store = SqliteStore::open_in_memory().unwrap();
        store
            .replace_plugin_catalog(&[entry("a"), entry("b")], 1)
            .unwrap();

        store.replace_plugin_catalog(&[entry("c")], 2).unwrap();

        assert_eq!(store.plugin_catalog().unwrap(), vec![entry("c")]);
    }
}
