//! Fold a headword exactly as `PackIndexStore.normalize` does.
//!
//! The app stores each row under this folded form, so the benchmark must fold
//! the same way or it would measure misses the app never sees.

use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::canonical_combining_class;

/// Lowercase, accent-folded, apostrophe-normalised. `café` and `CAFE` both
/// reach the `cafe` row.
pub fn normalize(word: &str) -> String {
    // NFKD splits `é` into `e` plus a combining mark. Marks carry a
    // non-zero combining class, so the filter below drops them.
    let folded: String = word
        .nfkd()
        .filter(|c| canonical_combining_class(*c) == 0)
        .collect();
    folded
        .replace(['’', '‘'], "'")
        .to_lowercase()
        .trim()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::normalize;

    #[test]
    fn documented_cases_fold_to_the_same_key() {
        assert_eq!(normalize("café"), "cafe");
        assert_eq!(normalize("CAFE"), "cafe");
        assert_eq!(normalize("don’t"), "don't");
    }

    #[test]
    fn trims_and_folds_case() {
        assert_eq!(normalize("  Hello "), "hello");
        assert_eq!(normalize("‘quoted’"), "'quoted'");
    }
}
