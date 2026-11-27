//! The visual specimen: layers 1 and 2 as one HTML page, plus an index.
//!
//! The page reads `design/generated/tokens.css` through a link and CSS custom
//! properties. Text takes its size, face, weight and line from one generated
//! class per typography role, so the page never copies a type value. The page
//! body holds no length literal and no hex; a reviewer opens it from a
//! checkout with `file://`, so every same-repo link is relative. Research-repo
//! links pin a commit, because two checkouts share no stable path.

use crate::model::{Doc, ScalarRole};
use crate::naming::kebab;


/// Research-repo links pin this commit. A moving target would break `--check`.
const RESEARCH_PIN: &str = "f3c1e36";
const RESEARCH: &str = "https://github.com/jacklaw1410/read-later-research";

/// `&`, `<`, `>` become entities. Descriptions are token words, not markup.
fn esc(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// Page chrome. Colour, gap and radius read a token through `var()`. Rem and
/// unitless numbers stay only where no token owns the value: the page width,
/// hairline widths, the chip height multiplier and the outline width. The font
/// stacks are the reference's stacks. No font stack is a token, so they live
/// here and not in `tokens.css`, which stays token-only.
const CHROME: &str = r#"
:root{--font-serif:"Iowan Old Style",Palatino,Georgia,serif;--font-sans:-apple-system,BlinkMacSystemFont,"SF Pro Text",Arial,sans-serif;--font-mono:ui-monospace,Menlo,monospace}
body{margin:0 auto;max-width:64rem;padding:var(--breathing-room) var(--screen-gutter);background:var(--page-paper);color:var(--text-body)}
[data-theme]{color:var(--text-body)}
::selection{background:var(--mark-selected);color:var(--text-body)}
:focus-visible{outline:0.125rem solid var(--rule-ring);outline-offset:0.125rem}
a{color:var(--brand-link);text-decoration-thickness:0.0625rem;text-underline-offset:0.125em}
p{margin:0 0 var(--stack-gap);max-width:var(--size-max-line-width);text-wrap:pretty}
h1,h2,h3{margin:0;color:var(--text-body);text-wrap:balance}
h1{margin-bottom:var(--paragraph-gap)}
h2{margin-top:var(--breathing-room);margin-bottom:var(--stack-gap);padding-top:var(--stack-gap);border-top:0.0625rem solid var(--line-hair)}
h3{margin:var(--paragraph-gap) 0 var(--inline-gap);color:var(--text-meta)}
.pair>section{min-width:0}
.scroll{overflow-x:auto}
.lede{color:var(--text-body)}
.masthead{display:flex;flex-wrap:wrap;align-items:flex-start;justify-content:space-between;gap:var(--stack-gap) var(--breathing-room)}
.mode{display:inline-flex;gap:var(--inline-gap);padding:var(--inline-gap);border:0.0625rem solid var(--line-hair);border-radius:var(--radius-button);background:var(--page-surface)}
.mode button{font:inherit;color:var(--text-body);background:transparent;border:0;border-radius:var(--radius-inner);min-height:var(--size-min-target);padding:var(--control-gap) var(--stack-gap);cursor:pointer}
.mode button:hover{background:var(--page-raised)}
.mode button[aria-pressed="true"]{background:var(--action-fill);color:var(--action-ink)}
.num{font-variant-numeric:tabular-nums}
code{font-family:var(--font-mono)}
table{width:100%;border-collapse:collapse}
th,td{padding:var(--inline-gap) var(--control-gap);border-top:0.0625rem solid var(--line-hair);text-align:left;vertical-align:middle;font-weight:normal}
thead th{color:var(--text-meta)}
tbody th{color:var(--text-body)}
.chip{display:inline-block;width:var(--size-min-target);height:calc(var(--stack-gap) * 2);border:0.0625rem solid var(--line-hair);border-radius:var(--radius-chip);vertical-align:middle}
.prims{display:flex;flex-wrap:wrap;gap:var(--control-gap) var(--stack-gap);list-style:none;margin:var(--stack-gap) 0 0;padding:0}
.prims li{display:flex;flex-direction:column;gap:var(--inline-gap);width:calc(var(--size-min-target) * 2)}
.pair{display:grid;grid-template-columns:repeat(auto-fit,minmax(calc(var(--size-max-line-width) / 2),1fr));gap:var(--breathing-room)}
.panel{display:flex;flex-direction:column;gap:var(--stack-gap);padding:var(--stack-gap);border:0.0625rem solid var(--line-hair);background:var(--page-paper)}
.layer{padding:var(--control-gap) var(--stack-gap);border:0.0625rem solid var(--line-hair)}
.layer .layer{margin-top:var(--control-gap)}
.hair{width:100%;margin:0;border:0;border-top:0.0625rem solid var(--line-hair)}
.defs{display:grid;grid-template-columns:repeat(auto-fit,minmax(calc(var(--size-max-line-width) / 3),1fr));gap:var(--inline-gap) var(--breathing-room);margin:0}
.defs dd{margin:0;color:var(--text-meta)}
.defs div{display:flex;flex-direction:column;gap:var(--inline-gap)}
.ibrow{display:flex;flex-wrap:wrap;align-items:center;gap:var(--control-gap)}
.btn{display:inline-flex;align-items:center;box-sizing:border-box;min-height:var(--size-min-target);padding:0 var(--stack-gap);border-radius:var(--radius-button);background:var(--action-fill);color:var(--action-ink)}
.btn-ghost{background:var(--ghost-fill);color:var(--text-body);border:0.0625rem solid var(--line-hair)}
.ib-box{display:block;width:var(--size-min-target);height:var(--size-min-target);border:0.0625rem dashed var(--line-hair);border-radius:var(--radius-button)}
td.sample{width:calc(var(--size-min-target) * 4)}
@media (max-width:36rem){.look-table thead{display:none}.look-table tbody tr{display:grid;grid-template-columns:auto 1fr;column-gap:var(--control-gap);align-items:center}.look-table th,.look-table td{border-top:0;padding:var(--inline-gap) 0}.look-table tbody tr{border-top:0.0625rem solid var(--line-hair);padding:var(--inline-gap) 0}.look-table th{grid-column:2;grid-row:1}.look-table td.sample{grid-column:1;grid-row:1 / span 2;width:auto}.look-table td:nth-child(3){grid-column:2;grid-row:2}.look-table td:nth-child(4){grid-column:1 / -1;grid-row:3;padding-top:var(--control-gap)}}
.ib{display:inline-flex;align-items:center;justify-content:center;flex:none;width:var(--size-min-target);height:var(--size-min-target);padding:0;border:0;border-radius:var(--radius-button);cursor:pointer}
.ib-quiet{background:transparent;color:var(--text-body)}
.ib-filled{background:var(--action-fill);color:var(--action-ink)}
.ib-quiet:active{opacity:0.7}
.ib-filled:active{opacity:0.82}
.ib svg{width:var(--type-icon-size);height:var(--type-icon-size);fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.ib svg.solid{fill:currentColor;stroke:none}
.ib-circle{border-radius:var(--radius-pill)}
.saved{border-left:0.25rem solid var(--mark-saved)}
.ring{outline:0.125rem solid var(--mark-coincide)}
.ring-paused{outline:0.125rem solid var(--rule-ring)}
.scale{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,2fr) auto;align-items:center;gap:var(--control-gap);padding:var(--inline-gap) 0;border-top:0.0625rem solid var(--line-hair)}
.scale p{margin:0;color:var(--text-meta)}
.track{display:block;height:var(--control-gap);background:var(--page-raised);border-radius:var(--radius-chip)}
.bar{display:block;height:100%;background:var(--brand-link);border-radius:var(--radius-chip)}
.tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(calc(var(--size-max-line-width) / 4),1fr));gap:var(--stack-gap)}
figure{margin:0;display:flex;flex-direction:column;align-items:flex-start;gap:var(--control-gap)}
figcaption{display:flex;flex-direction:column;gap:var(--inline-gap)}
figcaption span{color:var(--text-meta)}
.shape{display:block;width:var(--size-min-target);height:var(--size-min-target);background:var(--chip-surface);border:0.0625rem solid var(--line-hair)}
.wide{width:100%}
"#;

