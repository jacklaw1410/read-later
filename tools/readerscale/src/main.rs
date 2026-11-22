//! Fits the `probe.sample` events written by `ReaderScalingProbeTests`.
//!
//! Usage: `readlater-readerscale [--svg-dir DIR] OPLOG.jsonl...`
//!
//! Prints one row per component, then the verdict on each hypothesis in issue
//! #41. Writes `DIR/<component>.svg` with the samples and the word-count
//! regression line.
//!
//! Corpora: `rows` (rows sweep at 12 words per block), `grid` (rows at 5 and 40
//! words per block), `sweep` (400 rows, 1 to 100 words per block), `mixed`,
//! `real` (committed fixtures) and `micro` (oplog overhead, not fitted).

use serde_json::Value;
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs;
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq)]
struct Sample {
    corpus: String,
    component: String,
    rows: f64,
    words: f64,
    ms: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Fit {
    slope: f64,
    intercept: f64,
    r2: f64,
    n: usize,
}

struct Summary {
    line: Option<Fit>,
    exp_rows: Option<f64>,
    exp_words: Option<f64>,
    two: Option<[f64; 3]>,
    r2_two: Option<f64>,
    n: usize,
}

fn parse_oplog(text: &str) -> Vec<Sample> {
    text.lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|event| event["event"] == "probe.sample")
        .filter_map(|event| {
            let fields = &event["fields"];
            let number = |key: &str| fields[key].as_str()?.parse::<f64>().ok();
            Some(Sample {
                corpus: fields["corpus"].as_str()?.to_string(),
                component: fields["component"].as_str()?.to_string(),
                rows: number("rows")?,
                words: number("words")?,
                ms: number("ms")?,
            })
        })
        .collect()
}

/// Ordinary least squares on `(x, y)` pairs. None when x has no spread.
fn ols(points: &[(f64, f64)]) -> Option<Fit> {
    let n = points.len();
    if n < 2 {
        return None;
    }
    let mean_x = points.iter().map(|p| p.0).sum::<f64>() / n as f64;
    let mean_y = points.iter().map(|p| p.1).sum::<f64>() / n as f64;
    let sxx: f64 = points.iter().map(|p| (p.0 - mean_x).powi(2)).sum();
    let sxy: f64 = points.iter().map(|p| (p.0 - mean_x) * (p.1 - mean_y)).sum();
    let syy: f64 = points.iter().map(|p| (p.1 - mean_y).powi(2)).sum();
    if sxx == 0.0 {
        return None;
    }
    let slope = sxy / sxx;
    let intercept = mean_y - slope * mean_x;
    let residual: f64 = points
        .iter()
        .map(|p| (p.1 - (intercept + slope * p.0)).powi(2))
        .sum();
    let r2 = if syy == 0.0 {
        1.0
    } else {
        1.0 - residual / syy
    };
    Some(Fit {
        slope,
        intercept,
        r2,
        n,
    })
}

/// Power-law exponent k in `y = c * x^k`: the slope of log y on log x.
fn exponent(points: &[(f64, f64)]) -> Option<f64> {
    let logs: Vec<(f64, f64)> = points
        .iter()
        .filter(|p| p.0 > 0.0 && p.1 > 0.0)
        .map(|p| (p.0.ln(), p.1.ln()))
        .collect();
    ols(&logs).map(|fit| fit.slope)
}

/// Least squares for `y = a + c1 * x1 + c2 * x2`. Returns `[a, c1, c2]`.
/// Solves the 3 by 3 normal equations by Gaussian elimination with pivoting.
fn ols_two(points: &[(f64, f64, f64)]) -> Option<[f64; 3]> {
    if points.len() < 3 {
        return None;
    }
    let mut m = [[0.0f64; 4]; 3];
    for &(x1, x2, y) in points {
        let row = [1.0, x1, x2];
        for i in 0..3 {
            for j in 0..3 {
                m[i][j] += row[i] * row[j];
            }
            m[i][3] += row[i] * y;
        }
    }
    for col in 0..3 {
        let pivot = (col..3).max_by(|&a, &b| m[a][col].abs().total_cmp(&m[b][col].abs()))?;
        if m[pivot][col].abs() < 1e-12 {
            return None;
        }
        m.swap(col, pivot);
        for row in 0..3 {
            if row != col {
                let factor = m[row][col] / m[col][col];
                for k in col..4 {
                    m[row][k] -= factor * m[col][k];
                }
            }
        }
    }
    Some([m[0][3] / m[0][0], m[1][3] / m[1][1], m[2][3] / m[2][2]])
}

