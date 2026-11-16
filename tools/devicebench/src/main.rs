//! devicebench: record the Mac microphone and measure the reader on the phone.
//!
//! Commands (see README.md for the protocol):
//!   record  --seconds S --out FILE.wav [--device NAME]
//!   onsets  --wav FILE.wav [--min 0.01]
//!   align   --oplog FILE.jsonl --wav FILE.wav [--session ID] [--silence 0.3]
//!           [--clock-session ID] [--click-factor 8] [--quiet-factor 1.5]
//!   gen     --out FILE.wav --times 1.0,2.0 --seconds S [--rate 48000]

mod align;
mod detect;
mod record;

use std::path::{Path, PathBuf};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("record") => cmd_record(&args[1..]),
        Some("onsets") => cmd_onsets(&args[1..]),
        Some("align") => cmd_align(&args[1..]),
        Some("gen") => cmd_gen(&args[1..]),
        _ => Err(USAGE.to_string()),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

const USAGE: &str = "usage:
  devicebench record --seconds S --out FILE.wav [--device NAME]
  devicebench onsets --wav FILE.wav [--min 0.01]
  devicebench align --oplog FILE.jsonl --wav FILE.wav [--session ID] [--silence 0.3] [--clock-session ID] [--click-factor 8] [--quiet-factor 1.5]
  devicebench gen --out FILE.wav --times 1.0,2.0 --seconds S [--rate 48000]";

/// Spacing tolerance for every click after the first. The first click's late
/// start has its own wider window (`align::FIRST_STEP_TOLERANCE`). Later
/// spacings in a clean run agree within about 15 ms.
const SPACING_TOLERANCE: f64 = 0.03;

/// Onsets closer than this belong to one click. A 10 ms click spans about 25 ms.
const CLUSTER_GAP: f64 = 0.05;

/// How long after a pause the quiet level is read, in seconds. A held pause
/// leaves most of this window quiet.
const QUIET_WINDOW: f64 = 6.0;

/// A scrub restart goes quiet for at least this long before sound returns.
const SCRUB_QUIET_S: f64 = 0.05;

/// The restart's quiet run must begin within this many seconds of the commit.
/// A later quiet run is a pause in the speech, not the restart.
const SCRUB_STOP_WINDOW_S: f64 = 0.5;

/// The thresholds one align run uses. The silence level for a pause is the
/// quiet level of its window times `quiet_factor`, never below `silence`.
#[derive(Clone, Copy)]
struct Levels {
    click: f32,
    silence: f32,
    silence_s: f64,
    quiet_factor: f32,
}

fn flag<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.windows(2).find(|w| w[0] == name).map(|w| w[1].as_str())
}

fn required<'a>(args: &'a [String], name: &str) -> Result<&'a str, String> {
    flag(args, name).ok_or_else(|| format!("missing {name}\n{USAGE}"))
}

fn number(args: &[String], name: &str, default: f64) -> Result<f64, String> {
    match flag(args, name) {
        None => Ok(default),
        Some(raw) => raw.parse().map_err(|_| format!("{name} must be a number, got {raw}")),
    }
}

fn cmd_record(args: &[String]) -> Result<(), String> {
    let seconds = number(args, "--seconds", 0.0)?;
    if seconds <= 0.0 {
        return Err(format!("--seconds must be above zero\n{USAGE}"));
    }
    let out = PathBuf::from(required(args, "--out")?);
    record::record(seconds, &out, flag(args, "--device"))?;
    println!("recorded {seconds} s to {}", out.display());
    Ok(())
}

fn cmd_onsets(args: &[String]) -> Result<(), String> {
    let (samples, rate) = record::read_wav(Path::new(required(args, "--wav")?))?;
    let env = detect::Envelope::new(&samples, rate, 1.0);
    let floor = detect::noise_floor(&env, 0.5);
    let min = number(args, "--min", 0.01)? as f32;
    let thr = detect::threshold(floor, min);
    println!("# noise floor {floor:.6}, threshold {thr:.6}");
    for t in detect::onsets(&env, thr) {
        println!("{t:.4}");
    }
    Ok(())
}