/// Weight names the validator allows, with the CSS number each one stands for.
const WEIGHTS: [(&str, u16); 4] = [
    ("regular", 400),
    ("medium", 500),
    ("semibold", 600),
    ("bold", 700),
];

fn weight_number(name: &str) -> Result<u16, String> {
    WEIGHTS
        .iter()
        .find(|(known, _)| *known == name)
        .map(|(_, number)| *number)
        .ok_or_else(|| format!("unknown weight {name:?}"))
}

/// Family names select one of the stacks in `CHROME`. Any other name fails the
/// build, so a new family cannot render in a fallback face without notice.
fn check_family(family: &str) -> Result<(), String> {
    match family {
        "serif" | "sans" | "mono" => Ok(()),
        other => Err(format!("unknown family {other:?}")),
    }
}

/// One class per typography role, generated from its token. The page styles
/// text only through `class="t-<role>"`, so no size, face, weight or line is
/// copied into the page.
fn type_classes(doc: &Doc) -> Result<String, String> {
    let mut out = String::new();
    for (role, spec) in &doc.semantic.typography {
        let k = kebab(role);
        check_family(&spec.family)?;
        let weight = weight_number(&spec.weight)?;
        let line = if spec.line.is_some() {
            format!("var(--type-{k}-line)")
        } else {
            // No token owns a line for this role. A unitless ratio keeps the
            // text from collapsing onto its own leading.
            "1.5".to_string()
        };
        out.push_str(&format!(
            ".t-{k}{{font-family:var(--font-{family});font-size:var(--type-{k}-size);font-weight:{weight};line-height:{line}",
            family = spec.family,
        ));
        if spec.tracking.is_some() {
            out.push_str(&format!(";letter-spacing:var(--type-{k}-tracking)"));
        }
        out.push_str("}\n");
    }
    Ok(out)
}

