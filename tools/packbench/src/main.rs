//! Repeatable lookup benchmark for the installed dictionary pack.
//!
//! One lookup folds the headword with [`normalize::normalize`] and runs the
//! app's query (`SELECT word, phonetic, pos, gloss FROM words WHERE key =
//! ? LIMIT 1`) on a prepared statement. Sampling happens before timing
//! starts, so the report measures lookups only.
//!
//! ```text
//! readlater-packbench <index.sqlite> [--lookups N] [--json]
//! readlater-packbench --help
//! ```

mod normalize;
mod sample;

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Instant;

use rusqlite::{Connection, OpenFlags};

use normalize::normalize;

const DEFAULT_LOOKUPS: usize = 1000;
const MEMORY_EVERY: usize = 100;

const USAGE: &str = "\
readlater-packbench — benchmark the installed dictionary pack.

Usage:
  readlater-packbench <index.sqlite> [--lookups N] [--json]
  readlater-packbench --help

Sampling (deterministic): order every headword by key, set step to
row_count / N with integer division, and take rows at positions
0, step, 2 * step, and so on. A rerun against the same index picks the
same N headwords. N must not exceed the row count.

One lookup folds the headword as PackIndexStore.normalize does (NFKD,
drop combining marks, curly apostrophes to ', lowercase, trim), then
runs SELECT word, phonetic, pos, gloss FROM words WHERE key = ? LIMIT 1
on a prepared statement, in sample order with no shuffling.

The report shows per-lookup wall time in microseconds (min, p50, p95,
p99, max), total seconds, lookups per second, resident set before the
loop, and peak resident set sampled every 100 lookups. Read the numbers
as one machine, one index, one moment: the first run after a reboot
pages the index in from disk (cold), later runs reuse the page cache
(warm). Compare runs taken under the same condition.";

struct Args {
    index: PathBuf,
    lookups: usize,
    json: bool,
}

struct Stats {
    min_us: u64,
    p50_us: u64,
    p95_us: u64,
    p99_us: u64,
    max_us: u64,
    total_s: f64,
    per_s: f64,
}

fn parse_args(raw: &[String]) -> Result<Option<Args>, String> {
    let mut index: Option<PathBuf> = None;
    let mut lookups = DEFAULT_LOOKUPS;
    let mut json = false;
    let mut iter = raw.iter().peekable();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--help" | "-h" => return Ok(None),
            "--json" => json = true,
            "--lookups" => {
                let value = iter.next().ok_or("--lookups needs a number")?;
                lookups = value
                    .parse::<usize>()
                    .map_err(|_| format!("bad --lookups value: {value}"))?;
                if lookups == 0 {
                    return Err("lookups must be at least 1".to_owned());
                }
            }
            other if other.starts_with('-') => return Err(format!("unknown flag: {other}")),
            positional => {
                if index.is_some() {
                    return Err("one index path only".to_owned());
                }
                index = Some(PathBuf::from(positional));
            }
        }
    }
    match index {
        Some(index) => Ok(Some(Args {
            index,
            lookups,
            json,
        })),
        None => Err("missing <index.sqlite>".to_owned()),
    }
}

fn open_index(path: &std::path::Path) -> Result<Connection, String> {
    Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .and_then(|conn| {
            conn.query_row("SELECT COUNT(*) FROM words", [], |_| Ok(()))?;
            Ok(conn)
        })
        // One line, names the path: scripts match on it.
        .map_err(|_| format!("cannot open index at {}", path.display()))
}

/// Our own resident set in bytes. `task_info` asks the kernel about our
/// task, so no child process and no `ps` parsing. The flavor number and the
/// struct shape are stable Mach ABI; they are declared here because the
/// libc wrappers rename between versions and the kernel does not.
#[cfg(target_os = "macos")]
fn resident_bytes() -> Option<u64> {
    #[repr(C)]
    struct TimeValue {
        seconds: i32,
        microseconds: i32,
    }
    #[repr(C)]
    struct TaskBasicInfo {
        virtual_size: u64,
        resident_size: u64,
        resident_size_max: u64,
        user_time: TimeValue,
        system_time: TimeValue,
        policy: i32,
    }
    unsafe extern "C" {
        fn mach_task_self() -> u32;
        fn task_info(task: u32, flavor: u32, info: *mut i32, count: *mut u32) -> i32;
    }
    // MACH_TASK_BASIC_INFO is flavor 20. The kernel sizes the reply in
    // 4-byte units, so the count derives from the struct, not a constant.
    unsafe {
        let mut info = std::mem::zeroed::<TaskBasicInfo>();
        let mut count: u32 =
            (std::mem::size_of::<TaskBasicInfo>() / std::mem::size_of::<u32>()) as u32;
        let status = task_info(
            mach_task_self(),
            20,
            &mut info as *mut TaskBasicInfo as *mut i32,
            &mut count,
        );
        (status == 0).then_some(info.resident_size)
    }
}

