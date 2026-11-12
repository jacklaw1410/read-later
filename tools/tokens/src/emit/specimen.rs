//! The visual specimen: layers 1 and 2 as one HTML page, plus an index.
//!
//! The page reads `design/generated/tokens.css` through a link and CSS custom
//! properties. It holds no literal: no hex, no point size, no dp. A reviewer
//! opens it from a checkout with `file://`, so every same-repo link is
//! relative. Research-repo links pin a commit, because two checkouts share no
//! stable path.

use std::path::Path;

use crate::model::{ColorRef, Doc, ScalarRole};
use crate::naming::kebab;
use crate::validate::resolve_color;

/// The source commit behind the banner. Both values come from the last commit
/// that touched `design/tokens.json`, never from the wall clock: a date from
/// the clock would make `--check` fail on every commit after the page was
/// written.
pub struct Freshness {
    /// Seven hex digits of the source commit.
    pub sha: String,
    /// UTC date of the source commit, `YYYY-MM-DD`.
    pub date: String,
}

/// Reads the banner values from git history. Fails outside a checkout, so a
/// page built where history is missing never ships a guessed date.
pub fn freshness_from_git(root: &Path) -> Result<Freshness, String> {
    let full = git(root, &["log", "-1", "--format=%H", "--", "design/tokens.json"])?;
    let full = full.trim();
    if full.len() < 7 || !full.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(format!("design/tokens.json: bad commit {full:?}"));
    }
    let date = git(
        root,
        &["log", "-1", "--format=%cs", full, "--", "design/tokens.json"],
    )?;
    let date = date.trim().to_string();
    if date.len() != 10 {
        return Err(format!("design/tokens.json: bad date {date:?}"));
    }
    Ok(Freshness {
        sha: full[..7].to_string(),
        date,
    })
}

fn git(root: &Path, args: &[&str]) -> Result<String, String> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .map_err(|error| format!("git: {error}"))?;
    if !output.status.success() {
        return Err(format!("git {}: {}", args.join(" "), output.status));
    }
    String::from_utf8(output.stdout).map_err(|error| format!("git: {error}"))
}

/// One banner line on both pages. Same shape as the plan: source, not clock.
pub fn banner(fresh: &Freshness) -> String {
    format!(
        "Specimen from {} on {}. Source design/tokens.json.",
        fresh.sha, fresh.date
    )
}

/// Research-repo links pin this commit. A moving target would break `--check`
/// the same way a clock date would.
const RESEARCH_PIN: &str = "f3c1e36";
const RESEARCH: &str = "https://github.com/jacklaw1410/read-later-research";

/// `&`, `<`, `>` become entities. Descriptions are token words, not markup.
fn esc(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// Page chrome only: layout in `rem`, no token value. A swatch that needs a
/// token value uses an inline `var()`, never this block.
const CHROME: &str = r"
body{font-family:system-ui,sans-serif;margin:0 auto;max-width:64rem;padding:1rem;line-height:1.5}
.banner{border:0.125rem solid currentColor;padding:0.5rem 1rem;font-weight:bold}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(13rem,1fr));gap:1rem}
.cell{border:0.0625rem solid currentColor;padding:0.5rem}
.sw{height:3rem}
.stack{padding:1.5rem}
.stack .stack{margin-top:1rem}
.row{display:flex;align-items:center;gap:1rem;margin:0.5rem 0}
.bar{height:1.5rem}
.demo{border:0.0625rem solid currentColor;padding:1rem;margin:1rem 0}
.prose{max-width:40rem}
a{color:inherit}
";

fn head(title: &str) -> String {
    format!(
        "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>{title}</title>\n<link rel=\"stylesheet\" href=\"../generated/tokens.css\">\n<style>{CHROME}</style>\n</head>\n<body>\n"
    )
}