fn head(title: &str, types: &str) -> String {
    format!(
        "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>{title}</title>\n<link rel=\"stylesheet\" href=\"../generated/tokens.css\">\n<style>{types}{CHROME}</style>\n</head>\n<body class=\"t-note\">\n"
    )
}

/// A `<code>` element that prints a token name in the mono role.
fn code(name: &str) -> String {
    format!("<code class=\"t-code\">{}</code>", esc(name))
}

/// A colour chip that reads one semantic role. `theme` pins the mode the chip
/// resolves in, so light and dark chips can sit side by side in one row.
fn chip(var: &str, theme: Option<&str>) -> String {
    let attr = theme
        .map(|mode| format!(" data-theme=\"{mode}\""))
        .unwrap_or_default();
    format!("<span class=\"chip\"{attr} style=\"background:var(--{var})\"></span>")
}

/// Section 1: each semantic role on one row, light and dark side by side, then
/// the primitive chips. A primitive has no mode, so its chips never change.
fn section_colour(doc: &Doc) -> String {
    let mut out = String::from(
        "<section>\n<h2>1 · Mode switch</h2>\n<p>Mode governs every semantic colour. Each row shows light and dark side by side.</p>\n<div class=\"scroll\" tabindex=\"0\" role=\"region\" aria-label=\"Semantic colour roles\">\n<table>\n<thead><tr><th>Role</th><th>Light</th><th>Dark</th><th>Use</th></tr></thead>\n<tbody>\n",
    );
    for (role, entry) in &doc.semantic.color {
        let var = kebab(role);
        out.push_str(&format!(
            "<tr data-role=\"{role}\"><th scope=\"row\">{name}</th><td>{light}</td><td>{dark}</td><td>{desc}</td></tr>\n",
            name = code(role),
            light = chip(&var, Some("light")),
            dark = chip(&var, Some("dark")),
            desc = esc(&entry.description),
        ));
    }
    out.push_str(
        "</tbody>\n</table>\n</div>\n<h3>Layer 1 · primitives</h3>\n<p>Raw values with no meaning. A primitive belongs to no mode, so each chip keeps its colour in light and dark.</p>\n<ul class=\"prims\">\n",
    );
    for name in doc.primitive.color.keys() {
        out.push_str(&format!(
            "<li data-primitive=\"{name}\"><span class=\"chip\" style=\"background:var(--primitive-{var})\"></span><code class=\"t-mono\">{name}</code></li>\n",
            var = kebab(name),
        ));
    }
    out.push_str("</ul>\n</section>\n");
    out
}

/// Section 2: paper, surface and raised as nested layers, then body text in
/// the page's own roles.
fn section_page() -> String {
    String::from(
        r#"<section>
<h2>2 · Page and text</h2>
<p>Foundation before accents. Paper is the page, surface holds cards, raised is reserved.</p>
<div class="panel" data-theme="light">
<div class="layer" style="background:var(--page-paper)"><code class="t-code">page.paper</code> · Reader and entry background.
<div class="layer" style="background:var(--page-surface)"><code class="t-code">page.surface</code> · Card, player bar, chrome.
<div class="layer" style="background:var(--page-raised)"><code class="t-code">page.raised</code> · No view uses it; the token specimen does.</div>
</div>
</div>
<p class="t-body" style="color:var(--text-body)">Body text reads here. The wash will mark the spoken word.</p>
<p class="t-caption" style="color:var(--text-meta)">Meta line · provenance · clock</p>
<hr class="hair">
<p><code class="t-code">line.hair</code> · Divider and field border.</p>
</div>
</section>
"#,
    )
}

/// Section 3: the spoken word, the tapped word, their overlap, the frozen wash.
fn section_voice() -> String {
    String::from(
        r#"<section>
<h2>3 · Voice and tap</h2>
<p>The core interaction. The voice marks one word, a tap marks another, and a tap on the spoken word rings it.</p>
<div class="panel t-body" data-theme="light" style="color:var(--text-body)">
<p><span>The voice is </span><span style="background:var(--wash-fill);color:var(--wash-ink)">on this word</span><span>, the reader </span><span style="background:var(--mark-selected)">tapped that one</span><span>, and </span><span class="ring" style="background:var(--wash-fill);color:var(--wash-ink)">this one is both</span><span>.</span></p>
<p><span>Audio paused: </span><span class="ring-paused" style="background:var(--rule-paused)">the wash freezes here</span><span>.</span></p>
</div>
<dl class="defs">
<div><dt>{wash_fill} + {wash_ink}</dt><dd>The spoken word.</dd></div>
<div><dt>{mark_selected}</dt><dd>The tapped word.</dd></div>
<div><dt>{mark_coincide}</dt><dd>Ring when the tap lands on the spoken word.</dd></div>
<div><dt>{rule_paused} + {rule_ring}</dt><dd>The frozen wash.</dd></div>
</dl>
</section>
"#,
    )
    .replace("{wash_fill}", &code("wash.fill"))
    .replace("{wash_ink}", &code("wash.ink"))
    .replace("{mark_selected}", &code("mark.selected"))
    .replace("{mark_coincide}", &code("mark.coincide"))
    .replace("{rule_paused}", &code("rule.paused"))
    .replace("{rule_ring}", &code("rule.ring"))
}