fn exp_or_dash(value: Option<f64>) -> String {
    value.map_or("-".to_string(), |k| format!("{k:.3}"))
}

fn by_component(samples: &[Sample]) -> BTreeMap<String, Vec<Sample>> {
    let mut map: BTreeMap<String, Vec<Sample>> = BTreeMap::new();
    for sample in samples.iter().filter(|s| s.corpus != "micro") {
        map.entry(sample.component.clone())
            .or_default()
            .push(sample.clone());
    }
    map
}

fn summarize(samples: &[Sample]) -> Summary {
    let pooled: Vec<(f64, f64)> = samples.iter().map(|s| (s.words, s.ms)).collect();
    let rows_pts: Vec<(f64, f64)> = samples
        .iter()
        .filter(|s| s.corpus == "rows")
        .map(|s| (s.rows, s.ms))
        .collect();
    let sweep_pts: Vec<(f64, f64)> = samples
        .iter()
        .filter(|s| s.corpus == "sweep")
        .map(|s| (s.words, s.ms))
        .collect();
    let two_pts: Vec<(f64, f64, f64)> = samples
        .iter()
        .filter(|s| s.corpus == "rows" || s.corpus == "grid")
        .map(|s| (s.rows * s.rows, s.words, s.ms))
        .collect();
    let two = ols_two(&two_pts);
    let r2_two = two.map(|c| {
        let mean = two_pts.iter().map(|p| p.2).sum::<f64>() / two_pts.len() as f64;
        let total: f64 = two_pts.iter().map(|p| (p.2 - mean).powi(2)).sum();
        let resid: f64 = two_pts
            .iter()
            .map(|p| (p.2 - (c[0] + c[1] * p.0 + c[2] * p.1)).powi(2))
            .sum();
        1.0 - resid / total
    });
    Summary {
        line: ols(&pooled),
        exp_rows: exponent(&rows_pts),
        exp_words: exponent(&sweep_pts),
        two,
        r2_two,
        n: pooled.len(),
    }
}

fn report(components: &BTreeMap<String, Vec<Sample>>) {
    println!(
        "{:<18} {:>11} {:>10} {:>7} {:>5}  {:>9} {:>9}  {:>12} {:>11} {:>8}",
        "component",
        "ms/word",
        "intercept",
        "R2",
        "n",
        "exp_rows",
        "exp_words",
        "c_rows2",
        "c_words",
        "R2_2term"
    );
    for (name, samples) in components {
        let s = summarize(samples);
        println!(
            "{:<18} {:>11.6} {:>10.4} {:>7.3} {:>5}  {:>9} {:>9}  {:>12} {:>11} {:>8}",
            name,
            s.line.map_or(f64::NAN, |f| f.slope),
            s.line.map_or(f64::NAN, |f| f.intercept),
            s.line.map_or(f64::NAN, |f| f.r2),
            s.n,
            exp_or_dash(s.exp_rows),
            exp_or_dash(s.exp_words),
            s.two.map_or("-".to_string(), |c| format!("{:.3e}", c[1])),
            s.two.map_or("-".to_string(), |c| format!("{:.3e}", c[2])),
            s.r2_two.map_or("-".to_string(), |r| format!("{r:.3}")),
        );
    }
    println!();
    println!("ms/word: slope of ms on words, all articles pooled (ms per word).");
    println!(
        "exp_rows: k in ms = c * rows^k, rows corpus (12 words per block). For footnote.rowwise it mixes linear and quadratic terms."
    );
    println!("exp_words: k in ms = c * words^k, sweep corpus (400 rows).");
    println!(
        "c_rows2, c_words: coefficients of ms = a + c_rows2 * rows^2 + c_words * words, rows and grid corpora."
    );
    println!("R2_2term: fit quality of that two-term model.");
    println!();
    println!("Hypotheses (issue #41):");
    for line in verdicts(components) {
        println!("{line}");
    }
}