/// Finds a semantic role that shows a primitive, so the strip needs no
/// literal. Light mode wins; an alpha role is a last resort. Every primitive
/// in the file today has at least one role, so a missing one is an emitter
/// bug, not a gap the page may hide.
fn primitive_swatch(doc: &Doc, name: &str, hex: &str) -> Result<(String, String), String> {
    let mut fallback: Option<(String, String)> = None;
    for (role, entry) in &doc.semantic.color {
        for (mode, value) in [("light", &entry.light), ("dark", &entry.dark)] {
            if resolve_color(doc, value)?.eq_ignore_ascii_case(hex) {
                let named = (kebab(role), mode.to_string());
                match value {
                    ColorRef::Primitive(_) => return Ok(named),
                    ColorRef::Alpha { .. } => fallback = fallback.or(Some(named)),
                }
            }
        }
    }
    // `black` only appears under an alpha role today. The swatch shows the
    // scrim, which the caption says.
    let _ = name;
    fallback.ok_or_else(|| format!("primitive {name:?} is shown by no semantic role"))
}

/// Section 1: every semantic role in both modes, plus the primitive strip.
fn section_modes(doc: &Doc) -> Result<String, String> {
    let mut out = String::from("<h2>1 · Mode switch</h2>\n<p>Mode governs every colour. Same roles, light and dark.</p>\n");
    for mode in ["light", "dark"] {
        out.push_str(&format!("<h3>{mode}</h3>\n<div data-theme=\"{mode}\">\n<div class=\"grid\">\n"));
        for (role, entry) in &doc.semantic.color {
            out.push_str(&format!(
                "<div class=\"cell\" data-role=\"{role}\"><div class=\"sw\" style=\"background:var(--{var})\"></div><div><b>{role}</b></div><div>{desc}</div></div>\n",
                var = kebab(role),
                desc = esc(&entry.description),
            ));
        }
        out.push_str("</div>\n</div>\n");
    }
    out.push_str("<h3>Layer 1 · primitives</h3>\n<p>Raw values, no meaning. Each swatch borrows the first semantic role that shows it; <b>black</b> only appears under the scrim, so its swatch is the scrim.</p>\n<div data-theme=\"light\">\n<div class=\"grid\">\n");
    for (name, hex) in &doc.primitive.color {
        let (var, mode) = primitive_swatch(doc, name, hex)?;
        let _ = mode;
        out.push_str(&format!(
            "<div class=\"cell\" data-primitive=\"{name}\"><div class=\"sw\" style=\"background:var(--{var})\"></div><div><b>{name}</b></div></div>\n",
        ));
    }
    out.push_str("</div>\n</div>\n");
    Ok(out)
}

/// Section 2: paper, surface and raised as a stack, not three squares.
fn section_page() -> String {
    String::from(
        "<h2>2 · Page and text</h2>\n<p>Foundation before accents.</p>\n<div data-theme=\"light\">\n<div class=\"demo\" style=\"background:var(--page-paper)\">\n<div><b>page.paper</b> · Reader and entry background.</div>\n<div class=\"stack\" style=\"background:var(--page-surface)\">\n<div><b>page.surface</b> · Card, player bar, chrome.</div>\n<div class=\"stack\" style=\"background:var(--page-raised)\">\n<div><b>page.raised</b> · Hold badge fill, mono chip.</div>\n</div>\n</div>\n<p class=\"prose\" style=\"color:var(--text-body);font-size:var(--type-body-size)\">Body text reads here. The wash will mark the spoken word.</p>\n<p style=\"color:var(--text-meta);font-size:var(--type-caption-size)\">Meta line · provenance · clock</p>\n<hr style=\"border-color:var(--line-hair)\">\n<div>line.hair · Divider, field border.</div>\n</div>\n</div>\n",
    )
}