/// Section 4: controls after reading states. Saved marks are tier 2.
fn section_actions() -> String {
    String::from(
        r#"<section>
<h2>4 · Actions and marks</h2>
<p>Controls sit after the reading states. Saved marks are tier 2 and stay out of the flow.</p>
<h3>Text buttons</h3>
<div class="scroll" tabindex="0" role="region" aria-label="Text action looks">
<table class="look-table">
<thead><tr><th>Look</th><th>Sample</th><th>Tokens</th><th>Use</th></tr></thead>
<tbody>
<tr><th scope="row"><code class="t-code">primary</code></th><td class="sample"><span class="btn">Listen</span></td><td><code class="t-code">action.fill</code> · <code class="t-code">action.ink</code></td><td>Primary button. Stays dark in both modes so white ink keeps its contrast.</td></tr>
<tr><th scope="row"><code class="t-code">secondary</code></th><td class="sample"><span class="btn btn-ghost">Later</span></td><td><code class="t-code">ghost.fill</code> · <code class="t-code">line.hair</code> edge</td><td>Secondary button on a card. One hairline edge.</td></tr>
<tr><th scope="row"><code class="t-code">link</code></th><td class="sample"><span style="color:var(--brand-link)"><u>Quoted passage</u></span></td><td><code class="t-code">brand.link</code></td><td>Quote rule, track fill, marker ink.</td></tr>
<tr><th scope="row"><code class="t-code">mark</code></th><td class="sample"><span class="btn saved" style="background:var(--mark-saved-fill);color:var(--text-body)">Kept for study</span></td><td><code class="t-code">mark.saved</code> · <code class="t-code">mark.savedFill</code></td><td>Tier 2, not part of the flow.</td></tr>
</tbody>
</table>
</div>
<h3>Icon buttons</h3>
<p>One action, named by a glyph. The whole 44 pt box takes taps. The glyph is typography.icon.</p>
<div class="scroll" tabindex="0" role="region" aria-label="Icon button looks">
<table class="look-table">
<thead><tr><th>Look</th><th>Sample</th><th>Tokens</th><th>Use</th></tr></thead>
<tbody>
<tr><th scope="row"><code class="t-code">box</code></th><td class="sample"><span class="ib-box" aria-hidden="true"></span></td><td><code class="t-code">size.minTarget</code> · <code class="t-code">radius.button</code></td><td>Smallest control, both axes. Every point of the box takes a tap.</td></tr>
<tr><th scope="row"><code class="t-code">quiet</code></th><td class="sample"><button type="button" class="ib ib-quiet t-icon" aria-label="Back"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7"/></svg></button></td><td><code class="t-code">text.body</code>, no surface</td><td>Top bar, rows, settings. Pressed at 0.7 opacity.</td></tr>
<tr><th scope="row"><code class="t-code">filled</code></th><td class="sample"><button type="button" class="ib ib-filled t-icon" aria-label="Done"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></button></td><td><code class="t-code">action.fill</code> · <code class="t-code">action.ink</code></td><td>Primary action, the same pair as Listen. Pressed at 0.82 opacity.</td></tr>
<tr><th scope="row"><code class="t-code">circle</code></th><td class="sample"><button type="button" class="ib ib-filled ib-circle t-icon" aria-label="Play"><svg class="solid" viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5l11 7-11 7z"/></svg></button></td><td><code class="t-code">action.fill</code> · <code class="t-code">radius.pill</code></td><td>Play only. The one circle.</td></tr>
<tr><th scope="row"><code class="t-code">beside text</code></th><td class="sample"><div class="ibrow"><button type="button" class="ib ib-quiet t-icon" aria-label="Back"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7"/></svg></button><span class="btn">Listen</span></div></td><td><code class="t-code">size.minTarget</code> height on both</td><td>Icon and text buttons share a row and a height.</td></tr>
</tbody>
</table>
</div>
</section>
"#,
    )
}

/// Section 6: every type role, shown with the values its class reads.
fn section_type(doc: &Doc) -> Result<String, String> {
    let mut out = String::from(
        "<section>\n<h2>6 · Type ramp</h2>\n<p>Every role at its real size, face and weight. Each sample is the role's own generated class.</p>\n<div class=\"scroll\" tabindex=\"0\" role=\"region\" aria-label=\"Type roles\">\n<table>\n<thead><tr><th>Role</th><th>Sample</th><th>Size</th><th>Face</th><th>Weight</th><th>Tracking</th><th>Use</th></tr></thead>\n<tbody>\n",
    );
    for (role, spec) in &doc.semantic.typography {
        check_family(&spec.family)?;
        let tracking = spec
            .tracking
            .map(|t| format!("{t} em"))
            .unwrap_or_else(|| "none".to_string());
        out.push_str(&format!(
            "<tr data-type=\"{role}\"><th scope=\"row\">{name}</th><td><span class=\"t-{var}\">Ag</span></td><td class=\"num\">{size}</td><td>{family}</td><td>{weight}</td><td class=\"num\">{tracking}</td><td>{desc}</td></tr>\n",
            name = code(role),
            var = kebab(role),
            size = spec.size,
            family = spec.family,
            weight = spec.weight,
            desc = esc(&spec.description),
        ));
    }
    out.push_str("</tbody>\n</table>\n</div>\n</section>\n");
    Ok(out)
}

