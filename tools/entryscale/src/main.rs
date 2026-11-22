mod fit;
mod oplog;
mod svg;

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;

use fit::{Row, Slope};
use oplog::Log;

const ARMS: [&str; 8] = ["read", "extract", "plan", "invariant", "sha256", "save", "library", "seed"];
/// Real pages repeated for spread: the three named in the entry-wait ticket.
const SPREAD_PAGES: [&str; 3] = ["082-nyt-cooking", "046-atlantic", "092-ft"];
/// Parts of the entry wait that run after the fetch. `plan` excludes the hash,
/// so the hash is added here as its own part. `read` is the whole path, kept as a check.
const TOTAL_PARTS: [&str; 5] = ["extract", "plan", "sha256", "save", "seed"];

#[derive(Default)]
struct Article {
    label: String,
    sweep: String,
    source: String,
    blocks: f64,
    words: f64,
    bytes: f64,
    nodes: f64,
    wpb: f64,
    arms: BTreeMap<String, f64>,
    spread: BTreeMap<String, (f64, f64, f64)>,
}

struct Args {
    svg_dir: Option<PathBuf>,
    paths: Vec<PathBuf>,
}

fn parse_args() -> Result<Args, String> {
    let mut svg_dir = None;
    let mut paths = Vec::new();
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        if arg == "--svg-dir" {
            svg_dir = Some(PathBuf::from(it.next().ok_or("--svg-dir needs a directory")?));
        } else {
            paths.push(PathBuf::from(arg));
        }
    }
    if paths.is_empty() {
        return Err("usage: entryscale [--svg-dir DIR] <oplog.jsonl>...".into());
    }
    Ok(Args { svg_dir, paths })
}

fn median(mut values: Vec<f64>) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mid = values.len() / 2;
    Some(if values.len().is_multiple_of(2) { (values[mid - 1] + values[mid]) / 2.0 } else { values[mid] })
}

fn group(log: &Log) -> BTreeMap<String, Article> {
    let mut articles: BTreeMap<String, Article> = BTreeMap::new();
    for s in &log.samples {
        let entry = articles.entry(s.article.clone()).or_default();
        entry.label = s.article.clone();
        entry.sweep = s.sweep.clone();
        entry.source = s.source.clone();
        entry.blocks = s.blocks;
        entry.words = s.words;
        entry.wpb = s.wpb;
        entry.bytes = s.bytes;
        entry.nodes = s.nodes.unwrap_or(f64::NAN);
        entry.arms.insert(s.arm.clone(), s.ms);
        if let (Some(lo), Some(hi)) = (s.ms_min, s.ms_max) {
            entry.spread.insert(s.arm.clone(), (lo, hi, s.reps.unwrap_or(f64::NAN)));
        }
    }
    for article in articles.values_mut() {
        if TOTAL_PARTS.iter().all(|p| article.arms.contains_key(*p)) {
            let total: f64 = TOTAL_PARTS.iter().map(|p| article.arms[*p]).sum();
            article.arms.insert("total".into(), total);
        }
    }
    articles
}

fn points(articles: &BTreeMap<String, Article>, keep: impl Fn(&Article) -> bool, x: impl Fn(&Article) -> f64, metric: &str) -> Vec<(f64, f64)> {
    articles
        .values()
        .filter(|a| keep(a))
        .filter_map(|a| a.arms.get(metric).map(|v| (x(a), *v)))
        .collect()
}

fn fmt_slope(s: Option<Slope>) -> String {
    match s {
        Some(s) => format!(
            "{:>8.3}   [{:.3}, {:.3}]   n={:<3} {}",
            s.exponent, s.lo, s.hi, s.n, fit::verdict(&s)
        ),
        None => "   not enough points".into(),
    }
}

