//! Clock alignment between the phone's oplog and the Mac recording. Pure functions.
//!
//! The phone plays a click at oplog time `t` (the `marker.request` event) and
//! the click reaches the speaker `outputLatency` seconds later. The Mac hears
//! that click at recording time `O`. So `O = t + outputLatency + offset`, and
//! `offset` is the median of `O_i - (t_i + latency_i)` over all clicks.
//!
//! `offset` is the negative of the plan's `δ` (phone clock minus Mac clock),
//! because this module maps phone times to recording times.

use std::collections::HashMap;

use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct OplogEvent {
    pub t: f64,
    pub session: String,
    pub event: String,
    #[serde(default)]
    pub fields: HashMap<String, String>,
}

/// Parses JSONL. Lines that do not parse are skipped, so a partly written
/// final line does not stop the analysis.
pub fn parse_oplog(text: &str) -> Vec<OplogEvent> {
    text.lines()
        .filter_map(|line| serde_json::from_str::<OplogEvent>(line).ok())
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Alignment {
    /// Add this to a phone time to get a recording time.
    pub offset: f64,
    /// Largest distance of one click from the median, in seconds. This is the clock error.
    pub spread: f64,
    pub clicks: usize,
}

/// Aligns one session. `marker_times` holds each request time and output latency.
/// `onsets` holds the recording times of the clicks. Both must be in the same order.
pub fn align(marker_times: &[(f64, f64)], onsets: &[f64]) -> Result<Alignment, String> {
    if marker_times.is_empty() {
        return Err("no marker.request events in this session".into());
    }
    if marker_times.len() != onsets.len() {
        return Err(format!(
            "{} marker requests but {} clicks in the recording; re-record or check the threshold",
            marker_times.len(),
            onsets.len()
        ));
    }
    let mut diffs: Vec<f64> = marker_times
        .iter()
        .zip(onsets)
        .map(|((t, latency), onset)| onset - (t + latency))
        .collect();
    diffs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let offset = diffs[diffs.len() / 2];
    let spread = diffs.iter().map(|d| (d - offset).abs()).fold(0.0, f64::max);
    Ok(Alignment { offset, spread, clicks: diffs.len() })
}

/// Finds the run of onsets whose spacing matches the marker requests. Speech
/// also makes onsets, so the clicks cannot be taken as "the first N onsets".
/// Returns the index of the first onset of the matching run, or `None`.
pub fn find_click_run(marker_times: &[(f64, f64)], onsets: &[f64], tolerance: f64) -> Option<usize> {
    let k = marker_times.len();
    if k == 0 || onsets.len() < k {
        return None;
    }
    let spacing: Vec<f64> = marker_times.windows(2).map(|w| w[1].0 - w[0].0).collect();
    (0..=onsets.len() - k).find(|&s| {
        spacing.iter().enumerate().all(|(j, want)| {
            ((onsets[s + j + 1] - onsets[s + j]) - want).abs() <= tolerance
        })
    })
}

/// The marker requests of one session, as (time, output latency).
pub fn markers_for(events: &[OplogEvent], session: &str) -> Vec<(f64, f64)> {
    events
        .iter()
        .filter(|e| e.session == session && e.event == "marker.request")
        .map(|e| {
            let latency = e
                .fields
                .get("outputLatency")
                .and_then(|v| v.parse::<f64>().ok())
                .unwrap_or(0.0);
            (e.t, latency)
        })
        .collect()
}

/// Sessions that have at least one marker request, in first-seen order.
pub fn sessions_with_markers(events: &[OplogEvent]) -> Vec<String> {
    let mut seen: Vec<String> = Vec::new();
    for e in events.iter().filter(|e| e.event == "marker.request") {
        if !seen.contains(&e.session) {
            seen.push(e.session.clone());
        }
    }
    seen
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offset_is_the_median_and_spread_is_the_clock_error() {
        // Phone clicks at 10, 11, 12 s with 0.05 s latency. The Mac hears them
        // 0.5 s later, with 2 ms of jitter on the third.
        let markers = [(10.0, 0.05), (11.0, 0.05), (12.0, 0.05)];
        let onsets = [10.55, 11.55, 12.552];
        let a = align(&markers, &onsets).unwrap();
        assert!((a.offset - 0.5).abs() < 1e-9);
        assert!((a.spread - 0.002).abs() < 1e-9, "spread {}", a.spread);
        assert_eq!(a.clicks, 3);
    }

    #[test]
    fn the_click_run_is_found_among_speech_onsets() {
        // Clicks 1 s apart, with two speech onsets before them.
        let markers = [(10.0, 0.0), (11.0, 0.0), (12.0, 0.0)];
        let onsets = [0.3, 2.1, 5.0, 6.0, 7.0, 8.4];
        assert_eq!(find_click_run(&markers, &onsets, 0.02), Some(2));
        assert_eq!(find_click_run(&markers, &[0.3, 0.9], 0.02), None);
    }

    #[test]
    fn mismatched_counts_are_an_error() {
        assert!(align(&[(1.0, 0.0), (2.0, 0.0)], &[1.0]).is_err());
    }

    #[test]
    fn phone_time_maps_to_recording_time() {
        let a = align(&[(10.0, 0.05)], &[10.55]).unwrap();
        let phone_tap = 14.0;
        assert!((phone_tap + a.offset - 14.5).abs() < 1e-9);
    }

    #[test]
    fn sessions_are_kept_apart() {
        let text = r#"{"t":1.0,"iso":"","session":"a","event":"marker.request","fields":{"outputLatency":"0.1"}}
{"t":2.0,"iso":"","session":"b","event":"tap.pause"}
not json
{"t":3.0,"iso":"","session":"b","event":"marker.request","fields":{"outputLatency":"0.2"}}"#;
        let events = parse_oplog(text);
        assert_eq!(events.len(), 3, "the bad line is skipped");
        assert_eq!(sessions_with_markers(&events), vec!["a".to_string(), "b".to_string()]);
        assert_eq!(markers_for(&events, "b"), vec![(3.0, 0.2)]);
    }
}