/// A size step the page must show. A missing one fails the build, so the page
/// never renders a guessed bar.
fn size<'a>(doc: &'a Doc, role: &str) -> Result<&'a ScalarRole, String> {
    doc.semantic
        .size
        .get(role)
        .ok_or_else(|| format!("size.{role} is required by the specimen"))
}

/// Section 7: each space step as a bar, plus the reading measure. The track
/// behind each bar is the full extent, so a short bar reads as short.
fn section_space(doc: &Doc) -> Result<String, String> {
    let mut out = String::from(
        "<section>\n<h2>7 · Space and measure</h2>\n<p>Each bar is the step itself, read from its CSS variable.</p>\n",
    );
    for (role, spec) in &doc.semantic.space {
        out.push_str(&format!(
            "<div class=\"scale\" data-space=\"{role}\"><div>{name}<p class=\"t-caption\">{desc}</p></div><span class=\"track\"><span class=\"bar\" style=\"width:var(--{var})\"></span></span><span class=\"num t-mono\">{value}</span></div>\n",
            name = code(role),
            var = kebab(role),
            desc = esc(&spec.description),
            value = spec.value,
        ));
    }
    let measure = size(doc, "maxLineWidth")?;
    out.push_str(&format!(
        "<div class=\"scale\" data-space=\"maxLineWidth\"><div>{name}<p class=\"t-caption\">{desc}</p></div><span class=\"track\"><span class=\"bar\" style=\"width:100%\"></span></span><span class=\"num t-mono\">{value}</span></div>\n",
        name = code("maxLineWidth"),
        desc = esc(&measure.description),
        value = measure.value,
    ));
    out.push_str("</section>\n");
    Ok(out)
}

/// Section 8: each radius on a token-sized square, then the three sizes as
/// shapes at their own heights.
fn section_radius(doc: &Doc) -> Result<String, String> {
    let mut out = String::from(
        "<section>\n<h2>8 · Radius and size</h2>\n<p>Shape beside scale. Each tile draws the token, not a copy of it.</p>\n<div class=\"tiles\">\n",
    );
    for (role, spec) in &doc.semantic.radius {
        let flag = if spec.status.as_deref() == Some("provisional") {
            " · provisional"
        } else {
            ""
        };
        out.push_str(&format!(
            "<figure data-radius=\"{role}\"><span class=\"shape\" style=\"border-radius:var(--radius-{var})\"></span><figcaption>{name}<span class=\"num t-mono\">{value}{flag}</span><span class=\"t-caption\">{desc}</span></figcaption></figure>\n",
            name = code(role),
            var = kebab(role),
            value = spec.value,
            desc = esc(&spec.description),
        ));
    }
    for (role, height) in [("minTarget", "--size-min-target"), ("playerBar", "--size-player-bar"), ("chrome", "--size-chrome")] {
        let spec = size(doc, role)?;
        out.push_str(&format!(
            "<figure data-size=\"{role}\"><span class=\"shape wide\" style=\"height:var({height})\"></span><figcaption>{name}<span class=\"num t-mono\">{value}</span><span class=\"t-caption\">{desc}</span></figcaption></figure>\n",
            name = code(role),
            value = spec.value,
            desc = esc(&spec.description),
        ));
    }
    out.push_str("</div>\n</section>\n");
    Ok(out)
}

/// Section 9: four motions with duration, trigger and curve. The page sets no
/// animation, so durations print as text and restate nothing.
fn section_motion(doc: &Doc) -> String {
    let mut out = String::from(
        "<section>\n<h2>9 · Motion</h2>\n<p>Time after static form. The page sets no animation; the platforms read these values.</p>\n<div class=\"scroll\" tabindex=\"0\" role=\"region\" aria-label=\"Motion roles\">\n<table>\n<thead><tr><th>Role</th><th>Duration</th><th>Curve</th><th>Trigger</th></tr></thead>\n<tbody>\n",
    );
    for (role, spec) in &doc.semantic.motion {
        let curve = match spec.curve.cubic() {
            Some([x1, y1, x2, y2]) => format!("cubic {x1}, {y1}, {x2}, {y2}"),
            None => spec.curve.name.clone(),
        };
        out.push_str(&format!(
            "<tr data-motion=\"{role}\"><th scope=\"row\">{name}</th><td class=\"num\">{duration} ms</td><td>{curve}</td><td>{desc}</td></tr>\n",
            name = code(role),
            duration = spec.duration,
            desc = esc(&spec.description),
        ));
    }
    out.push_str("</tbody>\n</table>\n</div>\n</section>\n");
    out
}

