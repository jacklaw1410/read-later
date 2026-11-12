//! Name conversion shared by every emitter.
//!
//! The JSON writes a role as `group.role` or `group.role-part`. Each platform
//! spells that its own way, and this is the only place that decides how.

/// Splits a role on `.` and `-`.
fn parts(role: &str) -> Vec<&str> {
    role.split(['.', '-'])
        .filter(|part| !part.is_empty())
        .collect()
}

fn upper_first(part: &str) -> String {
    let mut chars = part.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// `page.paper` becomes `pagePaper`. Swift and Kotlin.
pub fn camel(role: &str) -> String {
    let parts = parts(role);
    let mut out = String::new();
    for (index, part) in parts.iter().enumerate() {
        if index == 0 {
            out.push_str(part);
        } else {
            out.push_str(&upper_first(part));
        }
    }
    out
}

/// `page.paper` becomes `PagePaper`. XAML keys.
pub fn pascal(role: &str) -> String {
    parts(role).iter().map(|part| upper_first(part)).collect()
}

/// `page.paper` becomes `page-paper`, `minTarget` becomes `min-target`. CSS
/// custom properties are lower case by convention, and a role written in camel
/// case must not leak a capital into a stylesheet.
pub fn kebab(role: &str) -> String {
    let mut out = String::new();
    for character in role.chars() {
        if character == '.' {
            out.push('-');
        } else if character.is_ascii_uppercase() {
            out.push('-');
            out.push(character.to_ascii_lowercase());
        } else {
            out.push(character);
        }
    }
    out
}

/// `#FFFCF7` becomes `0xFFFCF7`, the form Swift wants.
pub fn hex_arg(value: &str) -> String {
    format!("0x{}", value.trim_start_matches('#').to_uppercase())
}

/// `#FFFCF7` becomes `FFFCF7`, for a caller that adds its own prefix.
pub fn hex_bare(value: &str) -> String {
    value.trim_start_matches('#').to_uppercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn camel_joins_groups() {
        assert_eq!(camel("page.paper"), "pagePaper");
        assert_eq!(camel("mark.savedFill"), "markSavedFill");
        assert_eq!(camel("entry-progress"), "entryProgress");
        assert_eq!(camel("paper"), "paper");
    }

    #[test]
    fn pascal_uppercases_every_group() {
        assert_eq!(pascal("page.paper"), "PagePaper");
        assert_eq!(pascal("veil.scrim"), "VeilScrim");
        assert_eq!(pascal("minTarget"), "MinTarget");
    }

    #[test]
    fn kebab_lowercases_a_camel_case_role() {
        assert_eq!(kebab("wash.fill"), "wash-fill");
        assert_eq!(kebab("page.raised"), "page-raised");
        assert_eq!(kebab("minTarget"), "min-target");
        assert_eq!(kebab("entry-progress"), "entry-progress");
        assert_eq!(kebab("motion.entryProgress"), "motion-entry-progress");
    }

    #[test]
    fn a_hex_keeps_its_digits() {
        assert_eq!(hex_arg("#fffcf7"), "0xFFFCF7");
        assert_eq!(hex_bare("#FFFCF7"), "FFFCF7");
    }
}
