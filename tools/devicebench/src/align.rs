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
    /// The phone's wall clock in UTC, for example `2026-11-15T07:27:45.567Z`.
    /// Shared by every app launch, unlike `t`.
    #[serde(default)]
    pub iso: String,
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
    /// Largest distance of clicks 2 onward from the offset, in seconds. This is the clock error.
    pub spread: f64,
    /// Click 1's distance from the offset. It carries the cold-start delay.
    pub first_residual: f64,
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
    let residuals: Vec<f64> = marker_times
        .iter()
        .zip(onsets)
        .map(|((t, latency), onset)| onset - (t + latency))
        .collect();
    let mut sorted = residuals.clone();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let offset = sorted[sorted.len() / 2];
    // Every run so far started its first click late by 35 to 57 ms, a cold-start
    // delay. The clock error is therefore measured over clicks 2 onward, and the
    // first click's residual is reported apart. The offset still uses every click.
    let later = if residuals.len() >= 3 {
        &residuals[1..]
    } else {
        &residuals[..]
    };
    let spread = later.iter().map(|d| (d - offset).abs()).fold(0.0, f64::max);
    let first_residual = residuals[0] - offset;
    Ok(Alignment {
        offset,
        spread,
        first_residual,
        clicks: residuals.len(),
    })
}

/// Tolerance for the first step of a click run. The first click starts up to
/// about 60 ms late, so only the first spacing needs the wider window.
pub const FIRST_STEP_TOLERANCE: f64 = 0.08;

/// Matches the marker requests to onsets. Every onset is tried as the first
/// click. From it, each later click must land within `tolerance` of the
/// previous matched click plus the requested spacing. Speech is dense enough
/// (about 13 onsets a second in the M2 recording) that a few chains can match by
/// chance, so the chain with the most regular spacing wins. The first step is
/// excluded from that score, because the late first click is expected.
/// Returns the matched onsets in order, or `None` when no chain fits.
pub fn match_clicks(
    marker_times: &[(f64, f64)],
    onsets: &[f64],
    tolerance: f64,
) -> Option<Vec<f64>> {
    let k = marker_times.len();
    if k == 0 || onsets.len() < k {
        return None;
    }
    let spacing: Vec<f64> = marker_times.windows(2).map(|w| w[1].0 - w[0].0).collect();
    let mut best: Option<(f64, Vec<f64>)> = None;
    for &first in onsets {
        let Some(chain) = chain_from(first, &spacing, onsets, tolerance) else {
            continue;
        };
        let score = spacing_error(&chain, &spacing);
        if best.as_ref().is_none_or(|(s, _)| score < *s) {
            best = Some((score, chain));
        }
    }
    best.map(|(_, chain)| chain)
}

/// One candidate run that starts at `first`, or `None` when a step has no onset.
fn chain_from(first: f64, spacing: &[f64], onsets: &[f64], tolerance: f64) -> Option<Vec<f64>> {
    let mut chain = vec![first];
    let mut previous = first;
    for (step, want) in spacing.iter().enumerate() {
        let window = if step == 0 {
            FIRST_STEP_TOLERANCE
        } else {
            tolerance
        };
        let target = previous + want;
        let from = onsets.partition_point(|&o| o < target - window);
        let next = onsets[from..]
            .iter()
            .take_while(|&&o| o <= target + window)
            .find(|&&o| o > previous)?;
        chain.push(*next);
        previous = *next;
    }
    Some(chain)
}

/// Root mean square of the spacing errors, excluding the first step. Zero for
/// a run with no spacing to compare.
fn spacing_error(chain: &[f64], spacing: &[f64]) -> f64 {
    let errors: Vec<f64> = chain
        .windows(2)
        .zip(spacing)
        .skip(1)
        .map(|(pair, want)| (pair[1] - pair[0] - want).powi(2))
        .collect();
    if errors.is_empty() {
        return 0.0;
    }
    (errors.iter().sum::<f64>() / errors.len() as f64).sqrt()
}