/// Layers 1 and 2: sections 1–4 and 6–9, in the same order as before. Blocks
/// and the boundary note are slice 3; the page must not show what the tokens
/// cannot yet back.
pub fn emit_specimen(doc: &Doc) -> Result<String, String> {
    let mut out = head("Calm Editorial specimen · layers 1–2", &type_classes(doc)?);
    out.push_str(&format!(
        "<header class=\"masthead\">\n<div class=\"intro\">\n<h1 class=\"t-title\">Calm Editorial specimen</h1>\n<p class=\"t-body lede\">Layers 1 and 2 of {}. Every value on this page reads a CSS variable from the linked file. The page holds no colour, point size or platform value.</p>\n</div>\n{}\n</header>\n",
        code("design/tokens.json"),
        mode_switch(),
    ));
    out.push_str("<main>\n");
    out.push_str(&section_colour(doc));
    out.push_str("<div class=\"pair\">\n");
    out.push_str(&section_page());
    out.push_str(&section_voice());
    out.push_str("</div>\n");
    out.push_str(&section_actions());
    out.push_str(&section_type(doc)?);
    out.push_str("<div class=\"pair\">\n");
    out.push_str(&section_space(doc)?);
    out.push_str(&section_radius(doc)?);
    out.push_str("</div>\n");
    out.push_str(&section_motion(doc));
    out.push_str("</main>\n");
    out.push_str(MODE_SCRIPT);
    out.push_str("</body>\n</html>\n");
    Ok(out)
}

/// The colour-mode switch. `system` removes `data-theme`, so the page follows
/// the operating system. `light` and `dark` set it on `<html>`, which the
/// generated `tokens.css` reads for the whole document. The switch never
/// names a value; it only chooses which token block applies.
fn mode_switch() -> String {
    String::from(
        r#"<div class="mode" role="group" aria-label="Colour mode">
<button type="button" data-mode="system" aria-pressed="true">System</button>
<button type="button" data-mode="light" aria-pressed="false">Light</button>
<button type="button" data-mode="dark" aria-pressed="false">Dark</button>
</div>"#,
    )
}

/// The one piece of behaviour on the page. It runs from `file://` with no
/// network and no dependency.
const MODE_SCRIPT: &str = r#"<script>
(function () {
  var root = document.documentElement;
  var buttons = document.querySelectorAll("[data-mode]");
  function show(mode) {
    if (mode === "system") {
      root.removeAttribute("data-theme");
    } else {
      root.setAttribute("data-theme", mode);
    }
    buttons.forEach(function (button) {
      button.setAttribute("aria-pressed", String(button.dataset.mode === mode));
    });
  }
  buttons.forEach(function (button) {
    button.addEventListener("click", function () {
      show(button.dataset.mode);
    });
  });
})();
</script>
"#;

