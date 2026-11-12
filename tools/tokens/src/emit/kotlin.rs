//! Jetpack Compose tokens.
//!
//! Colours are semantic roles. Sizes are `dp`; type sizes are `sp`, so Android
//! scales text with the user's font setting. The component layer is Compose.

use super::HEADER;
use crate::model::{ColorRef, Doc};
use crate::naming::{camel, hex_bare};
use crate::validate::resolve_color;

pub fn emit(doc: &Doc) -> Result<String, String> {
    let props: Vec<String> = doc
        .semantic
        .color
        .keys()
        .map(|role| format!("val {}: Color", camel(role)))
        .collect();

    let mut lines: Vec<String> = vec![
        format!("// {HEADER}"),
        "package app.readlater.design".to_string(),
        String::new(),
        "import androidx.compose.foundation.isSystemInDarkTheme".to_string(),
        "import androidx.compose.runtime.Composable".to_string(),
        "import androidx.compose.runtime.ReadOnlyComposable".to_string(),
        "import androidx.compose.animation.core.CubicBezierEasing".to_string(),
        "import androidx.compose.animation.core.LinearEasing".to_string(),
        "import androidx.compose.ui.graphics.Color".to_string(),
        "import androidx.compose.ui.unit.dp".to_string(),
        "import androidx.compose.ui.unit.em".to_string(),
        "import androidx.compose.ui.unit.sp".to_string(),
        String::new(),
        "/** Semantic colours. The component layer is Compose; these are layer 2. */".to_string(),
        "interface ReadLaterTokens {".to_string(),
        format!("    {}", props.join(", ")),
        "}".to_string(),
        String::new(),
        "object LightTokens : ReadLaterTokens {".to_string(),
    ];
    for (role, entry) in &doc.semantic.color {
        push_marker(&mut lines, entry.status.as_deref(), role);
        lines.push(format!(
            "    override val {} = {}",
            camel(role),
            color(doc, &entry.light)?
        ));
    }
    lines.push("}".to_string());
    lines.push(String::new());
    lines.push("object DarkTokens : ReadLaterTokens {".to_string());
    for (role, entry) in &doc.semantic.color {
        push_marker(&mut lines, entry.status.as_deref(), role);
        lines.push(format!(
            "    override val {} = {}",
            camel(role),
            color(doc, &entry.dark)?
        ));
    }
    lines.extend([
        "}".to_string(),
        String::new(),
        "@Composable".to_string(),
        "@ReadOnlyComposable".to_string(),
        "fun tokens(): ReadLaterTokens = if (isSystemInDarkTheme()) DarkTokens else LightTokens"
            .to_string(),
        String::new(),
        "/** Layer 2 sizes. Android scales these with sp where text is involved. */".to_string(),
        "object Space {".to_string(),
    ]);
    for (role, spec) in &doc.semantic.space {
        push_marker(&mut lines, spec.status.as_deref(), role);
        lines.push(format!("    val {role} = {}.dp", spec.value));
    }
    for (role, spec) in &doc.semantic.radius {
        push_marker(&mut lines, spec.status.as_deref(), role);
        lines.push(format!("    val {role}Radius = {}.dp", spec.value));
    }
    for (role, spec) in &doc.semantic.size {
        push_marker(&mut lines, spec.status.as_deref(), role);
        lines.push(format!("    val {role} = {}.dp", spec.value));
    }
    lines.extend([
        "}".to_string(),
        String::new(),
        "/** Layer 2 type sizes. Compose builds its own TextStyle from these. */".to_string(),
        "object TypeScale {".to_string(),
    ]);
    for (role, spec) in &doc.semantic.typography {
        push_marker(&mut lines, spec.status.as_deref(), role);
        lines.push(format!("    val {}Size = {}.sp", camel(role), spec.size));
        if let Some(line) = spec.line {
            lines.push(format!("    val {}Line = {line}.sp", camel(role)));
        }
        if let Some(tracking) = spec.tracking {
            lines.push(format!(
                "    /** Tracking in em: multiply by the size. */\n    val {}Tracking = {}.em",
                camel(role),
                trim_float(tracking)
            ));
        }
    }
    lines.extend([
        "}".to_string(),
        String::new(),
        "/** Layer 2 motion: milliseconds plus the curve, not its name. */".to_string(),
        "object Motion {".to_string(),
    ]);
    for (role, spec) in &doc.semantic.motion {
        push_marker(&mut lines, spec.status.as_deref(), role);
        lines.push(format!(
            "    const val {} = {}L",
            camel(role),
            spec.duration
        ));
        let easing = match spec.curve.cubic() {
            Some([x1, y1, x2, y2]) => format!(
                "CubicBezierEasing({}f, {}f, {}f, {}f)",
                trim_float(x1),
                trim_float(y1),
                trim_float(x2),
                trim_float(y2)
            ),
            None => "LinearEasing".to_string(),
        };
        lines.push(format!("    val {}Easing = {easing}", camel(role)));
    }
    lines.push("}".to_string());

    Ok(lines.join("\n") + "\n")
}

fn push_marker(lines: &mut Vec<String>, status: Option<&str>, role: &str) {
    if status == Some("provisional") {
        lines.push(format!("    // provisional: {role}"));
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

fn color(doc: &Doc, value: &ColorRef) -> Result<String, String> {
    let hex = hex_bare(resolve_color(doc, value)?);
    match value.alpha() {
        Some(alpha) => Ok(format!("Color(0xFF{hex}).copy(alpha = {alpha}f)")),
        None => Ok(format!("Color(0xFF{hex})")),
    }
}