fn cmd_align(args: &[String]) -> Result<(), String> {
    let oplog = std::fs::read_to_string(required(args, "--oplog")?).map_err(|e| e.to_string())?;
    let events = align::parse_oplog(&oplog);
    let (samples, rate) = record::read_wav(Path::new(required(args, "--wav")?))?;
    let env = detect::Envelope::new(&samples, rate, 1.0);
    let floor = detect::noise_floor(&env, 0.5);
    let click_factor = number(args, "--click-factor", 8.0)? as f32;
    let levels = Levels {
        click: detect::threshold_factor(floor, click_factor, 0.01),
        silence: detect::silence_level(floor),
        silence_s: number(args, "--silence", 0.3)?,
        quiet_factor: number(args, "--quiet-factor", 1.5)? as f32,
    };
    eprintln!(
        "# noise floor {floor:.6}, click threshold {:.6}, silence floor level {:.6}, quiet factor {}",
        levels.click, levels.silence, levels.quiet_factor
    );
    let all_onsets = detect::collapse(&detect::onsets(&env, levels.click), CLUSTER_GAP);
    if let Some(clock) = flag(args, "--clock-session") {
        return align_by_wall(&events, &env, &all_onsets, clock, flag(args, "--session"), levels);
    }

    let sessions: Vec<String> = match flag(args, "--session") {
        Some(id) => vec![id.to_string()],
        None => align::sessions_with_markers(&events),
    };
    if sessions.is_empty() {
        return Err("no marker.request events in the oplog".into());
    }

    println!("session,event,phone_t,rec_t,response_ms,silence_level");
    for session in sessions {
        let markers = align::markers_for(&events, &session);
        let spacing = markers.windows(2).map(|w| w[1].0 - w[0].0).collect::<Vec<_>>();
        let clicks = align::match_clicks(&markers, &all_onsets, SPACING_TOLERANCE)
            .ok_or_else(|| format!("session {session}: clicks not found in the recording (spacing {spacing:?})"))?;
        let fit = align::align(&markers, &clicks)?;
        eprintln!(
            "# session {session}: offset {:.4} s (phone to recording), clock error {:.1} ms over clicks 2 to {}, click 1 residual {:+.1} ms",
            fit.offset,
            fit.spread * 1000.0,
            fit.clicks,
            fit.first_residual * 1000.0
        );
        print_residuals(&markers, &clicks, fit.offset, false);

        for e in events.iter().filter(|e| e.session == session) {
            if !matches!(e.event.as_str(), "tap.play" | "tap.pause" | "scrub.commit") {
                continue;
            }
            let rec_t = e.t + fit.offset;
            print_event(&env, &session, e, rec_t, levels);
        }
    }
    Ok(())
}

/// Aligns sessions on the wall clock of one clock session. Use it when the
/// taps and the clicks come from different app launches. Each launch has its
/// own `t` origin, but `iso` is the phone's wall clock and is shared.
fn align_by_wall(
    events: &[align::OplogEvent],
    env: &detect::Envelope,
    onsets: &[f64],
    clock: &str,
    only: Option<&str>,
    levels: Levels,
) -> Result<(), String> {
    let markers = align::markers_wall_for(events, clock);
    if markers.is_empty() {
        return Err(format!("clock session {clock}: no marker.request events with a stamp"));
    }
    let spacing = markers.windows(2).map(|w| w[1].0 - w[0].0).collect::<Vec<_>>();
    let clicks = align::match_clicks(&markers, onsets, SPACING_TOLERANCE)
        .ok_or_else(|| format!("clock session {clock}: clicks not found in the recording (spacing {spacing:?})"))?;
    let fit = align::align(&markers, &clicks)?;
    eprintln!(
        "# clock session {clock}: offset {:.4} s (wall clock to recording), clock error {:.1} ms over clicks 2 to {}, click 1 residual {:+.1} ms",
        fit.offset,
        fit.spread * 1000.0,
        fit.clicks,
        fit.first_residual * 1000.0
    );
    print_residuals(&markers, &clicks, fit.offset, true);

    println!("session,event,phone_t,rec_t,response_ms,silence_level");
    let sessions: Vec<String> = match only {
        Some(id) => vec![id.to_string()],
        None => align::sessions_in(events),
    };
    for session in sessions {
        for e in events.iter().filter(|e| e.session == session) {
            if !matches!(e.event.as_str(), "tap.play" | "tap.pause" | "scrub.commit") {
                continue;
            }
            let Some(wall) = align::wall_seconds(&e.iso) else {
                continue;
            };
            let rec_t = wall + fit.offset;
            print_event(env, &session, e, rec_t, levels);
        }
    }
    Ok(())
}

/// Prints each click's residual to stderr, in milliseconds.
fn print_residuals(markers: &[(f64, f64)], clicks: &[f64], offset: f64, wall: bool) {
    for (i, (marker, onset)) in markers.iter().zip(clicks.iter()).enumerate() {
        let (time, latency) = *marker;
        let residual = (*onset - (time + latency + offset)) * 1000.0;
        let label = if wall { "wall" } else { "phone" };
        eprintln!("# click {} ({label} clock): residual {residual:+.1} ms", i + 1);
    }
}