#[cfg(not(target_os = "macos"))]
fn resident_bytes() -> Option<u64> {
    None
}

fn percentile(sorted: &[u64], pct: f64) -> u64 {
    // Nearest rank: the smallest value at or above the pct share.
    let rank = (pct / 100.0 * sorted.len() as f64).ceil() as usize;
    sorted[rank.saturating_sub(1).min(sorted.len().saturating_sub(1))]
}

fn summarize(mut micros: Vec<u64>) -> Stats {
    micros.sort_unstable();
    let total_us: u128 = micros.iter().map(|m| u128::from(*m)).sum();
    let total_s = total_us as f64 / 1_000_000.0;
    Stats {
        min_us: micros[0],
        p50_us: percentile(&micros, 50.0),
        p95_us: percentile(&micros, 95.0),
        p99_us: percentile(&micros, 99.0),
        max_us: micros[micros.len() - 1],
        total_s,
        per_s: micros.len() as f64 / total_s,
    }
}

fn mib(bytes: Option<u64>) -> String {
    match bytes {
        Some(b) => format!("{:.2}", b as f64 / 1_048_576.0),
        None => "n/a".to_owned(),
    }
}

fn run(args: &Args) -> Result<(), String> {
    let conn = open_index(&args.index)?;
    // Sampling stays outside the timed region.
    let sample = sample::select_keys(&conn, args.lookups)?;
    let mut stmt = conn
        .prepare("SELECT word, phonetic, pos, gloss FROM words WHERE key = ? LIMIT 1")
        .map_err(|e| format!("cannot prepare lookup: {e}"))?;

    let rss_before = resident_bytes();
    let mut rss_peak = rss_before;
    let mut micros = Vec::with_capacity(sample.keys.len());
    let mut hits = 0usize;
    for (i, key) in sample.keys.iter().enumerate() {
        let folded = normalize(key);
        let start = Instant::now();
        let found = stmt.query_row([folded.as_str()], |_| Ok(())).is_ok();
        micros.push(start.elapsed().as_micros() as u64);
        hits += usize::from(found);
        if (i + 1) % MEMORY_EVERY == 0 {
            let rss = resident_bytes();
            if rss > rss_peak {
                rss_peak = rss;
            }
        }
    }
    let stats = summarize(micros);

    if args.json {
        let value = serde_json::json!({
            "index": args.index.display().to_string(),
            "lookups": sample.keys.len(),
            "row_count": sample.row_count,
            "step": sample.step,
            "hits": hits,
            "sample_checksum": format!("{:016x}", sample.checksum),
            "min_us": stats.min_us,
            "p50_us": stats.p50_us,
            "p95_us": stats.p95_us,
            "p99_us": stats.p99_us,
            "max_us": stats.max_us,
            "total_s": stats.total_s,
            "lookups_per_s": stats.per_s,
            "rss_before_bytes": rss_before,
            "rss_peak_bytes": rss_peak,
        });
        println!("{value}");
        return Ok(());
    }
    println!("readlater-packbench: {} lookups on {}", sample.keys.len(), args.index.display());
    println!("row_count        {}", sample.row_count);
    println!("step             every {}th headword ordered by key", sample.step);
    println!("sample_checksum  {:016x}", sample.checksum);
    println!("hits             {hits}/{}", sample.keys.len());
    println!("total_s          {:.3}", stats.total_s);
    println!("lookups_per_s    {:.1}", stats.per_s);
    println!("min_us           {}", stats.min_us);
    println!("p50_us           {}", stats.p50_us);
    println!("p95_us           {}", stats.p95_us);
    println!("p99_us           {}", stats.p99_us);
    println!("max_us           {}", stats.max_us);
    println!("rss_before_mib   {}", mib(rss_before));
    println!("rss_peak_mib     {}", mib(rss_peak));
    Ok(())
}

fn main() -> ExitCode {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    match parse_args(&raw) {
        Ok(None) => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        Ok(Some(args)) => match run(&args) {
            Ok(()) => ExitCode::SUCCESS,
            Err(message) => {
                eprintln!("readlater-packbench: {message}");
                ExitCode::FAILURE
            }
        },
        Err(message) => {
            eprintln!("readlater-packbench: {message}\n{USAGE}");
            ExitCode::FAILURE
        }
    }
}
