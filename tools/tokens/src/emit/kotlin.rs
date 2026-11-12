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
        "import androidx.compose.ui.graphics.Color".to_string(),
        "import androidx.compose.ui.unit.dp".to_string(),
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
        lines.push(format!("    val {role} = {}.dp", spec.value));
    }
    for (role, spec) in &doc.semantic.radius {
        lines.push(format!("    val {role}Radius = {}.dp", spec.value));
    }
    for (role, spec) in &doc.semantic.size {
        lines.push(format!("    val {role} = {}.dp", spec.value));
    }
    lines.extend([
        "}".to_string(),
        String::new(),
        "/** Layer 2 type sizes. Compose builds its own TextStyle from these. */".to_string(),
        "object TypeScale {".to_string(),
    ]);
    for (role, spec) in &doc.semantic.typography {
        lines.push(format!("    val {}Size = {}.sp", camel(role), spec.size));
        if let Some(line) = spec.line {
            lines.push(format!("    val {}Line = {line}.sp", camel(role)));
        }
    }
    lines.extend([
        "}".to_string(),
        String::new(),
        "/** Layer 2 motion durations in milliseconds. */".to_string(),
        "object Motion {".to_string(),
    ]);
    for (role, spec) in &doc.semantic.motion {
        lines.push(format!(
            "    const val {} = {}L",
            camel(role),
            spec.duration
        ));
    }
    lines.push("}".to_string());

    Ok(lines.join("\n") + "\n")
}

fn color(doc: &Doc, value: &ColorRef) -> Result<String, String> {
    let hex = hex_bare(resolve_color(doc, value)?);
    match value.alpha() {
        Some(alpha) => Ok(format!("Color(0xFF{hex}).copy(alpha = {alpha}f)")),
        None => Ok(format!("Color(0xFF{hex})")),
    }
}