/// Section 3: the spoken word, the tapped word, their overlap, the frozen wash.
fn section_voice() -> String {
    String::from(
        "<h2>3 · Voice and tap</h2>\n<p>Core product interaction.</p>\n<div data-theme=\"light\">\n<div class=\"demo\" style=\"background:var(--page-paper);color:var(--text-body);font-size:var(--type-body-size)\">\n<span>The voice is </span><span style=\"background:var(--wash-fill);color:var(--wash-ink)\">on this word</span><span>, the reader </span><span style=\"background:var(--mark-selected)\">tapped that one</span><span>, and </span><span style=\"background:var(--wash-fill);color:var(--wash-ink);outline:0.125rem solid var(--mark-coincide)\">this one is both</span><span>.</span>\n</div>\n<ul>\n<li><b>wash.fill</b> plus <b>wash.ink</b> · the spoken word.</li>\n<li><b>mark.selected</b> · the tapped word.</li>\n<li><b>mark.coincide</b> · ring when the tap lands on the spoken word.</li>\n</ul>\n<div class=\"demo\" style=\"background:var(--page-paper);color:var(--text-body);font-size:var(--type-body-size)\">\n<span>Audio paused: </span><span style=\"background:var(--rule-paused);outline:0.125rem solid var(--rule-ring)\">the wash freezes here</span><span>.</span>\n</div>\n<ul>\n<li><b>rule.paused</b> plus <b>rule.ring</b> · the frozen wash.</li>\n</ul>\n</div>\n",
    )
}

/// Section 4: controls after reading states. Saved marks are tier 2.
fn section_actions() -> String {
    String::from(
        "<h2>4 · Actions and marks</h2>\n<p>Controls after reading states.</p>\n<div data-theme=\"light\">\n<div class=\"demo\" style=\"background:var(--page-surface)\">\n<div class=\"row\"><span style=\"background:var(--action-fill);color:var(--action-ink);padding:0.5rem 1rem;border-radius:var(--radius-button)\">Listen</span><span><b>action.fill</b> plus <b>action.ink</b> · primary button. The fill stays dark in both modes so white ink keeps its contrast.</span></div>\n<div class=\"row\"><span style=\"background:var(--ghost-fill);color:var(--text-body);padding:0.5rem 1rem;border-radius:var(--radius-button)\">Later</span><span><b>ghost.fill</b> · secondary button fill on a card.</span></div>\n<div class=\"row\"><span style=\"color:var(--brand-link)\"><u>Quoted passage</u></span><span><b>brand.link</b> · quote rule, track fill, marker ink.</span></div>\n<div class=\"row\"><span style=\"background:var(--mark-saved-fill);border-left:0.25rem solid var(--mark-saved);padding:0.5rem 1rem\">Kept for study</span><span><b>mark.saved</b> plus <b>mark.savedFill</b> · tier 2, not part of the flow.</span></div>\n</div>\n</div>\n",
    )
}

/// Section 6: all 12 type roles at their real size. Sizes print as bare
/// numbers: a `px` value in the page would restate the token.
fn section_type(doc: &Doc) -> String {
    let mut out = String::from("<h2>6 · Type ramp</h2>\n<p>Editorial voice. Every role at its real size from the CSS variables.</p>\n<div data-theme=\"light\">\n<div class=\"demo\" style=\"background:var(--page-paper);color:var(--text-body)\">\n");
    for (role, spec) in &doc.semantic.typography {
        let tracking = spec
            .tracking
            .map(|t| format!(" · tracking {t} em"))
            .unwrap_or_default();
        out.push_str(&format!(
            "<div class=\"row\" data-type=\"{role}\"><span style=\"font-size:var(--type-{var}-size)\">Ag</span><span><b>{role}</b> · size {size} · {family} {weight}{tracking} · {desc}</span></div>\n",
            var = kebab(role),
            size = spec.size,
            family = spec.family,
            weight = spec.weight,
            desc = esc(&spec.description),
        ));
    }
    out.push_str("</div>\n</div>\n");
    out
}

/// A size step the page must show. A missing one fails the build, so the page
/// never renders a guessed bar.
fn size<'a>(doc: &'a Doc, role: &str) -> Result<&'a ScalarRole, String> {
    doc.semantic
        .size
        .get(role)
        .ok_or_else(|| format!("size.{role} is required by the specimen"))
}

