//! The token document, as declared in `design/tokens.json`.
//!
//! Every role map keeps JSON order, so a generated file lists roles in the
//! order a person wrote them. Field names match the JSON exactly, including
//! the camel-case ones.

use indexmap::IndexMap;
use serde::Deserialize;

/// A role map keeps JSON order: a generated file lists roles as a person wrote
/// them, not in alphabetical order.
pub type Roles<T> = IndexMap<String, T>;

#[derive(Deserialize)]
pub struct Doc {
    pub primitive: Primitive,
    pub semantic: Semantic,
    pub platform: Platform,
}

#[derive(Deserialize)]
pub struct Primitive {
    pub color: Roles<String>,
}

#[derive(Deserialize)]
pub struct Semantic {
    pub color: Roles<ColorRole>,
    pub typography: Roles<TypeRole>,
    pub space: Roles<ScalarRole>,
    pub radius: Roles<ScalarRole>,
    pub size: Roles<ScalarRole>,
    pub motion: Roles<MotionRole>,
}

#[derive(Deserialize)]
pub struct ColorRole {
    pub light: ColorRef,
    pub dark: ColorRef,
    #[serde(default)]
    pub description: String,
}

/// A role points at a primitive, or at a primitive plus an alpha.
#[derive(Deserialize)]
#[serde(untagged)]
pub enum ColorRef {
    Primitive(String),
    Alpha { color: String, alpha: f64 },
}

impl ColorRef {
    pub fn primitive(&self) -> &str {
        match self {
            Self::Primitive(value) => value,
            Self::Alpha { color, .. } => color,
        }
    }

    pub fn alpha(&self) -> Option<f64> {
        match self {
            Self::Primitive(_) => None,
            Self::Alpha { alpha, .. } => Some(*alpha),
        }
    }
}

#[derive(Deserialize)]
pub struct TypeRole {
    pub family: String,
    pub size: u32,
    #[serde(default)]
    pub line: Option<u32>,
    pub weight: String,
    #[serde(rename = "monospacedDigit", default)]
    pub monospaced_digit: bool,
    #[serde(default)]
    pub description: String,
}

#[derive(Deserialize)]
pub struct ScalarRole {
    pub value: u32,
    #[serde(default)]
    pub description: String,
}

#[derive(Deserialize)]
pub struct MotionRole {
    pub duration: u32,
    /// Named, not coded: each platform maps the name to its own easing API.
    pub curve: String,
}

#[derive(Deserialize)]
pub struct Platform {
    pub swift: SwiftPlatform,
}

#[derive(Deserialize)]
pub struct SwiftPlatform {
    /// Semantic role to Swift symbol. Explicit, because the app shipped names
    /// before the JSON existed.
    pub names: Roles<String>,
    #[serde(rename = "fontNames", default)]
    pub font_names: Roles<String>,
}

impl Doc {
    pub fn parse(text: &str) -> Result<Self, String> {
        serde_json::from_str(text).map_err(|error| format!("design/tokens.json: {error}"))
    }
}
