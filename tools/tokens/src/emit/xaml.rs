//! WinUI 3 resource dictionaries.
//!
//! Colours live in theme dictionaries, so WinUI picks the mode. Sizes are
//! doubles in effective pixels: 44 is 44 epx at 100 percent scaling, and the
//! view must scale it with the system text scale.

use super::HEADER;
use crate::model::{ColorRef, Doc};
use crate::naming::{hex_bare, pascal};
use crate::validate::resolve_color;

pub fn emit(doc: &Doc) -> Result<String, String> {
    let mut lines: Vec<String> = vec![
        format!("<!-- {HEADER} -->"),
        "<ResourceDictionary".to_string(),
        "    xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"".to_string(),
        "    xmlns:x=\"http://schemas.microsoft.com/winfx/2006/xaml\">".to_string(),
        "    <ResourceDictionary.ThemeDictionaries>".to_string(),
        "        <ResourceDictionary x:Key=\"Light\">".to_string(),
    ];
    for (role, entry) in &doc.semantic.color {
        lines.push(colour(doc, role, &entry.light)?);
    }
    lines.push("        </ResourceDictionary>".to_string());
    lines.push("        <ResourceDictionary x:Key=\"Dark\">".to_string());
    for (role, entry) in &doc.semantic.color {
        lines.push(colour(doc, role, &entry.dark)?);
    }
    lines.push("        </ResourceDictionary>".to_string());
    lines.push("    </ResourceDictionary.ThemeDictionaries>".to_string());

    for (role, spec) in &doc.semantic.space {
        lines.push(format!(
            "    <x:Double x:Key=\"Space{}\">{}</x:Double>",
            pascal(role),
            spec.value
        ));
    }
    for (role, spec) in &doc.semantic.radius {
        lines.push(format!(
            "    <x:Double x:Key=\"Radius{}\">{}</x:Double>",
            pascal(role),
            spec.value
        ));
    }
    for (role, spec) in &doc.semantic.size {
        lines.push(format!(
            "    <x:Double x:Key=\"Size{}\">{}</x:Double>",
            pascal(role),
            spec.value
        ));
    }
    for (role, spec) in &doc.semantic.typography {
        lines.push(format!(
            "    <x:Double x:Key=\"Type{}Size\">{}</x:Double>",
            pascal(role),
            spec.size
        ));
        if let Some(line) = spec.line {
            lines.push(format!(
                "    <x:Double x:Key=\"Type{}Line\">{line}</x:Double>",
                pascal(role)
            ));
        }
    }
    for (role, spec) in &doc.semantic.motion {
        lines.push(format!(
            "    <x:Int32 x:Key=\"Motion{}\">{}</x:Int32>",
            pascal(role),
            spec.duration
        ));
    }
    lines.push("</ResourceDictionary>".to_string());

    Ok(lines.join("\n") + "\n")
}

fn colour(doc: &Doc, role: &str, value: &ColorRef) -> Result<String, String> {
    let key = pascal(role);
    let Some(alpha) = value.alpha() else {
        return Ok(format!(
            "                <Color x:Key=\"{key}\">{}</Color>",
            resolve_color(doc, value)?
        ));
    };
    // XAML spells alpha first, as #AARRGGBB.
    Ok(format!(
        "                <Color x:Key=\"{key}\">#{:02X}{}</Color>",
        (alpha * 255.0) as u32,
        hex_bare(resolve_color(doc, value)?)
    ))
}