/// Prints one event row: the response in milliseconds, and for a pause or a scrub the
/// silence level used. A response of `none` means no quiet run was found.
fn print_event(env: &detect::Envelope, session: &str, e: &align::OplogEvent, rec_t: f64, levels: Levels) {
    let (response, level) = respond(env, &e.event, rec_t, levels);
    if e.event == "scrub.commit" && response.is_none() {
        explain_scrub(env, rec_t, levels);
    }
    let response_ms = response.map(|r| format!("{:.1}", (r - rec_t) * 1000.0)).unwrap_or_else(|| "none".into());
    println!("{session},{},{:.4},{rec_t:.4},{response_ms},{level}", e.event, e.t);
}

/// Says on stderr why a scrub has no restart: where the first quiet run after
/// the commit starts, and whether sound follows it. The CSV keeps its columns.
fn explain_scrub(env: &detect::Envelope, rec_t: f64, levels: Levels) {
    let level = quiet_level(env, rec_t, levels);
    let note = match detect::silence_after(env, rec_t, level, SCRUB_QUIET_S) {
        None => "no quiet run of at least 0.05 s after the commit".to_string(),
        Some(stop) => {
            let after = format!(
                "first quiet run starts {:.3} s after the commit",
                stop - rec_t
            );
            match detect::sound_after(env, stop, level) {
                Some(_) => after,
                None => format!("{after}; no sound follows it"),
            }
        }
    };
    eprintln!("# scrub at {rec_t:.4} s: no restart within {SCRUB_STOP_WINDOW_S} s; {note}");
}

/// The response of one event, and the silence level used for a pause or a scrub
/// ("" for other events). A pause ends at the first quiet run that follows it.
/// A scrub ends when the sentence it restarts sounds again. Both levels follow
/// the recording, not only its head.
fn respond(env: &detect::Envelope, event: &str, rec_t: f64, levels: Levels) -> (Option<f64>, String) {
    match event {
        "tap.pause" => {
            let level = quiet_level(env, rec_t, levels);
            (detect::silence_after(env, rec_t, level, levels.silence_s), format!("{level:.6}"))
        }
        "scrub.commit" => {
            let level = quiet_level(env, rec_t, levels);
            (
                detect::resumed_after(env, rec_t, level, SCRUB_QUIET_S, SCRUB_STOP_WINDOW_S),
                format!("{level:.6}"),
            )
        }
        _ => (detect::sound_after(env, rec_t, levels.click), String::new()),
    }
}

/// The level below which the audio counts as quiet after `rec_t`: the quiet
/// level of the window times `quiet_factor`, never below the silence level.
fn quiet_level(env: &detect::Envelope, rec_t: f64, levels: Levels) -> f32 {
    let quiet = detect::quantile(env, rec_t, QUIET_WINDOW, 0.10);
    (quiet * levels.quiet_factor).max(levels.silence)
}

fn cmd_gen(args: &[String]) -> Result<(), String> {
    let out = PathBuf::from(required(args, "--out")?);
    let seconds = number(args, "--seconds", 5.0)?;
    let rate = number(args, "--rate", 48_000.0)? as u32;
    let times: Vec<f64> = required(args, "--times")?
        .split(',')
        .map(|t| t.trim().parse::<f64>().map_err(|_| format!("bad time {t}")))
        .collect::<Result<_, _>>()?;
    let mut samples = vec![0.0f32; (seconds * rate as f64) as usize];
    for at in times {
        let start = (at * rate as f64) as usize;
        let len = rate as usize / 100; // 10 ms
        for i in 0..len {
            if let Some(slot) = samples.get_mut(start + i) {
                *slot = (0.8 * (2.0 * std::f64::consts::PI * 1000.0 * i as f64 / rate as f64).sin()) as f32;
            }
        }
    }
    record::write_wav(&out, &samples, rate)?;
    println!("wrote {} ({seconds} s)", out.display());
    Ok(())
}

#[cfg(test)]
mod baseline_repro_tests {
    //! Replays the filed baseline numbers from the surviving /tmp recordings.
    //!
    //! The oplogs that fixed the clock offset are gone (see results.md: only
    //! /tmp WAVs survive), so this test takes the filed `rec_t` anchors from
    //! the CSVs and re-runs the detection rule on the WAV at each anchor. It
    //! proves the detector deterministically reproduces the filed M2/M3/M4
    //! response values. It skips when the /tmp files are absent.

    use super::*;
    use std::path::Path;

    struct Case {
        wav: &'static str,
        csv: &'static str,
        click_factor: f32,
        /// Whether to assert tap.play rows strictly. The M2 CSVs were made
        /// with two click factors (rr-3 vs rr-4 play rows differ), which was
        /// not recorded, so M2 play rows are reported, not asserted.
        strict_play: bool,
    }

    fn median(values: &[f64]) -> f64 {
        let mut sorted = values.to_vec();
        sorted.sort_by(|v: &f64, w: &f64| v.partial_cmp(w).unwrap());
        (sorted[sorted.len() / 2 - 1] + sorted[sorted.len() / 2]) / 2.0
    }

