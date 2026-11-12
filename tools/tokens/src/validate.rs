//! Checks that run before any file is written.
//!
//! A bad reference must fail the build, not produce a file that a platform
//! compiles into the wrong colour.

use std::collections::{HashMap, HashSet};

use crate::model::{ColorRef, Doc, Roles};

/// Resolves a primitive reference, or names the role that broke.
pub fn resolve<'a>(primitive: &'a Roles<String>, reference: &str) -> Result<&'a str, String> {
    primitive
        .get(reference)
        .map(String::as_str)
        .ok_or_else(|| format!("unknown primitive colour {reference:?}"))
}

pub fn resolve_color<'a>(doc: &'a Doc, value: &ColorRef) -> Result<&'a str, String> {
    resolve(&doc.primitive.color, value.primitive())
}

pub fn validate(doc: &Doc) -> Result<(), String> {
    for (role, entry) in &doc.semantic.color {
        for (mode, value) in [("light", &entry.light), ("dark", &entry.dark)] {
            resolve_color(doc, value).map_err(|error| format!("{role}.{mode}: {error}"))?;
            if let Some(alpha) = value.alpha()
                && !(0.0..=1.0).contains(&alpha)
            {
                return Err(format!("{role}.{mode}: alpha {alpha} is outside 0..1"));
            }
        }
    }

    let swift = &doc.platform.swift.names;
    let mut seen: HashMap<&str, &str> = HashMap::new();
    for role in doc.semantic.color.keys() {
        let symbol = swift
            .get(role)
            .ok_or_else(|| format!("swift binding missing for {role}"))?;
        if let Some(first) = seen.insert(symbol, role) {
            return Err(format!(
                "swift symbol {symbol:?} is used by {first} and {role}"
            ));
        }
    }

    let colour_symbols: HashSet<&str> = swift.values().map(String::as_str).collect();
    for role in doc.semantic.typography.keys() {
        let symbol = doc
            .platform
            .swift
            .font_names
            .get(role)
            .map(String::as_str)
            .unwrap_or(role);
        if colour_symbols.contains(symbol) {
            return Err(format!(
                "type symbol {symbol:?} collides with a colour symbol"
            ));
        }
    }

    for (role, spec) in &doc.semantic.typography {
        if !matches!(
            spec.weight.as_str(),
            "regular" | "medium" | "semibold" | "bold"
        ) {
            return Err(format!("{role}: unknown weight {:?}", spec.weight));
        }
        if !matches!(spec.family.as_str(), "serif" | "sans" | "mono") {
            return Err(format!("{role}: unknown family {:?}", spec.family));
        }
    }

    let body = doc
        .semantic
        .typography
        .get("body")
        .ok_or("typography needs a `body` role")?;
    if body.line.unwrap_or(0) < body.size {
        return Err("body: line box is smaller than the type size".into());
    }

    for (role, spec) in &doc.semantic.motion {
        if !matches!(
            spec.curve.as_str(),
            "linear" | "easeIn" | "easeOut" | "easeInOut"
        ) {
            return Err(format!("{role}: unknown curve {:?}", spec.curve));
        }
    }

    for role in ["minTarget", "maxLineWidth"] {
        if !doc.semantic.size.contains_key(role) {
            return Err(format!("size.{role} is required"));
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(swift_names: &str, colors: &str) -> Doc {
        let json = format!(
            r##"{{
              "primitive": {{ "color": {{ "sand.50": "#FFFCF7", "ink.900": "#191C1F", "white": "#FFFFFF" }} }},
              "semantic": {{
                "color": {colors},
                "typography": {{
                  "body": {{ "family": "serif", "size": 19, "line": 31, "weight": "regular" }}
                }},
                "space": {{ "stackGap": {{ "value": 12, "description": "" }} }},
                "radius": {{ "card": {{ "value": 12, "description": "" }} }},
                "size": {{
                  "minTarget": {{ "value": 44, "description": "" }},
                  "maxLineWidth": {{ "value": 640, "description": "" }}
                }},
                "motion": {{ "wash": {{ "duration": 150, "curve": "linear" }} }}
              }},
              "platform": {{ "swift": {{ "names": {swift_names} }} }}
            }}"##
        );
        Doc::parse(&json).expect("fixture parses")
    }

    const ONE_ROLE: &str =
        r#"{ "page.paper": { "light": "sand.50", "dark": "ink.900", "description": "" } }"#;

    #[test]
    fn a_good_document_passes() {
        let doc = doc(r#"{ "page.paper": "paper" }"#, ONE_ROLE);
        assert!(validate(&doc).is_ok());
    }

    #[test]
    fn a_missing_binding_is_named() {
        let doc = doc("{}", ONE_ROLE);
        let error = validate(&doc).unwrap_err();
        assert!(error.contains("page.paper"), "{error}");
    }

    #[test]
    fn a_duplicate_symbol_is_rejected() {
        let colors = r#"{
          "a.one": { "light": "sand.50", "dark": "ink.900", "description": "" },
          "b.two": { "light": "white", "dark": "white", "description": "" }
        }"#;
        let doc = doc(r#"{ "a.one": "same", "b.two": "same" }"#, colors);
        let error = validate(&doc).unwrap_err();
        assert!(error.contains("same"), "{error}");
    }

    #[test]
    fn an_unknown_primitive_is_rejected() {
        let colors =
            r#"{ "page.paper": { "light": "sand.99", "dark": "ink.900", "description": "" } }"#;
        let doc = doc(r#"{ "page.paper": "paper" }"#, colors);
        let error = validate(&doc).unwrap_err();
        assert!(error.contains("sand.99"), "{error}");
    }

    #[test]
    fn alpha_must_be_a_fraction() {
        let colors = r#"{ "veil.scrim": {
          "light": { "color": "ink.900", "alpha": 1.5 },
          "dark": { "color": "ink.900", "alpha": 0.28 },
          "description": ""
        } }"#;
        let doc = doc(r#"{ "veil.scrim": "scrim" }"#, colors);
        let error = validate(&doc).unwrap_err();
        assert!(error.contains("alpha"), "{error}");
    }
}
