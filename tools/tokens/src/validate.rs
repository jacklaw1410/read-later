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

/// Roles marked `provisional`: a mock value that may ship but must not be
/// forgotten. Every emitter marks them; `--check` prints this list.
pub fn provisional(doc: &Doc) -> Vec<String> {
    let mut out = Vec::new();
    for (role, entry) in &doc.semantic.color {
        if entry.status.as_deref() == Some("provisional") {
            out.push(format!("color.{role}"));
        }
    }
    for (role, spec) in &doc.semantic.typography {
        if spec.status.as_deref() == Some("provisional") {
            out.push(format!("typography.{role}"));
        }
    }
    for (group, roles) in [
        ("space", &doc.semantic.space),
        ("radius", &doc.semantic.radius),
        ("size", &doc.semantic.size),
    ] {
        for (role, spec) in roles {
            if spec.status.as_deref() == Some("provisional") {
                out.push(format!("{group}.{role}"));
            }
        }
    }
    for (role, spec) in &doc.semantic.motion {
        if spec.status.as_deref() == Some("provisional") {
            out.push(format!("motion.{role}"));
        }
    }
    out
}

fn check_status(role: &str, status: Option<&str>) -> Result<(), String> {
    match status {
        None | Some("stable") | Some("provisional") => Ok(()),
        Some(other) => Err(format!("{role}: unknown status {other:?}")),
    }
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

    for (role, entry) in &doc.semantic.color {
        check_status(role, entry.status.as_deref())?;
    }
    for (role, spec) in doc
        .semantic
        .space
        .iter()
        .chain(&doc.semantic.radius)
        .chain(&doc.semantic.size)
    {
        check_status(role, spec.status.as_deref())?;
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
        check_status(role, spec.status.as_deref())?;
        if let Some(tracking) = spec.tracking
            && !(0.0..=0.5).contains(&tracking)
        {
            return Err(format!(
                "{role}: tracking {tracking}em is outside 0..0.5em"
            ));
        }
        if let Some(case) = spec.case_rule.as_deref()
            && case != "uppercase"
        {
            return Err(format!("{role}: unknown case {case:?}"));
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
            spec.curve.name.as_str(),
            "linear" | "easeIn" | "easeOut" | "easeInOut"
        ) {
            return Err(format!("{role}: unknown curve {:?}", spec.curve.name));
        }
        check_status(role, spec.status.as_deref())?;
        if spec.duration == 0 {
            return Err(format!("{role}: duration must be greater than zero"));
        }
        match (spec.curve.name.as_str(), spec.curve.cubic()) {
            ("linear", Some(_)) => {
                return Err(format!("{role}: linear takes no cubic points"));
            }
            ("linear", None) => {}
            (_, None) => {
                return Err(format!(
                    "{role}: curve {:?} needs [x1, y1, x2, y2]",
                    spec.curve.name
                ));
            }
            (_, Some([x1, _, x2, _])) => {
                // x must stay in 0..1 to keep the curve a function. y may
                // overshoot, so a spring needs no new shape.
                if !(0.0..=1.0).contains(&x1) || !(0.0..=1.0).contains(&x2) {
                    return Err(format!("{role}: cubic x values must be in 0..1"));
                }
            }
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
                "motion": {{ "wash": {{ "duration": 150, "curve": {{ "name": "linear" }} }} }}
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

    fn custom(typography: &str, motion: &str, radius: &str) -> Doc {
        let json = format!(
            r##"{{
              "primitive": {{ "color": {{ "sand.50": "#FFFCF7" }} }},
              "semantic": {{
                "color": {{ "page.paper": {{ "light": "sand.50", "dark": "sand.50", "description": "" }} }},
                "typography": {typography},
                "space": {{ "stackGap": {{ "value": 12, "description": "" }} }},
                "radius": {radius},
                "size": {{
                  "minTarget": {{ "value": 44, "description": "" }},
                  "maxLineWidth": {{ "value": 640, "description": "" }}
                }},
                "motion": {motion}
              }},
              "platform": {{ "swift": {{ "names": {{ "page.paper": "paper" }} }} }}
            }}"##
        );
        Doc::parse(&json).expect("fixture parses")
    }

    const BODY: &str =
        r#"{ "body": { "family": "serif", "size": 19, "line": 31, "weight": "regular" } }"#;
    const RADIUS: &str = r#"{ "card": { "value": 12, "description": "" } }"#;
    const WASH: &str = r#"{ "wash": { "duration": 150, "curve": { "name": "linear" } } }"#;

    #[test]
    fn a_provisional_role_is_listed_but_legal() {
        let radius =
            r#"{ "sheet": { "value": 16, "description": "mock", "status": "provisional" } }"#;
        let doc = custom(BODY, WASH, radius);
        assert!(validate(&doc).is_ok());
        assert_eq!(provisional(&doc), vec!["radius.sheet".to_string()]);
    }

    #[test]
    fn an_unknown_status_is_rejected() {
        let radius = r#"{ "card": { "value": 16, "description": "", "status": "maybe" } }"#;
        let doc = custom(BODY, WASH, radius);
        let error = validate(&doc).unwrap_err();
        assert!(error.contains("maybe"), "{error}");
    }

    #[test]
    fn tracking_is_measured_in_em() {
        let typography = r#"{
          "body": { "family": "serif", "size": 19, "line": 31, "weight": "regular" },
          "chip": { "family": "mono", "size": 10, "weight": "bold", "tracking": 0.088,
                    "case": "uppercase", "description": "" }
        }"#;
        assert!(validate(&custom(typography, WASH, RADIUS)).is_ok());

        let too_wide = typography.replace("0.088", "2.0");
        let error = validate(&custom(&too_wide, WASH, RADIUS)).unwrap_err();
        assert!(error.contains("tracking"), "{error}");

        let bad_case = typography.replace("uppercase", "capitalise");
        let error = validate(&custom(&bad_case, WASH, RADIUS)).unwrap_err();
        assert!(error.contains("case"), "{error}");
    }

    #[test]
    fn a_curve_needs_its_points() {
        let named_only = r#"{ "sheet": { "duration": 180, "curve": { "name": "easeInOut" } } }"#;
        let error = validate(&custom(BODY, named_only, RADIUS)).unwrap_err();
        assert!(error.contains("cubic") || error.contains("x1"), "{error}");

        let points = r#"{ "sheet": { "duration": 180, "curve": { "name": "easeInOut",
                        "cubic": [0.42, 0.0, 0.58, 1.0] } } }"#;
        assert!(validate(&custom(BODY, points, RADIUS)).is_ok());

        // y may overshoot: a spring needs no new shape.
        let overshoot = r#"{ "sheet": { "duration": 180, "curve": { "name": "easeOut",
                          "cubic": [0.2, 1.6, 0.4, 1.0] } } }"#;
        assert!(validate(&custom(BODY, overshoot, RADIUS)).is_ok());
    }

    #[test]
    fn a_cubic_x_outside_the_unit_interval_is_rejected() {
        let points = r#"{ "sheet": { "duration": 180, "curve": { "name": "easeInOut",
                        "cubic": [1.2, 0.0, 0.58, 1.0] } } }"#;
        let error = validate(&custom(BODY, points, RADIUS)).unwrap_err();
        assert!(error.contains("0..1"), "{error}");
    }

    #[test]
    fn linear_takes_no_points() {
        let points = r#"{ "wash": { "duration": 150, "curve": { "name": "linear",
                        "cubic": [0.0, 0.0, 1.0, 1.0] } } }"#;
        let error = validate(&custom(BODY, points, RADIUS)).unwrap_err();
        assert!(error.contains("linear"), "{error}");
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
