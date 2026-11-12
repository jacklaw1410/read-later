//! Pick the benchmark sample: a deterministic slice of headwords.
//!
//! The rule: order every headword by `key`, set `step` to `row_count / n`
//! (integer division), and take rows at positions `0, step, 2 * step, …`.
//! A rerun against the same index walks the same positions, so the sample is
//! stable. One streaming query does the walk; offsets would rescan the table
//! once per probe.

use rusqlite::Connection;

/// The headwords one benchmark run looks up, in lookup order.
pub struct Sample {
    /// Folded keys, already in `ORDER BY key` order.
    pub keys: Vec<String>,
    /// Every headword in the index.
    pub row_count: usize,
    /// Positions sit `step` rows apart.
    pub step: usize,
    /// FNV-1a over the keys. Two runs match when the checksums match, with
    /// no need to print all 1,000 words.
    pub checksum: u64,
}

/// Select `n` headwords. Fails when `n` is zero or larger than the row count.
pub fn select_keys(conn: &Connection, n: usize) -> Result<Sample, String> {
    let row_count: usize = conn
        .query_row("SELECT COUNT(*) FROM words", [], |row| {
            row.get::<_, i64>(0)
        })
        .map_err(|e| format!("cannot count headwords: {e}"))?
        as usize;
    if n == 0 {
        return Err("lookups must be at least 1".to_owned());
    }
    if n > row_count {
        return Err(format!(
            "lookups ({n}) exceed the headword count ({row_count})"
        ));
    }
    let step = row_count / n;
    let mut stmt = conn
        .prepare("SELECT key FROM words ORDER BY key")
        .map_err(|e| format!("cannot read headwords: {e}"))?;
    let mut keys = Vec::with_capacity(n);
    let rows = stmt
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(|e| format!("cannot read headwords: {e}"))?;
    for (position, key) in rows.enumerate() {
        let key: String = key.map_err(|e| format!("cannot read headwords: {e}"))?;
        if position % step == 0 {
            keys.push(key);
            if keys.len() == n {
                break;
            }
        }
    }
    debug_assert_eq!(keys.len(), n);
    let checksum = checksum_keys(&keys);
    Ok(Sample {
        keys,
        row_count,
        step,
        checksum,
    })
}

fn checksum_keys(keys: &[String]) -> u64 {
    // FNV-1a, 64 bit. A std fingerprint with no extra crate.
    let mut hash: u64 = 0xcbf29ce484222325;
    for key in keys {
        for byte in key.as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        hash ^= 0xff;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

#[cfg(test)]
pub mod tests {
    use super::select_keys;
    use rusqlite::Connection;

    pub fn fixture(rows: usize) -> Connection {
        let conn = Connection::open_in_memory().expect("memory database opens");
        conn.execute(
            "CREATE TABLE words(key TEXT PRIMARY KEY, word TEXT NOT NULL, phonetic TEXT, pos TEXT, gloss TEXT NOT NULL)",
            [],
        )
        .expect("schema applies");
        // Keys sort in insertion order here (`k00` …), so positions are known.
        for i in 0..rows {
            let key = format!("k{i:02}");
            conn.execute(
                "INSERT INTO words(key, word, phonetic, pos, gloss) VALUES(?, ?, NULL, NULL, ?)",
                rusqlite::params![key, key, "a gloss"],
            )
            .expect("row inserts");
        }
        conn
    }

    #[test]
    fn picks_every_kth_key_in_order() {
        let conn = fixture(10);
        let sample = select_keys(&conn, 5).expect("5 of 10 works");
        assert_eq!(sample.step, 2);
        assert_eq!(sample.keys, vec!["k00", "k02", "k04", "k06", "k08"]);
    }

    #[test]
    fn sample_is_distinct_and_stable() {
        let conn = fixture(10);
        let first = select_keys(&conn, 4).expect("first call works");
        let second = select_keys(&conn, 4).expect("second call works");
        let mut sorted = first.keys.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), first.keys.len());
        assert_eq!(first.keys, second.keys);
        assert_eq!(first.checksum, second.checksum);
    }

    #[test]
    fn rejects_more_lookups_than_rows() {
        let conn = fixture(3);
        assert!(select_keys(&conn, 4).is_err());
        assert!(select_keys(&conn, 0).is_err());
        assert!(select_keys(&conn, 3).is_ok());
    }
}