/// The rowwise arm mixes a linear word term with a quadratic row term, so its
/// one-variable exponent sits between 1 and 2. H1 therefore rests on the
/// two-term fit and on the share of the quadratic term at the largest article.
fn verdicts(components: &BTreeMap<String, Vec<Sample>>) -> Vec<String> {
    let mut out = Vec::new();
    if let Some(samples) = components.get("footnote.rowwise") {
        let s = summarize(samples);
        out.push(match (s.two, s.r2_two) {
            (Some(c), Some(r2)) => format!(
                "H1 footnote.rowwise, quadratic term: c_rows2 {:.3e} > 0 and R2_2term {r2:.3} >= 0.95: {}",
                c[1],
                pass(c[1] > 0.0 && r2 >= 0.95)
            ),
            _ => "H1 footnote.rowwise, quadratic term: no fit, not decided".to_string(),
        });
        out.push(match (s.two, largest_rows(samples)) {
            (Some(c), Some(big)) => {
                let share = c[1] * big.rows * big.rows / big.ms;
                format!(
                    "H1 footnote.rowwise, quadratic share at {} rows: {share:.3} >= 0.5: {}",
                    big.rows,
                    pass(share >= 0.5)
                )
            }
            _ => "H1 footnote.rowwise, quadratic share: no fit, not decided".to_string(),
        });
    }
    if let Some(s) = components.get("footnote.once").map(|v| summarize(v)) {
        out.push(band(
            "H1 footnote.once, rows exponent",
            s.exp_rows,
            0.8,
            1.2,
        ));
    }
    for name in ["meta.count", "wash.scan"] {
        if let Some(s) = components.get(name).map(|v| summarize(v)) {
            out.push(band(
                &format!("H2 {name}, words exponent"),
                s.exp_words,
                0.8,
                1.2,
            ));
        }
    }
    out
}

fn largest_rows(samples: &[Sample]) -> Option<&Sample> {
    samples
        .iter()
        .filter(|s| s.corpus == "rows")
        .max_by(|a, b| a.rows.total_cmp(&b.rows))
}

fn band(label: &str, value: Option<f64>, low: f64, high: f64) -> String {
    match value {
        Some(v) => format!(
            "{label} {v:.3} in [{low}, {high}]: {}",
            pass((low..=high).contains(&v))
        ),
        None => format!("{label}: no fit, not decided"),
    }
}

fn pass(ok: bool) -> &'static str {
    if ok { "pass" } else { "fail" }
}

fn svg(name: &str, samples: &[Sample]) -> String {
    let (w, h, pad) = (640.0, 420.0, 56.0);
    let max_x = samples.iter().map(|s| s.words).fold(1.0, f64::max);
    let max_y = samples.iter().map(|s| s.ms).fold(1e-9, f64::max);
    let x = |v: f64| pad + v / max_x * (w - 2.0 * pad);
    let y = |v: f64| h - pad - v / max_y * (h - 2.0 * pad);
    let mut out = String::new();
    let _ = writeln!(
        out,
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" font-family="sans-serif" font-size="12">"#
    );
    let _ = writeln!(
        out,
        r#"<text x="{pad}" y="20" font-size="14">{name}: ms per render vs spoken words</text>"#
    );
    let _ = writeln!(
        out,
        r#"<line x1="{pad}" y1="{0}" x2="{1}" y2="{0}" stroke="black"/>"#,
        h - pad,
        w - pad
    );
    let _ = writeln!(
        out,
        r#"<line x1="{pad}" y1="{pad}" x2="{pad}" y2="{0}" stroke="black"/>"#,
        h - pad
    );
    let colour = |corpus: &str| match corpus {
        "rows" => "#1f77b4",
        "grid" => "#9467bd",
        "sweep" => "#ff7f0e",
        "mixed" => "#2ca02c",
        _ => "#d62728",
    };
    for s in samples {
        let _ = writeln!(
            out,
            r#"<circle cx="{:.1}" cy="{:.1}" r="3.5" fill="{}"/>"#,
            x(s.words),
            y(s.ms),
            colour(&s.corpus)
        );
    }
    if let Some(fit) = ols(&samples.iter().map(|s| (s.words, s.ms)).collect::<Vec<_>>()) {
        let (x0, x1) = (0.0, max_x);
        let _ = writeln!(
            out,
            r#"<line x1="{:.1}" y1="{:.1}" x2="{:.1}" y2="{:.1}" stroke="black" stroke-dasharray="4 3"/>"#,
            x(x0),
            y(fit.intercept + fit.slope * x0),
            x(x1),
            y(fit.intercept + fit.slope * x1)
        );
        let _ = writeln!(
            out,
            r#"<text x="{0}" y="{1}">ms = {2:.4} + {3:.5} * words, R2 {4:.3}</text>"#,
            pad + 8.0,
            pad + 14.0,
            fit.intercept,
            fit.slope,
            fit.r2
        );
    }
    out.push_str("</svg>\n");
    out
}