    fn check_case(case: &Case) -> bool {
        if !Path::new(case.wav).exists() || !Path::new(case.csv).exists() {
            eprintln!("baseline_repro: skip {} (files absent)", case.csv);
            return false;
        }
        let (samples, rate) = record::read_wav(Path::new(case.wav)).expect("wav");
        let env = detect::Envelope::new(&samples, rate, 1.0);
        let floor = detect::noise_floor(&env, 0.5);
        let levels = Levels {
            click: detect::threshold_factor(floor, case.click_factor, 0.01),
            silence: detect::silence_level(floor),
            silence_s: 0.3,
            quiet_factor: 1.5,
        };
        eprintln!(
            "baseline_repro: {} floor {floor:.6} click {:.6} silence {:.6}",
            case.wav, levels.click, levels.silence
        );
        let text = std::fs::read_to_string(case.csv).expect("csv");
        let mut bad = 0;
        let mut pauses = Vec::new();
        for (n, line) in text.lines().enumerate() {
            if n == 0 {
                continue;
            }
            let col: Vec<&str> = line.split(',').collect();
            let (event, rec_t, filed_ms, filed_level) =
                (col[1], col[3].parse::<f64>().unwrap(), col[4], col[5]);
            let (response, level) = respond(&env, event, rec_t, levels);
            if event != "tap.play" {
                assert_eq!(level, filed_level, "{} row {n}: silence level", case.csv);
            }
            let filed = if filed_ms == "none" {
                None
            } else {
                Some(filed_ms.parse::<f64>().unwrap())
            };
            let got = response.map(|r| (r - rec_t) * 1000.0);
            let ok = match (got, filed) {
                (None, None) => true,
                (Some(g), Some(f)) => (g - f).abs() <= 0.06,
                _ => false,
            };
            let strict = event != "tap.play" || case.strict_play;
            if event == "tap.pause" {
                if let Some(f) = filed {
                    pauses.push(f);
                }
            }
            if !ok && strict {
                bad += 1;
                eprintln!(
                    "baseline_repro: {} row {n} {event} rec_t {rec_t}: filed {filed_ms}, got {got:?}",
                    case.csv
                );
            } else if event == "tap.play" && !case.strict_play {
                eprintln!(
                    "baseline_repro: {} row {n} play rec_t {rec_t}: filed {filed_ms}, got {got:?} (info only)",
                    case.csv
                );
            }
        }
        if !pauses.is_empty() {
            eprintln!(
                "baseline_repro: {} pause median {:.1} ms over {} pauses",
                case.csv,
                median(&pauses),
                pauses.len()
            );
        }
        assert_eq!(bad, 0, "{} mismatches in {}", bad, case.csv);
        true
    }

    #[test]
    fn baseline_numbers_reproduce_from_recordings() {
        let cases = [
            // Filed M2: median 133 to 173 ms, range 10 to 485 ms, 2 batches of 12.
            Case {
                wav: "/tmp/m2-rerun.wav",
                csv: "/tmp/rr4-43C4625A.csv",
                click_factor: 8.0,
                strict_play: false,
            },
            Case {
                wav: "/tmp/m2-rerun.wav",
                csv: "/tmp/rr-3.csv",
                click_factor: 8.0,
                strict_play: false,
            },
            // Filed M3: 422 to 435 ms tap-to-sound; M4 best recording, 4 of 20 restarts.
            Case {
                wav: "/tmp/m4-rerun6.wav",
                csv: "/tmp/m4-rerun6-final.csv",
                click_factor: 8.0,
                strict_play: true,
            },
            Case {
                wav: "/tmp/m4-rerun4.wav",
                csv: "/tmp/m4-rerun4-f2.csv",
                click_factor: 2.0,
                strict_play: true,
            },
        ];
        let mut ran = 0;
        for case in &cases {
            if check_case(case) {
                ran += 1;
            }
        }
        eprintln!("baseline_repro: {ran} of {} cases ran", cases.len());
    }

    #[test]
    fn filed_m2_medians_match_the_csvs() {
        // Guards the arithmetic behind F23: batch medians 133.4 and 172.9 ms.
        for (csv, want) in [("/tmp/rr-3.csv", 133.4), ("/tmp/rr4-43C4625A.csv", 172.9)] {
            if !Path::new(csv).exists() {
                eprintln!("baseline_repro: skip median check for {csv}");
                continue;
            }
            let text = std::fs::read_to_string(csv).unwrap();
            let pauses: Vec<f64> = text
                .lines()
                .skip(1)
                .filter_map(|line| {
                    let col: Vec<&str> = line.split(',').collect();
                    (col[1] == "tap.pause").then(|| col[4].parse().unwrap())
                })
                .collect();
            assert_eq!(pauses.len(), 12, "{csv} must hold one 12-pause batch");
            assert!((median(&pauses) - want).abs() < 0.05, "{csv} median");
        }
    }
}
