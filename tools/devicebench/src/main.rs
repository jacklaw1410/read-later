//! devicebench: record the Mac microphone and measure the reader on the phone.
//!
//! Commands (see README.md for the protocol):
//!   record  --seconds S --out FILE.wav [--device NAME]
//!   onsets  --wav FILE.wav [--min 0.01]
//!   align   --oplog FILE.jsonl --wav FILE.wav [--session ID] [--silence 0.3]
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
  devicebench align --oplog FILE.jsonl --wav FILE.wav [--session ID] [--silence 0.3]
  devicebench gen --out FILE.wav --times 1.0,2.0 --seconds S [--rate 48000]";

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
    let thr = detect::threshold(floor, 0.01);
    let silence_s = number(args, "--silence", 0.3)?;
    let all_onsets = detect::onsets(&env, thr);

    let sessions: Vec<String> = match flag(args, "--session") {
        Some(id) => vec![id.to_string()],
        None => align::sessions_with_markers(&events),
    };
    if sessions.is_empty() {
        return Err("no marker.request events in the oplog".into());
    }

    println!("session,event,phone_t,rec_t,response_ms");
    for session in sessions {
        let markers = align::markers_for(&events, &session);
        let spacing = markers.windows(2).map(|w| w[1].0 - w[0].0).collect::<Vec<_>>();
        let tolerance = 0.02;
        let start = align::find_click_run(&markers, &all_onsets, tolerance)
            .ok_or_else(|| format!("session {session}: clicks not found in the recording (spacing {spacing:?})"))?;
        let clicks = &all_onsets[start..start + markers.len()];
        let fit = align::align(&markers, clicks)?;
        eprintln!(
            "# session {session}: offset {:.4} s (phone to recording), clock error {:.1} ms over {} clicks",
            fit.offset,
            fit.spread * 1000.0,
            fit.clicks
        );

        for e in events.iter().filter(|e| e.session == session) {
            if !matches!(e.event.as_str(), "tap.play" | "tap.pause" | "scrub.commit") {
                continue;
            }
            let rec_t = e.t + fit.offset;
            let response = match e.event.as_str() {
                "tap.pause" => detect::silence_after(&env, rec_t, thr, silence_s),
                _ => detect::sound_after(&env, rec_t, thr),
            };
            let response_ms = response.map(|r| format!("{:.1}", (r - rec_t) * 1000.0)).unwrap_or_else(|| "none".into());
            println!("{session},{},{:.4},{rec_t:.4},{response_ms}", e.event, e.t);
        }
    }
    Ok(())
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
