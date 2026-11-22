mod fit;
mod oplog;
mod svg;

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;

use fit::{Row, Slope};
use oplog::{Log, Sample};

const ARMS: [&str; 7] = ["read", "extract", "plan", "invariant", "sha256", "save", "seed"];
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
    wpb: f64,
    arms: BTreeMap<String, f64>,
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
    for Sample { sweep, source, article, arm, blocks, words, wpb, ms, .. } in &log.samples {
        let entry = articles.entry(article.clone()).or_default();
        entry.label = article.clone();
        entry.sweep = sweep.clone();
        entry.source = source.clone();
        entry.blocks = *blocks;
        entry.words = *words;
        entry.wpb = *wpb;
        entry.arms.insert(arm.clone(), *ms);
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
