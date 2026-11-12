//! CSS variables, for prototypes and docs.
//!
//! Every semantic colour appears in `:root` (system light by default), in a
//! `prefers-color-scheme` block, and in an attribute block for a forced theme.

use super::HEADER;
use crate::model::Doc;
use crate::naming::kebab;
use crate::validate::resolve_color;

pub fn emit(doc: &Doc) -> Result<String, String> {
    let light = block(doc, true)?;
    let dark = block(doc, false)?;

    let mut extra: Vec<String> = Vec::new();
    for (role, spec) in &doc.semantic.space {
        extra.push(marker(spec.status.as_deref(), &kebab(role)));
        extra.push(format!("  --{}: {}px;", kebab(role), spec.value));
    }
    for (role, spec) in &doc.semantic.radius {
        extra.push(marker(spec.status.as_deref(), &kebab(role)));
        extra.push(format!("  --radius-{}: {}px;", kebab(role), spec.value));
    }
    for (role, spec) in &doc.semantic.size {
        extra.push(marker(spec.status.as_deref(), &kebab(role)));
        extra.push(format!("  --size-{}: {}px;", kebab(role), spec.value));
    }
    for (role, spec) in &doc.semantic.motion {
        extra.push(marker(spec.status.as_deref(), &kebab(role)));
        extra.push(format!("  --motion-{}: {}ms;", kebab(role), spec.duration));
        let ease = match spec.curve.cubic() {
            Some([x1, y1, x2, y2]) => format!(
                "cubic-bezier({}, {}, {}, {})",
                trim_float(x1),
                trim_float(y1),
                trim_float(x2),
                trim_float(y2)
            ),
            None => "linear".to_string(),
        };
        extra.push(format!("  --motion-{}-ease: {ease};", kebab(role)));
    }
    for (role, spec) in &doc.semantic.typography {
        extra.push(marker(spec.status.as_deref(), &kebab(role)));
        extra.push(format!("  --type-{}-size: {}px;", kebab(role), spec.size));
        if let Some(line) = spec.line {
            extra.push(format!("  --type-{}-line: {line}px;", kebab(role)));
        }
        if let Some(tracking) = spec.tracking {
            extra.push(format!(
                "  --type-{}-tracking: {}em;",
                kebab(role),
                trim_float(tracking)
            ));
        }
    }

    let mut lines: Vec<String> = vec![
        format!("/* {HEADER} */"),
        String::new(),
        ":root {".to_string(),
    ];
    lines.extend(light.iter().cloned());
    lines.extend(extra);
    lines.push("}".to_string());
    lines.push(String::new());
    lines.push("@media (prefers-color-scheme: dark) {".to_string());
    lines.push("  :root {".to_string());
    lines.extend(dark.iter().map(|line| format!("  {line}")));
    lines.push("  }".to_string());
    lines.push("}".to_string());
    lines.push(String::new());
    lines.push("[data-theme=\"light\"] {".to_string());
    lines.extend(light);
    lines.push("}".to_string());
    lines.push(String::new());
    lines.push("[data-theme=\"dark\"] {".to_string());
    lines.extend(dark);
    lines.push("}".to_string());

    Ok(lines.join("\n") + "\n")
}

fn marker(status: Option<&str>, name: &str) -> String {
    if status == Some("provisional") {
        format!("  /* provisional: {name} */")
    } else {
        String::new()
    }
}

/// `0.42` prints as `0.42`, not `0.4200`.
fn trim_float(value: f64) -> String {
    let text = format!("{value}");
    if text.contains('.') {
        text.trim_end_matches('0').trim_end_matches('.').to_string()
    } else {
        text
    }
}

fn block(doc: &Doc, light: bool) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    for (role, entry) in &doc.semantic.color {
        let value = if light { &entry.light } else { &entry.dark };
        let hex = resolve_color(doc, value)?;
        if entry.status.as_deref() == Some("provisional") {
            out.push(marker(Some("provisional"), &kebab(role)));
        }
        // CSS spells alpha last, as #RRGGBBAA.
        match value.alpha() {
            Some(alpha) => out.push(format!(
                "  --{}: {}{:02X};",
                kebab(role),
                hex,
                (alpha * 255.0) as u32
            )),
            None => out.push(format!("  --{}: {hex};", kebab(role))),
        }
    }
    Ok(out)
}