fn run(args: Args) -> Result<(), String> {
    let mut log = Log::default();
    for path in &args.paths {
        let text = fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        oplog::parse(&text, &mut log)?;
    }
    let articles = group(&log);
    let count = |sweep: &str| articles.values().filter(|a| a.sweep == sweep && a.source == "synthetic").count();
    let real = articles.values().filter(|a| a.source == "file").count();

    println!("Build: {}", log.builds.join(" | "));
    println!(
        "Articles: sweep A={} B={} X={} real={} skipped={}",
        count("A"), count("B"), count("X"), real, log.skipped
    );
    println!();

    println!("Sweep A: exponent of ms against blocks (30 words per block)");
    println!("{:<12} {:>8}   {:<22} verdict", "metric", "exponent", "95% interval");
    for metric in ARMS.iter().copied().chain(["total"]) {
        let pts = points(&articles, |a| a.sweep == "A", |a| a.blocks, metric);
        println!("{:<12} {}", metric, fmt_slope(fit::loglog(&pts)));
    }
    println!();

    println!("Sweep B: exponent of ms against words per block (100 blocks)");
    println!("{:<12} {:>8}   {:<22} verdict", "metric", "exponent", "95% interval");
    for metric in ARMS.iter().copied().chain(["total"]) {
        let pts = points(&articles, |a| a.sweep == "B", |a| a.wpb, metric);
        println!("{:<12} {}", metric, fmt_slope(fit::loglog(&pts)));
    }
    println!();

    println!("Two-term fit on synthetic articles: ms = a + b·words + c·blocks·wpb²");
    println!("{:<12} {:>12} {:>12} {:>14} {:>8} {:>6}", "metric", "a (ms)", "b (ms/word)", "c", "t(c)", "R²");
    for metric in ARMS.iter().copied().chain(["total"]) {
        let rows: Vec<Row> = articles
            .values()
            .filter(|a| a.source == "synthetic")
            .filter_map(|a| {
                a.arms.get(metric).map(|ms| Row { ms: *ms, words: a.words, blocks: a.blocks, wpb: a.wpb })
            })
            .collect();
        match fit::two_term(&rows) {
            Some(f) => println!(
                "{:<12} {:>12.4e} {:>12.6} {:>14.4e} {:>8.2} {:>6.3}",
                metric, f.coef[0], f.coef[1], f.coef[2], f.coef[2] / f.se[2], f.r2
            ),
            None => println!("{metric:<12} not enough points"),
        }
    }
    println!();

    let real_points = points(&articles, |a| a.source == "file", |a| a.words, "total");
    println!("Real pages: total ms against spoken words (n={})", real_points.len());
    let slope = fit::loglog(&real_points);
    println!("  log-log exponent: {}", fmt_slope(slope));
    let regression = {
        let ones = vec![1.0; real_points.len()];
        let xs: Vec<f64> = real_points.iter().map(|p| p.0).collect();
        let ys: Vec<f64> = real_points.iter().map(|p| p.1).collect();
        fit::ols(&[ones, xs], &ys)
    };
    if let Some(f) = &regression {
        println!("  regression: ms = {:.4} + {:.6}·words   R² = {:.4}", f.coef[0], f.coef[1], f.r2);
    }
    println!();

    println!("Real pages by stage: ms = a + b·words");
    println!("{:<12} {:>12} {:>14} {:>8} {:>6}", "metric", "a (ms)", "b (ms/word)", "R²", "n");
    for metric in ARMS.iter().copied().chain(["total"]) {
        let pts = points(&articles, |a| a.source == "file", |a| a.words, metric);
        match linear(&pts) {
            Some(f) => println!("{:<12} {:>12.4} {:>14.6} {:>8.3} {:>6}", metric, f.coef[0], f.coef[1], f.r2, pts.len()),
            None => println!("{metric:<12} not enough points"),
        }
    }
    println!();

    println!("Real pages: ms = a + b·HTML bytes");
    for metric in ["extract", "plan", "total"] {
        let pts = points(&articles, |a| a.source == "file", |a| a.bytes, metric);
        match linear(&pts) {
            Some(f) => println!("{:<12} {:>12.4} {:>14.3e} {:>8.3} {:>6}", metric, f.coef[0], f.coef[1], f.r2, pts.len()),
            None => println!("{metric:<12} not enough points"),
        }
    }
    println!();

    let mut smallest: Vec<&Article> = articles.values().filter(|a| a.source == "file").collect();
    smallest.sort_by(|a, b| a.words.partial_cmp(&b.words).unwrap_or(std::cmp::Ordering::Equal));
    println!("Smallest real pages, ms per stage (by words):");
    println!("{:<28} {:>7} {:>7} {:>9} {:>9} {:>9} {:>9} {:>9} {:>9}", "article", "words", "blocks", "extract", "plan", "sha256", "save", "seed", "total");
    for a in smallest.iter().take(15) {
        let cell = |m: &str| a.arms.get(m).map_or("-".to_string(), |v| format!("{v:.3}"));
        println!("{:<28} {:>7.0} {:>7.0} {:>9} {:>9} {:>9} {:>9} {:>9} {:>9}", a.label, a.words, a.blocks, cell("extract"), cell("plan"), cell("sha256"), cell("save"), cell("seed"), cell("total"));
    }
    println!();

    let mut ratios_extract = Vec::new();
    let mut ratios_plan = Vec::new();
    let mut by_article: BTreeMap<String, Vec<oplog::Split>> = BTreeMap::new();
    for split in &log.splits {
        by_article.entry(split.article.clone()).or_default().push(split.clone());
    }
    for (label, splits) in &by_article {
        let Some(article) = articles.get(label) else { continue };
        if let (Some(e), Some(p)) = (median(splits.iter().map(|s| s.extract_ms).collect()), article.arms.get("extract")) {
            ratios_extract.push(e / p);
        }
        if let (Some(pl), Some(sh)) = (median(splits.iter().map(|s| s.plan_ms).collect()), article.arms.get("plan")) {
            let hash = article.arms.get("sha256").copied().unwrap_or(0.0);
            ratios_plan.push(pl / (sh + hash));
        }
    }
    println!("Telemetry cross-check (median of ratios, 1.0 agrees):");
    println!("  extract: telemetry / probe = {:.3} (n={})", median(ratios_extract.clone()).unwrap_or(f64::NAN), ratios_extract.len());
    println!("  plan:    telemetry / (probe plan + sha256) = {:.3} (n={})", median(ratios_plan.clone()).unwrap_or(f64::NAN), ratios_plan.len());
    println!();

    let real: Vec<&Article> = articles.values().filter(|a| a.source == "file").collect();

    println!("Real pages: extract ms = a + b·HTML bytes + c·nodes");
    let node_rows: Vec<&Article> = real.iter().copied().filter(|a| a.arms.contains_key("extract") && a.nodes.is_finite()).collect();
    let ones = vec![1.0; node_rows.len()];
    let bytes_col: Vec<f64> = node_rows.iter().map(|a| a.bytes).collect();
    let nodes_col: Vec<f64> = node_rows.iter().map(|a| a.nodes).collect();
    let extract_col: Vec<f64> = node_rows.iter().map(|a| a.arms["extract"]).collect();
    match fit::ols(&[ones, bytes_col, nodes_col], &extract_col) {
        Some(f) => println!(
            "  a = {:.3} ms, b = {:.4e} ms/byte, c = {:.4e} ms/node, t(c) = {:.2}, R² = {:.4}, n = {}",
            f.coef[0], f.coef[1], f.coef[2], f.coef[2] / f.se[2], f.r2, node_rows.len()
        ),
        None => println!("  not enough points"),
    }
    println!();

    println!("Library open, real pages (ms, medians):");
    let lib_rows: Vec<&Article> = real.iter().copied().filter(|a| a.arms.contains_key("library") && a.arms.contains_key("total")).collect();
    let library: Vec<f64> = lib_rows.iter().map(|a| a.arms["library"]).collect();
    let total: Vec<f64> = lib_rows.iter().map(|a| a.arms["total"]).collect();
    let share: Vec<f64> = lib_rows.iter().map(|a| a.arms["library"] / a.arms["total"]).collect();
    println!(
        "  library {:.3}, entry total {:.3}, library / total {:.4}, n = {}",
        median(library).unwrap_or(f64::NAN),
        median(total).unwrap_or(f64::NAN),
        median(share).unwrap_or(f64::NAN),
        lib_rows.len()
    );
    println!();

    println!("Spread on repeated pages: median [min, max] reps");
    for label in SPREAD_PAGES {
        let Some(a) = articles.values().find(|a| a.label == label) else {
            println!("  {label}: not in this oplog");
            continue;
        };
        for arm in ["extract", "total"] {
            if let (Some(m), Some((lo, hi, reps))) = (a.arms.get(arm), a.spread.get(arm)) {
                println!("  {:<16} {:<8} {:>10.3} [{:.3}, {:.3}] reps={}", label, arm, m, lo, hi, reps);
            }
        }
    }
    println!();

    let tiny: Vec<&Article> = articles.values().filter(|a| a.sweep == "T").collect();
    let tiny_extract: Vec<f64> = tiny.iter().filter_map(|a| a.arms.get("extract").copied()).collect();
    let tiny_bytes: f64 = median(tiny.iter().map(|a| a.bytes).collect()).unwrap_or(f64::NAN);
    println!("1 kB pages (sweep T, n = {}):", tiny.len());
    match (median(tiny_extract), linear(&points(&articles, |a| a.source == "file", |a| a.bytes, "extract"))) {
        (Some(m), Some(f)) => println!(
            "  measured extract median {:.3} ms at {:.0} bytes; bytes-only fit predicts {:.3} ms (intercept {:.3} ms)",
            m, tiny_bytes, f.coef[0] + f.coef[1] * tiny_bytes, f.coef[0]
        ),
        _ => println!("  not enough points"),
    }
    println!();

    let h1 = fit::loglog(&points(&articles, |a| a.sweep == "A", |a| a.blocks, "total")).map(|s| fit::verdict(&s)).unwrap_or("not enough points");
    let h2 = fit::loglog(&points(&articles, |a| a.sweep == "B", |a| a.wpb, "invariant")).map(|s| fit::verdict(&s)).unwrap_or("not enough points");
    let h3 = fit::loglog(&real_points).map(|s| fit::verdict(&s)).unwrap_or("not enough points");
    println!("H1 total entry cost linear in blocks (sweep A): {h1}");
    println!("H2 invariant cost quadratic in words per block (sweep B): {h2}");
    println!("H3 total entry cost linear in words (real pages): {h3}");

    if let Some(dir) = &args.svg_dir {
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        let a_pts = points(&articles, |a| a.sweep == "A", |a| a.blocks, "total");
        let b_pts = points(&articles, |a| a.sweep == "B", |a| a.wpb, "invariant");
        let line = regression.as_ref().map(|f| (f.coef[0], f.coef[1]));
        let files = [
            ("sweep-a-total.svg", svg::scatter(&a_pts, None, "blocks (30 words each)", "total ms")),
            ("sweep-b-invariant.svg", svg::scatter(&b_pts, None, "words per block (100 blocks)", "invariant ms")),
            ("real-total-words.svg", svg::scatter(&real_points, line, "spoken words", "total ms")),
        ];
        for (name, body) in files {
            fs::write(dir.join(name), body).map_err(|e| format!("{name}: {e}"))?;
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    match parse_args().and_then(run) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

fn linear(points: &[(f64, f64)]) -> Option<fit::Ols> {
    let ones = vec![1.0; points.len()];
    let xs: Vec<f64> = points.iter().map(|p| p.0).collect();
    let ys: Vec<f64> = points.iter().map(|p| p.1).collect();
    fit::ols(&[ones, xs], &ys)
}
