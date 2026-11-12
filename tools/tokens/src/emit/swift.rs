//! Swift tokens for `ReadLaterUI`.
//!
//! Views read these names. The values never appear in a view, so the JSON is
//! the only place a colour or a size is written.

use super::HEADER;
use crate::model::Doc;
use crate::naming::hex_arg;
use crate::validate::resolve_color;

const FAMILY: &[(&str, &str)] = &[
    ("serif", "serif"),
    ("sans", "default"),
    ("mono", "monospaced"),
];

pub fn emit(doc: &Doc) -> Result<String, String> {
    let mut lines: Vec<String> = vec![
        format!("// {HEADER}"),
        "// A view reads these names. A value change happens in the JSON.".to_string(),
        String::new(),
        "import SwiftUI".to_string(),
        String::new(),
        "public extension Theme {".to_string(),
        "    // MARK: - Colour (layer 2, bound to this platform)".to_string(),
        String::new(),
    ];

    for (role, entry) in &doc.semantic.color {
        let symbol = doc
            .platform
            .swift
            .names
            .get(role)
            .ok_or_else(|| format!("swift binding missing for {role}"))?;
        let light = resolve_color(doc, &entry.light)?;
        let dark = resolve_color(doc, &entry.dark)?;
        let doc_line = format!(
            "    /// `{role}`.{} {}",
            provisional(entry.status.as_deref()),
            entry.description
        );
        lines.push(doc_line.trim_end().to_string());

        let mut call = format!(
            "themedColor(light: {}, dark: {})",
            hex_arg(light),
            hex_arg(dark)
        );
        if let Some(alpha) = entry.light.alpha() {
            call.push_str(&format!(".opacity({alpha})"));
        }
        lines.push(format!("    static let {symbol} = {call}"));
        // The raw pair, for the adapters that must build a UIColor or NSColor
        // before SwiftUI resolves a Color.
        lines.push(format!(
            "    static let {symbol}Hex: (light: UInt32, dark: UInt32) = ({}, {})",
            hex_arg(light),
            hex_arg(dark)
        ));
        lines.push(String::new());
    }

    lines.push("    // MARK: - Type (layer 2)".to_string());
    lines.push(String::new());

    for (role, spec) in &doc.semantic.typography {
        let symbol = doc
            .platform
            .swift
            .font_names
            .get(role)
            .map(String::as_str)
            .unwrap_or(role);
        let design = FAMILY
            .iter()
            .find(|(family, _)| *family == spec.family)
            .map(|(_, name)| *name)
            .ok_or_else(|| format!("unknown family {:?}", spec.family))?;
        let digits = if spec.monospaced_digit {
            ".monospacedDigit()"
        } else {
            ""
        };
        let weight = spec.weight.as_str();
        let size = spec.size;

        let doc_line = format!(
            "    /// `{role}`.{} {}",
            provisional(spec.status.as_deref()),
            spec.description
        );
        lines.push(doc_line.trim_end().to_string());
        lines.push(format!(
            "    static func {symbol}() -> Font {{ .system(size: {size}, weight: .{weight}, design: .{design}){digits} }}"
        ));
        // The text engines need the numbers before SwiftUI resolves a Font.
        lines.push(format!("    static let {symbol}Size: CGFloat = {size}"));
        if let Some(line) = spec.line {
            lines.push(format!("    static let {symbol}Line: CGFloat = {line}"));
        }
        if let Some(tracking) = spec.tracking {
            // SwiftUI takes points; the JSON holds em, so the size is applied
            // here and a view reads one number.
            // Rounded to a thousandth: 0.088 * 10 must print as 0.88.
            let points = ((tracking * f64::from(size)) * 1000.0).round() / 1000.0;
            lines.push(format!(
                "    /// `{role}` tracking, in points: {}em at {size}.",
                trim_float(tracking)
            ));
            lines.push(format!(
                "    static let {symbol}Tracking: CGFloat = {}",
                trim_float(points)
            ));
        }
        lines.push(String::new());
    }

    lines.push("    // MARK: - Space, shape, size (layer 2)".to_string());
    lines.push(String::new());

    for (role, spec) in &doc.semantic.space {
        lines.push(format!(
            "    /// `{role}`.{} {}",
            provisional(spec.status.as_deref()),
            spec.description
        ));
        lines.push(format!(
            "    public static let {role}: CGFloat = {}",
            spec.value
        ));
        lines.push(String::new());
    }
    for (role, spec) in &doc.semantic.radius {
        lines.push(format!(
            "    /// `radius.{role}`.{} {}",
            provisional(spec.status.as_deref()),
            spec.description
        ));
        lines.push(format!(
            "    public static let {role}Radius: CGFloat = {}",
            spec.value
        ));
        lines.push(String::new());
    }
    for (role, spec) in &doc.semantic.size {
        if role == "minTarget" || role == "maxLineWidth" {
            continue; // named exactly below
        }
        lines.push(format!(
            "    /// `size.{role}`.{} {}",
            provisional(spec.status.as_deref()),
            spec.description
        ));
        lines.push(format!(
            "    public static let {role}: CGFloat = {}",
            spec.value
        ));
        lines.push(String::new());
    }

    for role in ["minTarget", "maxLineWidth"] {
        let spec = doc
            .semantic
            .size
            .get(role)
            .ok_or_else(|| format!("size.{role} is required"))?;
        lines.push(format!(
            "    /// `size.{role}`.{} {}",
            provisional(spec.status.as_deref()),
            spec.description
        ));
        lines.push(format!(
            "    public static let {role}: CGFloat = {}",
            spec.value
        ));
        lines.push(String::new());
    }

    let body = doc
        .semantic
        .typography
        .get("body")
        .ok_or("typography needs a `body` role")?;
    let spacing = body.line.ok_or("body needs a `line` value")? - body.size;
    lines.push("    /// The body line box, minus the type size.".to_string());
    lines.push(format!(
        "    public static let bodyLineSpacing: CGFloat = {spacing}"
    ));
    lines.push("}".to_string());

    lines.push(String::new());
    lines.push("/// Motion, layer 2. Built from the numbers, not from a name.".to_string());
    lines.push("public enum ThemeMotion {".to_string());
    for (role, spec) in &doc.semantic.motion {
        let seconds = format!("{:.3}", f64::from(spec.duration) / 1000.0);
        let animation = match spec.curve.cubic() {
            Some([x1, y1, x2, y2]) => format!(
                "Animation.timingCurve({}, {}, {}, {}, duration: {seconds})",
                trim_float(x1),
                trim_float(y1),
                trim_float(x2),
                trim_float(y2)
            ),
            None => format!("Animation.linear(duration: {seconds})"),
        };
        lines.push(format!(
            "    /// `motion.{role}`.{} {}",
            provisional(spec.status.as_deref()),
            spec.curve.name
        ));
        lines.push(format!("    public static let {role} = {animation}"));
        lines.push(String::new());
    }
    lines.push("}".to_string());
    Ok(lines.join("\n") + "\n")
}

fn provisional(status: Option<&str>) -> &'static str {
    if status == Some("provisional") {
        " Provisional."
    } else {
        ""
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
