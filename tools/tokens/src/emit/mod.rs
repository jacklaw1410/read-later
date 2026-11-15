//! One emitter per platform. Each reads the semantic layer only, so a platform
//! file can never depend on another platform's binding.

use crate::model::Doc;

pub mod css;
pub mod kotlin;
pub mod specimen;
pub mod swift;
pub mod xaml;

/// First line of every generated file. The file names its own source.
pub const HEADER: &str =
    "Generated from design/tokens.json by tools/tokens (readlater-tokens). Do not edit.";

/// A generated file: where it goes, relative to the repo root, and its text.
pub struct Output {
    pub path: &'static str,
    pub text: String,
}

pub fn emit_all(doc: &Doc) -> Result<Vec<Output>, String> {
    Ok(vec![
        Output {
            path: "packages/ReadLaterUI/Sources/ReadLaterUI/Generated/ThemeTokens.swift",
            text: swift::emit(doc)?,
        },
        Output {
            path: "design/generated/tokens.css",
            text: css::emit(doc)?,
        },
        Output {
            path: "design/generated/Tokens.kt",
            text: kotlin::emit(doc)?,
        },
        Output {
            path: "design/generated/Tokens.xaml",
            text: xaml::emit(doc)?,
        },
        Output {
            path: "design/specimen/specimen.html",
            text: specimen::emit_specimen(doc)?,
        },
        Output {
            path: "design/specimen/index.html",
            text: specimen::emit_index(doc)?,
        },
    ])
}