/// The single entry point. Relative links stay inside one checkout; the
/// research repo has no stable relative path, so those links pin a commit.
pub fn emit_index(doc: &Doc) -> Result<String, String> {
    let mut out = head("Calm Editorial specimen · index", &type_classes(doc)?);
    out.push_str(&format!(
        "<header class=\"masthead\">\n<div class=\"intro\">\n<h1 class=\"t-title\">Specimen index</h1>\n<p class=\"t-body lede\">The pages, captures and research behind the Calm Editorial system. The written rules live in the design system doc. The pages show what the tokens produce.</p>\n</div>\n{}\n</header>\n",
        mode_switch(),
    ));
    out.push_str("<main>\n");

    out.push_str(
        "<section>\n<h2>1 · Pages</h2>\n<p>Each page reads the generated CSS, so every value traces back to design/tokens.json.</p>\n<div class=\"scroll\" tabindex=\"0\" role=\"region\" aria-label=\"Pages\">\n<table>\n<thead><tr><th>Page</th><th>Holds</th></tr></thead>\n<tbody>\n<tr><th scope=\"row\"><a href=\"specimen.html\"><code class=\"t-code\">specimen.html</code></a></th><td>Layers 1 and 2, the page itself.</td></tr>\n<tr><th scope=\"row\"><a href=\"../generated/tokens.css\"><code class=\"t-code\">tokens.css</code></a></th><td>The CSS variables the page reads.</td></tr>\n<tr><th scope=\"row\"><a href=\"../../docs/design-system.md\"><code class=\"t-code\">design-system.md</code></a></th><td>The written system.</td></tr>\n<tr><th scope=\"row\"><a href=\"../../docs/gloss-samples.html\"><code class=\"t-code\">gloss-samples.html</code></a></th><td>The review sheet.</td></tr>\n<tr><th scope=\"row\"><a href=\"../../docs/adr/\"><code class=\"t-code\">adr/</code></a></th><td>Architecture decisions.</td></tr>\n</tbody>\n</table>\n</div>\n</section>\n",
    );

    out.push_str(
        "<section>\n<h2>2 · Captures</h2>\n<p>No PNG is committed. Take them locally with <code class=\"t-code\">ReadLater.app/Contents/MacOS/ReadLater --snapshot &lt;dir&gt;</code> from <code class=\"t-code\">apps/apple/Sources/App/SnapshotHarness.swift</code>; the harness pins the window to 430 by 760. A release copies the set into <code class=\"t-code\">evidence/</code>, dated, never edited.</p>\n</section>\n",
    );

    out.push_str(&format!(
        "<section>\n<h2>3 · Research repo</h2>\n<p>Every link is pinned to one commit, so the research cannot move under these pages.</p>\n<div class=\"scroll\" tabindex=\"0\" role=\"region\" aria-label=\"Research links\">\n<table>\n<thead><tr><th>Document</th><th>Holds</th><th>Pinned</th></tr></thead>\n<tbody>\n"
    ));
    for (label, path, holds) in [
        ("layer-3-components.md", format!("blob/{RESEARCH_PIN}/design/layer-3-components.md"), "Layer 3 component notes."),
        ("token-gaps.md", format!("blob/{RESEARCH_PIN}/design/token-gaps.md"), "Gaps the tokens do not yet cover."),
        ("prototypes", format!("tree/{RESEARCH_PIN}/prototypes"), "Prototype builds."),
        ("findings", format!("tree/{RESEARCH_PIN}/findings"), "What the prototypes showed."),
        ("evidence/", format!("tree/{RESEARCH_PIN}/evidence"), "Dated, write-once measurements."),
    ] {
        out.push_str(&format!(
            "<tr><th scope=\"row\"><a href=\"{RESEARCH}/{path}\"><code class=\"t-code\">{label}</code></a></th><td>{holds}</td><td><code class=\"t-code\">{RESEARCH_PIN}</code></td></tr>\n"
        ));
    }
    out.push_str("</tbody>\n</table>\n</div>\n</section>\n");

    out.push_str("</main>\n");
    out.push_str(MODE_SCRIPT);
    out.push_str("</body>\n</html>\n");
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use std::path::Path;

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

    /// The real `tokens.json`, not the fixture. The fixture lacks most roles,
    /// so a test over it could not catch a typo in a page variable name.
    fn real_doc() -> Doc {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(Path::parent)
            .expect("tools/tokens is two levels below the root");
        let text = std::fs::read_to_string(root.join("design/tokens.json"))
            .expect("tokens.json reads");
        Doc::parse(&text).expect("tokens.json parses")
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
        let html = emit_specimen(&doc).expect("specimen emits");
        assert_eq!(restated(&html), Vec::<String>::new());
    }

    #[test]
    fn the_index_holds_no_literal() {
        let html = emit_index(&real_doc()).expect("index emits");
        assert_eq!(restated(&html), Vec::<String>::new());
    }

    /// A primitive has no mode. If it slipped into a themed block, a swatch
    /// would change colour with the system setting and the raw layer would
    /// misreport its own value.
    #[test]
    fn a_primitive_never_follows_the_theme() {
        let css = crate::emit::css::emit(&fixture()).expect("css emits");
        assert!(css.contains("--primitive-sand-50: #FFFCF7;"));
        let dark = css
            .find("@media (prefers-color-scheme: dark)")
            .expect("dark block");
        let forced = css.find("[data-theme=\"dark\"]").expect("forced block");
        assert!(!css[dark..forced].contains("--primitive-"));
        assert!(!css[forced..].contains("--primitive-"));
    }

    #[test]
    fn the_primitive_strip_reads_the_raw_layer() {
        let html = emit_specimen(&fixture()).expect("specimen emits");
        assert!(html.contains("data-primitive=\"ink.900\""));
        assert!(html.contains("var(--primitive-ink-900)"));
    }

    #[test]
    fn the_specimen_reads_the_linked_css() {
        let doc = fixture();
        let html = emit_specimen(&doc).expect("specimen emits");
        assert!(html.contains("../generated/tokens.css"));
        assert!(html.contains("var(--page-paper)"));
        assert!(html.contains("var(--type-body-size)"));
    }

    #[test]
    fn the_index_has_no_source_banner() {
        let doc = real_doc();
        let specimen = emit_specimen(&doc).expect("specimen emits");
        let index = emit_index(&doc).expect("index emits");
        assert!(!index.contains("Source design/tokens.json."));
        assert!(!index.contains("Specimen from "));
        assert!(!specimen.contains("Source design/tokens.json."));
    }

    /// The switch names three modes. `system` is the default, so the page
    /// starts with `aria-pressed` on it and no forced `data-theme`.
    #[test]
    fn the_specimen_offers_system_light_and_dark() {
        let html = emit_specimen(&real_doc()).expect("specimen emits");
        for mode in ["system", "light", "dark"] {
            assert!(html.contains(&format!("data-mode=\"{mode}\"")), "no {mode} button");
        }
        assert!(html.contains("data-mode=\"system\" aria-pressed=\"true\""));
        assert!(html.contains("document.documentElement"));
    }


    #[test]
    fn the_index_offers_the_same_mode_switch() {
        let html = emit_index(&real_doc()).expect("index emits");
        for mode in ["system", "light", "dark"] {
            assert!(html.contains(&format!("data-mode=\"{mode}\"")), "no {mode} button");
        }
        assert!(html.contains("document.documentElement"));
    }

    /// Custom properties a stylesheet declares (`--name:`) and reads
    /// (`var(--name`). A name is letters, digits and hyphens.
    fn declared_and_read(text: &str) -> (HashSet<String>, HashSet<String>) {
        let mut declared = HashSet::new();
        let mut read = HashSet::new();
        for (index, _) in text.match_indices("--") {
            let name: String = text[index + 2..]
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '-')
                .collect();
            if name.is_empty() {
                continue;
            }
            if text[index + 2 + name.len()..].starts_with(':') {
                declared.insert(name.clone());
            }
            if text[..index].ends_with("var(") {
                read.insert(name);
            }
        }
        (declared, read)
    }

    #[test]
    fn every_variable_the_page_reads_is_declared() {
        let doc = real_doc();
        let css = crate::emit::css::emit(&doc).expect("css emits");
        let (from_css, _) = declared_and_read(&css);
        for html in [
            emit_specimen(&doc).expect("specimen emits"),
            emit_index(&doc).expect("index emits"),
        ] {
            let (from_page, read) = declared_and_read(&html);
            let declared: HashSet<String> = from_css.union(&from_page).cloned().collect();
            let mut missing: Vec<&String> = read.difference(&declared).collect();
            missing.sort();
            assert!(missing.is_empty(), "read but never declared: {missing:?}");
        }
    }

    /// A number written against a unit, such as `6rem` or `1px`. A unit with a
    /// space before it, as in `44 pt hit row`, is prose and passes. The page
    /// body may not hold a length; the `<style>` block may, for structure.
    fn length_literals(html: &str) -> Vec<String> {
        let body = match (html.find("<style>"), html.find("</style>")) {
            (Some(open), Some(close)) => format!("{}{}", &html[..open], &html[close..]),
            _ => html.to_string(),
        };
        let bytes = body.as_bytes();
        let mut out = Vec::new();
        for unit in ["px", "rem", "em", "pt", "dp"] {
            for (index, _) in body.match_indices(unit) {
                let before = index.checked_sub(1).map(|i| bytes[i]);
                let after = bytes.get(index + unit.len());
                if before.is_some_and(|b| b.is_ascii_digit())
                    && after.is_none_or(|b| !b.is_ascii_alphanumeric())
                {
                    out.push(
                        body.get(index.saturating_sub(4)..index + unit.len())
                            .unwrap_or(unit)
                            .to_string(),
                    );
                }
            }
        }
        out
    }

    #[test]
    fn the_page_body_holds_no_length_literal() {
        let doc = real_doc();
        for html in [
            emit_specimen(&doc).expect("specimen emits"),
            emit_index(&doc).expect("index emits"),
        ] {
            assert_eq!(length_literals(&html), Vec::<String>::new());
        }
    }

    #[test]
    fn the_chrome_reads_calm_editorial_tokens() {
        let html = emit_specimen(&real_doc()).expect("specimen emits");
        for rule in [
            "body{margin:0 auto;max-width:64rem;padding:var(--breathing-room) var(--screen-gutter);background:var(--page-paper)",
            "a{color:var(--brand-link)",
            "[data-theme]{color:var(--text-body)",
            ".t-title{font-family:var(--font-serif)",
            "font-size:var(--type-title-size)",
        ] {
            assert!(html.contains(rule), "missing chrome rule: {rule}");
        }
    }

    /// Every typography role gets a class that reads its token. A role without
    /// one would render in the body face, silently.
    #[test]
    fn every_typography_role_has_a_generated_class() {
        let doc = real_doc();
        let html = emit_specimen(&doc).expect("specimen emits");
        for role in doc.semantic.typography.keys() {
            let class = format!(".t-{}{{", kebab(role));
            assert!(html.contains(&class), "no class for {role}");
            assert!(html.contains(&format!("data-type=\"{role}\"")), "no row for {role}");
        }
    }

    #[test]
    fn a_weight_name_outside_the_map_fails_the_build() {
        assert_eq!(weight_number("semibold"), Ok(600));
        assert!(weight_number("heavy").is_err());
        assert!(check_family("display").is_err());
    }

    /// The font stacks are not a token. Writing them into `tokens.css` would
    /// let a platform value leak into the token-only artifact.
    #[test]
    fn the_font_stacks_stay_out_of_the_token_css() {
        let css = crate::emit::css::emit(&real_doc()).expect("css emits");
        assert!(!css.contains("--font-"));
    }

    #[test]
    fn the_index_uses_the_same_chrome() {
        let index = emit_index(&real_doc()).expect("index emits");
        assert!(index.contains(CHROME));
    }

    #[test]
    fn the_page_has_sections_one_to_four_and_six_to_nine_only() {
        let html = emit_specimen(&real_doc()).expect("specimen emits");
        let numbers: Vec<char> = html
            .match_indices("<h2>")
            .filter_map(|(index, _)| html[index + 4..].chars().next())
            .collect();
        assert_eq!(numbers, vec!['1', '2', '3', '4', '6', '7', '8', '9']);
        assert!(!html.contains("ReaderCard"));
    }
}