/// Section 7: six space steps as bars, plus the reading measure.
fn section_space(doc: &Doc) -> Result<String, String> {
    let mut out = String::from("<h2>7 · Space and measure</h2>\n<p>Rhythm needs a bar. Each bar is the step itself, from the CSS variable.</p>\n<div data-theme=\"light\">\n<div class=\"demo\" style=\"background:var(--page-paper);color:var(--text-body)\">\n");
    for (role, spec) in &doc.semantic.space {
        out.push_str(&format!(
            "<div class=\"row\" data-space=\"{role}\"><div class=\"bar\" style=\"width:var(--{var});background:var(--brand-link)\"></div><span><b>{role}</b> · step {value} · {desc}</span></div>\n",
            var = kebab(role),
            value = spec.value,
            desc = esc(&spec.description),
        ));
    }
    let measure = size(doc, "maxLineWidth")?;
    out.push_str(&format!(
        "<div class=\"row\" data-space=\"maxLineWidth\"><div class=\"bar\" style=\"width:100%;max-width:var(--size-max-line-width);background:var(--brand-link)\"></div><span><b>maxLineWidth</b> · step {value} · {desc}</span></div>\n",
        value = measure.value,
        desc = esc(&measure.description),
    ));
    out.push_str("</div>\n</div>\n");
    Ok(out)
}

/// Section 8: six radii, the 44 target, the 58 player bar.
fn section_radius(doc: &Doc) -> Result<String, String> {
    let mut out = String::from("<h2>8 · Radius and size</h2>\n<p>Shape beside scale.</p>\n<div data-theme=\"light\">\n<div class=\"demo\" style=\"background:var(--page-paper);color:var(--text-body)\">\n");
    for (role, spec) in &doc.semantic.radius {
        let flag = if spec.status.as_deref() == Some("provisional") {
            " · provisional"
        } else {
            ""
        };
        out.push_str(&format!(
            "<div class=\"row\" data-radius=\"{role}\"><div class=\"sw\" style=\"width:6rem;background:var(--page-raised);border-radius:var(--radius-{var})\"></div><span><b>{role}</b> · step {value}{flag} · {desc}</span></div>\n",
            var = kebab(role),
            value = spec.value,
            desc = esc(&spec.description),
        ));
    }
    let target = size(doc, "minTarget")?;
    let bar = size(doc, "playerBar")?;
    let chrome = size(doc, "chrome")?;
    out.push_str(&format!(
        "<div class=\"row\" data-size=\"minTarget\"><div style=\"width:var(--size-min-target);height:var(--size-min-target);background:var(--action-fill)\"></div><span><b>minTarget</b> · step {value} · {desc}</span></div>\n",
        value = target.value,
        desc = esc(&target.description),
    ));
    out.push_str(&format!(
        "<div class=\"row\" data-size=\"playerBar\"><div style=\"width:100%;height:var(--size-player-bar);background:var(--page-surface);border:0.0625rem solid currentColor\"></div><span><b>playerBar</b> · step {value} · {desc}</span></div>\n",
        value = bar.value,
        desc = esc(&bar.description),
    ));
    out.push_str(&format!(
        "<div class=\"row\" data-size=\"chrome\"><div style=\"width:100%;height:var(--size-chrome);background:var(--page-raised);border:0.0625rem solid currentColor\"></div><span><b>chrome</b> · step {value} · {desc}</span></div>\n",
        value = chrome.value,
        desc = esc(&chrome.description),
    ));
    out.push_str("</div>\n</div>\n");
    Ok(out)
}

/// Section 9: four motions with duration, trigger and curve points. Durations
/// print as text; the page sets no animation, so it restates nothing.
fn section_motion(doc: &Doc) -> String {
    let mut out = String::from("<h2>9 · Motion</h2>\n<p>Time after static form. Trigger names come from the token descriptions.</p>\n<div data-theme=\"light\">\n<div class=\"demo\" style=\"background:var(--page-paper);color:var(--text-body)\">\n");
    for (role, spec) in &doc.semantic.motion {
        let curve = match spec.curve.cubic() {
            Some([x1, y1, x2, y2]) => format!("cubic {x1}, {y1}, {x2}, {y2}"),
            None => spec.curve.name.clone(),
        };
        out.push_str(&format!(
            "<div class=\"row\" data-motion=\"{role}\"><span><b>{role}</b> · {duration} ms · {desc} · {curve}</span></div>\n",
            duration = spec.duration,
            desc = esc(&spec.description),
        ));
    }
    out.push_str("</div>\n</div>\n");
    out
}