/// Seconds since 1970 for an oplog `iso` stamp. Returns `None` for any other
/// shape, so an event without a stamp is skipped, not misread.
pub fn wall_seconds(iso: &str) -> Option<f64> {
    let (date, time) = iso.trim_end_matches('Z').split_once('T')?;
    let mut parts = date.split('-').map(|p| p.parse::<i64>().ok());
    let (year, month, day) = (parts.next()??, parts.next()??, parts.next()??);
    let (hms, fraction) = time.split_once('.').unwrap_or((time, "0"));
    let mut clock = hms.split(':').map(|p| p.parse::<i64>().ok());
    let (hour, minute, second) = (clock.next()??, clock.next()??, clock.next()??);
    let fraction: f64 = format!("0.{fraction}").parse().ok()?;
    let whole = days_from_civil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second;
    Some(whole as f64 + fraction)
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let year_of_era = y - era * 400;
    let month_from_march = (month + 9) % 12;
    let day_of_year = (153 * month_from_march + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// Recording time offset implied by the Mac's wall clock: the median over one
/// session's stamped events of `(iso wall time - recording start) - t`. Any
/// event works, so a session with no marker requests can still align. Add the
/// offset to a phone time to get a recording time, like `Alignment::offset`.
/// Assumes the phone and the Mac clocks agree. The difference from the click
/// fit is the clock disagreement.
pub fn wall_offset(events: &[OplogEvent], session: &str, recording_started: f64) -> Option<f64> {
    let mut offsets: Vec<f64> = events
        .iter()
        .filter(|e| e.session == session)
        .filter_map(|e| Some(wall_seconds(&e.iso)? - recording_started - e.t))
        .collect();
    if offsets.is_empty() {
        return None;
    }
    offsets.sort_by(|a, b| a.partial_cmp(b).unwrap());
    Some(offsets[offsets.len() / 2])
}

/// Marker requests of one session as (wall-clock seconds, output latency).
pub fn markers_wall_for(events: &[OplogEvent], session: &str) -> Vec<(f64, f64)> {
    events
        .iter()
        .filter(|e| e.session == session && e.event == "marker.request")
        .filter_map(|e| {
            let wall = wall_seconds(&e.iso)?;
            let latency = e
                .fields
                .get("outputLatency")
                .and_then(|v| v.parse::<f64>().ok())
                .unwrap_or(0.0);
            Some((wall, latency))
        })
        .collect()
}

/// Every session in the oplog, in first-seen order.
pub fn sessions_in(events: &[OplogEvent]) -> Vec<String> {
    let mut seen: Vec<String> = Vec::new();
    for e in events {
        if !seen.contains(&e.session) {
            seen.push(e.session.clone());
        }
    }
    seen
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
        assert_eq!(
            match_clicks(&markers, &onsets, 0.02),
            Some(vec![5.0, 6.0, 7.0])
        );
        assert_eq!(match_clicks(&markers, &[0.3, 0.9], 0.02), None);
    }

    #[test]
    fn a_stray_peak_between_clicks_is_skipped() {
        let markers = [(10.0, 0.0), (11.0, 0.0), (12.0, 0.0)];
        let onsets = [10.0, 10.4, 11.0, 12.0];
        assert_eq!(
            match_clicks(&markers, &onsets, 0.02),
            Some(vec![10.0, 11.0, 12.0])
        );
    }

    #[test]
    fn a_late_first_click_matches_because_the_first_step_is_wider() {
        // The first click starts 55 ms late, so the first spacing is 0.945 s
        // against 1.0 s requested. The first step uses FIRST_STEP_TOLERANCE,
        // and the later spacings agree within 0.02 s.
        let markers = [(10.0, 0.0), (11.0, 0.0), (12.0, 0.0)];
        let onsets = [10.055, 11.0, 12.0];
        assert_eq!(
            match_clicks(&markers, &onsets, 0.02),
            Some(vec![10.055, 11.0, 12.0])
        );
    }

    #[test]
    fn the_most_regular_chain_wins_over_an_earlier_irregular_one() {
        // A chain at 10 s is exact. A chain at 20 s also fits the tolerance,
        // but its second spacing is 30 ms off, so the exact one is kept.
        let markers = [(10.0, 0.0), (11.0, 0.0), (12.0, 0.0)];
        let onsets = [10.0, 11.0, 12.0, 20.0, 21.03, 22.0];
        assert_eq!(
            match_clicks(&markers, &onsets, 0.03),
            Some(vec![10.0, 11.0, 12.0])
        );
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
    fn wall_clock_stamps_convert_across_midnight_and_month_ends() {
        let a = wall_seconds("2026-11-15T07:27:45.567Z").unwrap();
        let b = wall_seconds("2026-11-15T07:27:46.000Z").unwrap();
        assert!((b - a - 0.433).abs() < 1e-6, "diff {}", b - a);
        let late = wall_seconds("2026-11-30T23:59:59.500Z").unwrap();
        let early = wall_seconds("2026-12-01T00:00:00.500Z").unwrap();
        assert!(
            (early - late - 1.0).abs() < 1e-6,
            "across month end: {}",
            early - late
        );
        assert_eq!(wall_seconds("not a stamp"), None);
    }

    #[test]
    fn wall_offset_is_the_wall_clock_minus_the_phone_time() {
        // Marker at phone t 2.0 s, stamped 2026-11-17T09:27:44.000Z. The
        // recording started at 09:27:09.000Z. So the marker is at recording
        // time 35 s, and the offset (recording time minus phone time) is 33 s.
        let started = wall_seconds("2026-11-17T09:27:09.000Z").unwrap();
        let text = r#"{"t":2.0,"iso":"2026-11-17T09:27:44.000Z","session":"a","event":"marker.request","fields":{}}"#;
        let events = parse_oplog(text);
        let offset = wall_offset(&events, "a", started).unwrap();
        assert!((offset - 33.0).abs() < 1e-6, "offset {offset}");
        assert_eq!(wall_offset(&events, "missing", started), None);
    }

    #[test]
    fn wall_offset_uses_any_stamped_event_in_the_session() {
        let started = wall_seconds("2026-11-17T09:27:09.000Z").unwrap();
        let text = r#"{"t":5.0,"iso":"2026-11-17T09:27:44.000Z","session":"a","event":"scrub.begin","fields":{}}"#;
        let events = parse_oplog(text);
        let offset = wall_offset(&events, "a", started).unwrap();
        assert!((offset - 30.0).abs() < 1e-6, "offset {offset}");
    }

    #[test]
    fn sessions_are_kept_apart() {
        let text = r#"{"t":1.0,"iso":"","session":"a","event":"marker.request","fields":{"outputLatency":"0.1"}}
{"t":2.0,"iso":"","session":"b","event":"tap.pause"}
not json
{"t":3.0,"iso":"","session":"b","event":"marker.request","fields":{"outputLatency":"0.2"}}"#;
        let events = parse_oplog(text);
        assert_eq!(events.len(), 3, "the bad line is skipped");
        assert_eq!(
            sessions_with_markers(&events),
            vec!["a".to_string(), "b".to_string()]
        );
        assert_eq!(markers_for(&events, "b"), vec![(3.0, 0.2)]);
    }

    #[test]
    fn no_markers_is_an_error_and_no_onsets_is_none() {
        assert!(align(&[], &[1.0]).is_err());
        assert_eq!(match_clicks(&[], &[1.0, 2.0], 0.02), None);
        assert_eq!(match_clicks(&[(1.0, 0.0)], &[], 0.02), None);
    }

    #[test]
    fn a_single_click_aligns_with_zero_spread() {
        let a = align(&[(10.0, 0.05)], &[10.55]).unwrap();
        assert!((a.offset - 0.5).abs() < 1e-9);
        assert_eq!(a.spread, 0.0);
        assert_eq!(a.first_residual, 0.0);
        assert_eq!(a.clicks, 1);
    }

    #[test]
    fn two_markers_use_the_upper_median() {
        let a = align(&[(10.0, 0.0), (11.0, 0.0)], &[10.5, 11.7]).unwrap();
        assert!((a.offset - 0.7).abs() < 1e-9, "offset {}", a.offset);
        assert!((a.spread - 0.2).abs() < 1e-9, "spread {}", a.spread);
        assert!(
            (a.first_residual + 0.2).abs() < 1e-9,
            "first {}",
            a.first_residual
        );
    }

    #[test]
    fn a_single_marker_matches_the_earliest_onset() {
        // One click carries no spacing, so every onset is a candidate and the
        // earliest wins. Callers must not rely on this to reject speech.
        assert_eq!(
            match_clicks(&[(10.0, 0.0)], &[5.0, 6.0], 0.02),
            Some(vec![5.0])
        );
    }

    #[test]
    fn the_first_step_window_is_wider_than_tolerance() {
        // 62.5 ms late on the first spacing passes with a 20 ms tolerance,
        // because the first step uses FIRST_STEP_TOLERANCE. 90 ms late fails.
        let markers = [(10.0, 0.0), (11.0, 0.0), (12.0, 0.0)];
        assert_eq!(
            match_clicks(&markers, &[10.0, 11.0625, 12.0625], 0.02),
            Some(vec![10.0, 11.0625, 12.0625])
        );
        assert_eq!(match_clicks(&markers, &[10.0, 11.09, 12.09], 0.02), None);
    }

    #[test]
    fn wall_seconds_parses_fractions_and_rejects_offsets() {
        let half = wall_seconds("2026-11-15T07:27:45.5Z").unwrap();
        let whole = wall_seconds("2026-11-15T07:27:45.000Z").unwrap();
        assert!((half - whole - 0.5).abs() < 1e-6);
        let no_z = wall_seconds("2026-11-15T07:27:45.5").unwrap();
        assert!((no_z - half).abs() < 1e-9, "a missing Z changes nothing");
        assert_eq!(wall_seconds("2026-11-15T07:27:45+08:00"), None);
        let leap = wall_seconds("2024-02-29T00:00:00Z").unwrap();
        let next = wall_seconds("2024-03-01T00:00:00Z").unwrap();
        assert!(
            (next - leap - 86_400.0).abs() < 1e-6,
            "leap day is a real day"
        );
    }

    #[test]
    fn markers_wall_needs_a_stamp_but_not_a_latency() {
        let text = r#"{"t":1.0,"iso":"2026-11-15T07:27:45.000Z","session":"a","event":"marker.request","fields":{}}
{"t":2.0,"iso":"","session":"a","event":"marker.request","fields":{"outputLatency":"0.1"}}"#;
        let events = parse_oplog(text);
        let markers = markers_wall_for(&events, "a");
        assert_eq!(markers.len(), 1, "the stamp-less event is skipped");
        assert!(
            (markers[0].1 - 0.0).abs() < 1e-12,
            "a missing latency reads 0.0"
        );
    }
}