fn main() {
    let mut args = std::env::args().skip(1);
    let mut svg_dir: Option<PathBuf> = None;
    let mut inputs: Vec<PathBuf> = Vec::new();
    while let Some(arg) = args.next() {
        if arg == "--svg-dir" {
            svg_dir = args.next().map(PathBuf::from);
        } else {
            inputs.push(PathBuf::from(arg));
        }
    }
    if inputs.is_empty() {
        eprintln!("usage: readlater-readerscale [--svg-dir DIR] OPLOG.jsonl...");
        std::process::exit(2);
    }
    let mut samples = Vec::new();
    for path in &inputs {
        let text = fs::read_to_string(path).unwrap_or_else(|e| {
            eprintln!("cannot read {}: {e}", path.display());
            std::process::exit(1);
        });
        samples.extend(parse_oplog(&text));
    }
    if samples.is_empty() {
        eprintln!("no probe.sample events in the input");
        std::process::exit(1);
    }
    let components = by_component(&samples);
    report(&components);
    if let Some(dir) = svg_dir {
        fs::create_dir_all(&dir).expect("create svg dir");
        for (name, group) in &components {
            let file = dir.join(format!("{}.svg", name.replace('.', "-")));
            fs::write(&file, svg(name, group)).expect("write svg");
            eprintln!("wrote {}", file.display());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ols_recovers_an_exact_line() {
        let pts: Vec<(f64, f64)> = (0..10).map(|x| (x as f64, 2.0 + 3.0 * x as f64)).collect();
        let fit = ols(&pts).expect("fit");
        assert!((fit.slope - 3.0).abs() < 1e-9);
        assert!((fit.intercept - 2.0).abs() < 1e-9);
        assert!((fit.r2 - 1.0).abs() < 1e-9);
    }

    #[test]
    fn ols_two_recovers_a_known_plane() {
        let mut pts = Vec::new();
        for x1 in 1..=6 {
            for x2 in [3.0, 7.0, 11.0, 20.0] {
                let (x1, x2) = (x1 as f64, x2);
                pts.push((x1, x2, 1.5 + 0.25 * x1 - 0.75 * x2));
            }
        }
        let c = ols_two(&pts).expect("solve");
        assert!((c[0] - 1.5).abs() < 1e-9);
        assert!((c[1] - 0.25).abs() < 1e-9);
        assert!((c[2] + 0.75).abs() < 1e-9);
    }

    #[test]
    fn exponent_of_a_square_is_two() {
        let pts: Vec<(f64, f64)> = (1..=50)
            .map(|x| (x as f64, 0.5 * (x as f64).powi(2)))
            .collect();
        assert!((exponent(&pts).expect("exponent") - 2.0).abs() < 1e-9);
    }

    #[test]
    fn exponent_ignores_zero_and_needs_spread() {
        assert_eq!(exponent(&[(0.0, 1.0), (1.0, 0.0)]), None);
        assert_eq!(ols(&[(2.0, 1.0), (2.0, 3.0)]), None);
    }

    #[test]
    fn band_flags_values_outside_the_range() {
        assert!(band("h", Some(1.9), 1.8, 2.2).ends_with("pass"));
        assert!(band("h", Some(1.2), 1.8, 2.2).ends_with("fail"));
        assert!(band("h", None, 1.8, 2.2).ends_with("not decided"));
    }

    #[test]
    fn parse_keeps_only_probe_samples_with_numeric_fields() {
        let text = concat!(
            r#"{"event":"probe.start","fields":{"build":"release"}}"#,
            "\n",
            r#"{"event":"probe.sample","fields":{"corpus":"rows","component":"body.total","rows":"50","words":"600","ms":"1.25"}}"#,
            "\n",
            r#"{"event":"probe.sample","fields":{"corpus":"rows","component":"body.total","rows":"x","words":"600","ms":"1"}}"#,
            "\n",
            "not json\n",
        );
        let samples = parse_oplog(text);
        assert_eq!(samples.len(), 1);
        assert_eq!(samples[0].words, 600.0);
        assert_eq!(samples[0].ms, 1.25);
    }
}