/// Layers 1 and 2: sections 1–4 and 6–9. Blocks and the boundary note are
/// slice 3; the page must not show what the tokens cannot yet back.
pub fn emit_specimen(doc: &Doc, fresh: &Freshness) -> Result<String, String> {
    let mut out = head("Calm Editorial specimen · layers 1–2");
    out.push_str(&format!("<p class=\"banner\">{}</p>\n", banner(fresh)));
    out.push_str("<h1>Calm Editorial specimen</h1>\n<p>Layers 1 and 2 from <b>design/tokens.json</b>. Every swatch, bar and row reads the linked CSS file. This page holds no colour, no point size, no platform value.</p>\n");
    out.push_str(&section_modes(doc)?);
    out.push_str(&section_page());
    out.push_str(&section_voice());
    out.push_str(&section_actions());
    out.push_str(&section_type(doc));
    out.push_str(&section_space(doc)?);
    out.push_str(&section_radius(doc)?);
    out.push_str(&section_motion(doc));
    out.push_str("</body>\n</html>\n");
    Ok(out)
}

/// The single entry point. Relative links stay inside one checkout; the
/// research repo has no stable relative path, so those links pin a commit.
pub fn emit_index(fresh: &Freshness) -> Result<String, String> {
    let mut out = head("Calm Editorial specimen · index");
    out.push_str(&format!("<p class=\"banner\">{}</p>\n", banner(fresh)));
    out.push_str(
        "<h1>Specimen index</h1>\n<ul>\n<li><a href=\"specimen.html\">specimen.html</a> · layers 1–2, the page itself.</li>\n<li><a href=\"../generated/tokens.css\">tokens.css</a> · the CSS variables the page reads.</li>\n<li><a href=\"../../docs/design-system.md\">design-system.md</a> · the written system.</li>\n<li><a href=\"../../docs/gloss-samples.html\">gloss-samples.html</a> · the review sheet.</li>\n<li><a href=\"../../docs/adr/\">adr/</a> · architecture decisions.</li>\n</ul>\n<h2>Captures</h2>\n<p>No PNG is committed. Take them locally with <code>ReadLater.app/Contents/MacOS/ReadLater --snapshot &lt;dir&gt;</code> from <code>apps/apple/Sources/App/SnapshotHarness.swift</code>; the harness pins the window to 430 by 760. A release copies the set into <code>evidence/</code>, dated, never edited.</p>\n<h2>Research repo</h2>\n<ul>\n",
    );
    for (name, path) in [
        ("layer-3-components.md", "design/layer-3-components.md"),
        ("token-gaps.md", "design/token-gaps.md"),
    ] {
        out.push_str(&format!(
            "<li><a href=\"{RESEARCH}/blob/{RESEARCH_PIN}/{path}\">{name}</a> · pinned to {RESEARCH_PIN}.</li>\n",
        ));
    }
    out.push_str(&format!(
        "<li><a href=\"{RESEARCH}/tree/{RESEARCH_PIN}/prototypes\">prototypes</a> and <a href=\"{RESEARCH}/tree/{RESEARCH_PIN}/findings\">findings</a> · pinned to {RESEARCH_PIN}.</li>\n<li><a href=\"{RESEARCH}/tree/{RESEARCH_PIN}/evidence\">evidence/</a> · dated, write-once measurements, pinned to {RESEARCH_PIN}.</li>\n</ul>\n</body>\n</html>\n",
    ));
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Doc {
        let json = r##"{
          "primitive": { "color": { "sand.50": "#FFFCF7", "ink.900": "#191C1F", "white": "#FFFFFF", "black": "#000000" } },
          "semantic": {
            "color": {
              "page.paper": { "light": "sand.50", "dark": "ink.900", "description": "Reader background." },
              "ghost.fill": { "light": "white", "dark": "black", "description": "Button fill." }
            },
            "typography": { "body": { "family": "serif", "size": 19, "line": 31, "weight": "regular", "description": "Reader prose." } },
            "space": { "stackGap": { "value": 12, "description": "Card rows." } },
            "radius": { "card": { "value": 12, "description": "Card." } },
            "size": {
              "minTarget": { "value": 44, "description": "Smallest control." },
              "maxLineWidth": { "value": 640, "description": "Measure." },
              "playerBar": { "value": 58, "description": "Bar height." },
              "chrome": { "value": 44, "description": "Top bar." }
            },
            "motion": { "wash": { "duration": 150, "curve": { "name": "linear" }, "description": "Wash word swap." } }
          },
          "platform": { "swift": { "names": { "page.paper": "paper", "ghost.fill": "ghostFill" } } }
        }"##;
        Doc::parse(json).expect("fixture parses")
    }

    fn fresh() -> Freshness {
        Freshness {
            sha: "54f6b16".to_string(),
            date: "2026-11-12".to_string(),
        }
    }

    #[test]
    fn the_banner_names_the_source_commit() {
        assert_eq!(
            banner(&fresh()),
            "Specimen from 54f6b16 on 2026-11-12. Source design/tokens.json."
        );
    }

    #[test]
    fn freshness_reads_git_not_the_clock() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(Path::parent)
            .expect("tools/tokens is two levels below the root");
        let first = freshness_from_git(root).expect("git history reads");
        let second = freshness_from_git(root).expect("git history reads");
        assert_eq!(first.sha, second.sha);
        assert_eq!(first.date, second.date);
        assert_eq!(first.sha.len(), 7);
        assert_eq!(first.date.len(), 10);
    }

    /// A hex, an attached `pt` or an attached `dp` in the page means a value
    /// was copied instead of read through `var()`. Prose from a token
    /// description may name a unit with a space ("44 pt hit row"); the lint
    /// targets machine-readable restatements (`44pt`), not quoted words.
    fn restated(html: &str) -> Vec<String> {
        let bytes = html.as_bytes();
        let mut out = Vec::new();
        for (index, window) in html.char_indices() {
            if window == '#'
                && bytes
                    .get(index + 1..index + 7)
                    .is_some_and(|hex| hex.iter().all(|b| b.is_ascii_hexdigit()))
            {
                out.push(html[index..index + 7].to_string());
            }
            if (window == 'p' && html[index..].starts_with("pt"))
                || (window == 'd' && html[index..].starts_with("dp"))
            {
                let unit = &html[index..index + 2];
                let before = index.checked_sub(1).and_then(|i| bytes.get(i));
                let after = bytes.get(index + 2);
                if before.is_some_and(|b| b.is_ascii_digit())
                    && after.is_none_or(|b| !b.is_ascii_alphanumeric())
                {
                    out.push(unit.to_string());
                }
            }
        }
        out
    }

    #[test]
    fn the_specimen_holds_no_literal() {
        let doc = fixture();
        let html = emit_specimen(&doc, &fresh()).expect("specimen emits");
        assert_eq!(restated(&html), Vec::<String>::new());
    }

    #[test]
    fn the_index_holds_no_literal() {
        let html = emit_index(&fresh()).expect("index emits");
        assert_eq!(restated(&html), Vec::<String>::new());
    }

    #[test]
    fn the_specimen_reads_the_linked_css() {
        let doc = fixture();
        let html = emit_specimen(&doc, &fresh()).expect("specimen emits");
        assert!(html.contains("../generated/tokens.css"));
        assert!(html.contains("var(--page-paper)"));
        assert!(html.contains("var(--type-body-size)"));
    }

    #[test]
    fn both_pages_carry_the_banner() {
        let doc = fixture();
        let line = banner(&fresh());
        let specimen = emit_specimen(&doc, &fresh()).expect("specimen emits");
        let index = emit_index(&fresh()).expect("index emits");
        assert!(specimen.contains(&line));
        assert!(index.contains(&line));
    }
}
