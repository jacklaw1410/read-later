//! Level detection on a mono recording. Pure functions, no I/O.

/// RMS level per window. `window_ms` is 1 ms by default, so one value is one millisecond.
pub struct Envelope {
    pub sample_rate: f64,
    pub hop: usize,
    pub rms: Vec<f32>,
}

impl Envelope {
    pub fn new(samples: &[f32], sample_rate: f64, window_ms: f64) -> Self {
        let hop = ((sample_rate * window_ms / 1000.0).round() as usize).max(1);
        let rms = samples
            .chunks(hop)
            .map(|chunk| {
                let energy: f32 = chunk.iter().map(|s| s * s).sum();
                (energy / chunk.len() as f32).sqrt()
            })
            .collect();
        Envelope {
            sample_rate,
            hop,
            rms,
        }
    }

    /// Recording time, in seconds, at the start of window `index`.
    pub fn time(&self, index: usize) -> f64 {
        (index * self.hop) as f64 / self.sample_rate
    }

    /// First window at or after `seconds`.
    pub fn index_at(&self, seconds: f64) -> usize {
        ((seconds * self.sample_rate) / self.hop as f64)
            .ceil()
            .max(0.0) as usize
    }
}

/// Median RMS over the first `seconds` of the recording. The recording must
/// start in quiet, so this value is the room and device noise. An empty
/// recording has no floor, so it reads 0.0 instead of panicking.
pub fn noise_floor(env: &Envelope, seconds: f64) -> f32 {
    if env.rms.is_empty() {
        return 0.0;
    }
    let end = env.index_at(seconds).min(env.rms.len()).max(1);
    let mut head = env.rms[..end].to_vec();
    head.sort_by(|a, b| a.partial_cmp(b).unwrap());
    head[head.len() / 2]
}

/// A level that counts as sound: `factor` times the noise floor, never below `min`.
pub fn threshold_factor(floor: f32, factor: f32, min: f32) -> f32 {
    (floor * factor).max(min)
}

/// A level that counts as sound: eight times the noise floor, never below `min`.
pub fn threshold(floor: f32, min: f32) -> f32 {
    threshold_factor(floor, 8.0, min)
}

/// The level that counts as silence: four times the noise floor of the same
/// recording. There is no fixed minimum, so a quiet room sets a low bar and a
/// loud room a higher one.
pub fn silence_level(floor: f32) -> f32 {
    (floor * 4.0).max(f32::MIN_POSITIVE)
}

/// Merges onsets that are at most `gap` seconds after the previous raw onset.
/// A click rings for a few milliseconds and crosses the threshold several
/// times, so one click gives a cluster of onsets. The first onset of each
/// cluster is the click's start.
pub fn collapse(onsets: &[f64], gap: f64) -> Vec<f64> {
    let mut out = Vec::new();
    let mut previous: Option<f64> = None;
    for &t in onsets {
        if previous.is_none_or(|p| t - p > gap) {
            out.push(t);
        }
        previous = Some(t);
    }
    out
}

/// Rising edges above `threshold`. Each edge is the start of a window that is
/// above the threshold and whose predecessor is not. A 10 ms click gives one edge.
pub fn onsets(env: &Envelope, threshold: f32) -> Vec<f64> {
    let mut out = Vec::new();
    for i in 0..env.rms.len() {
        let above = env.rms[i] >= threshold;
        let was_above = i > 0 && env.rms[i - 1] >= threshold;
        if above && !was_above {
            out.push(env.time(i));
        }
    }
    out
}

/// First sound onset at or after `seconds`.
pub fn sound_after(env: &Envelope, seconds: f64, threshold: f32) -> Option<f64> {
    (env.index_at(seconds)..env.rms.len())
        .find(|&i| env.rms[i] >= threshold)
        .map(|i| env.time(i))
}

/// Start of the first quiet run at or after `seconds` that lasts `min_quiet`
/// seconds. A run that reaches the end of the recording is not counted, because
/// it is too short to prove the sound stopped.
pub fn silence_after(env: &Envelope, seconds: f64, threshold: f32, min_quiet: f64) -> Option<f64> {
    let need = (min_quiet * env.sample_rate / env.hop as f64).ceil() as usize;
    let start = env.index_at(seconds);
    let mut i = start;
    while i + need <= env.rms.len() {
        if env.rms[i..i + need].iter().all(|&r| r < threshold) {
            return Some(env.time(i));
        }
        i += 1;
    }
    None
}

/// The `p`-quantile of the RMS over `window` seconds from `start`. After a
/// pause, a held pause leaves most of the window quiet, so a low quantile gives
/// the quiet level of that place in the recording.
pub fn quantile(env: &Envelope, start: f64, window: f64, p: f64) -> f32 {
    let from = env.index_at(start).min(env.rms.len());
    let to = env.index_at(start + window).min(env.rms.len());
    if to <= from {
        return 0.0;
    }
    let mut slice = env.rms[from..to].to_vec();
    slice.sort_by(|a, b| a.partial_cmp(b).unwrap());
    slice[((slice.len() - 1) as f64 * p).round() as usize]
}

/// Sound that resumes after a restart. A scrub stops the sentence and starts it
/// again, so the audio goes quiet within `stop_within` seconds of the commit.
/// Returns the moment sound comes back above `threshold` after that quiet run,
/// or None when the audio does not go quiet near the commit.
pub fn resumed_after(
    env: &Envelope,
    commit: f64,
    threshold: f32,
    min_quiet: f64,
    stop_within: f64,
) -> Option<f64> {
    let stop = silence_after(env, commit, threshold, min_quiet)?;
    if stop - commit > stop_within {
        return None;
    }
    sound_after(env, stop, threshold)
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: f64 = 48_000.0;

    /// A 1 kHz burst of `ms` milliseconds starting at `at` seconds, in a silent recording.
    fn burst(total_s: f64, at: f64, ms: f64) -> Vec<f32> {
        let n = (total_s * RATE) as usize;
        let mut out = vec![0.0f32; n];
        let start = (at * RATE) as usize;
        let len = (ms / 1000.0 * RATE) as usize;
        for i in 0..len {
            out[start + i] =
                (0.8 * (2.0 * std::f64::consts::PI * 1000.0 * i as f64 / RATE).sin()) as f32;
        }
        out
    }

    #[test]
    fn click_onset_is_within_one_millisecond() {
        let samples = burst(2.0, 0.5, 10.0);
        let env = Envelope::new(&samples, RATE, 1.0);
        let floor = noise_floor(&env, 0.2);
        let found = onsets(&env, threshold(floor, 0.01));
        assert_eq!(found.len(), 1);
        assert!((found[0] - 0.5).abs() < 0.001, "onset {}", found[0]);
    }

    #[test]
    fn two_clicks_give_two_onsets() {
        let mut samples = burst(3.0, 0.5, 10.0);
        for (s, b) in samples.iter_mut().zip(burst(3.0, 1.5, 10.0)) {
            *s += b;
        }
        let env = Envelope::new(&samples, RATE, 1.0);
        let found = onsets(&env, threshold(noise_floor(&env, 0.2), 0.01));
        assert_eq!(found.len(), 2);
        assert!((found[1] - 1.5).abs() < 0.001);
    }

    #[test]
    fn silence_is_found_after_sound_stops() {
        // Sound from 0.0 to 0.8 s, then quiet.
        let samples = burst(3.0, 0.0, 800.0);
        let env = Envelope::new(&samples, RATE, 1.0);
        let thr = threshold(0.0, 0.01);
        let stop = silence_after(&env, 0.0, thr, 0.3).expect("silence");
        assert!((stop - 0.8).abs() < 0.002, "stop {stop}");
    }

    #[test]
    fn a_short_gap_is_skipped_and_the_real_silence_is_found() {
        // Sound 0 to 0.3 s, a 100 ms gap, sound 0.4 to 0.7 s, then quiet.
        // The gap is shorter than min_quiet, so the silence starts at 0.7 s.
        let mut samples = burst(2.0, 0.0, 300.0);
        for (s, b) in samples.iter_mut().zip(burst(2.0, 0.4, 300.0)) {
            *s += b;
        }
        let env = Envelope::new(&samples, RATE, 1.0);
        let thr = threshold(0.0, 0.01);
        let stop = silence_after(&env, 0.0, thr, 0.3).expect("silence");
        assert!((stop - 0.7).abs() < 0.002, "stop {stop}");
    }

    #[test]
    fn a_click_cluster_collapses_to_its_first_onset() {
        // Four crossings within 25 ms, then a separate click 1 s later.
        let found = [8.262, 8.277, 8.279, 8.286, 9.243];
        assert_eq!(collapse(&found, 0.05), vec![8.262, 9.243]);
        assert_eq!(collapse(&[], 0.05), Vec::<f64>::new());
    }

    #[test]
    fn silence_level_follows_the_noise_floor() {
        assert!((silence_level(0.002) - 0.008).abs() < 1e-7);
        assert!(
            silence_level(0.0) > 0.0,
            "a silent head must still give a positive level"
        );
    }

    #[test]
    fn quantile_reads_the_quiet_part_of_the_window() {
        // Sound from 0 to 2 s, then silence to 6 s. Four of six seconds are quiet.
        let samples = burst(6.0, 0.0, 2000.0);
        let env = Envelope::new(&samples, RATE, 1.0);
        assert_eq!(quantile(&env, 0.0, 6.0, 0.10), 0.0);
        assert!(
            quantile(&env, 0.0, 6.0, 1.0) > 0.1,
            "the loud part is above the quiet part"
        );
    }

    #[test]
    fn sound_after_finds_the_first_loud_window() {
        let samples = burst(2.0, 1.2, 50.0);
        let env = Envelope::new(&samples, RATE, 1.0);
        let at = sound_after(&env, 1.0, threshold(0.0, 0.01)).expect("sound");
        assert!((at - 1.2).abs() < 0.001);
    }

    #[test]
    fn onsets_on_an_empty_envelope_is_empty() {
        let env = Envelope::new(&[], RATE, 1.0);
        assert!(env.rms.is_empty());
        assert_eq!(onsets(&env, 0.01), Vec::<f64>::new());
        assert_eq!(sound_after(&env, 0.0, 0.01), None);
        assert_eq!(silence_after(&env, 0.0, 0.01, 0.3), None);
    }

    #[test]
    fn empty_input_gives_empty_results_not_a_panic() {
        let env = Envelope::new(&[], RATE, 1.0);
        assert!(env.rms.is_empty());
        assert_eq!(noise_floor(&env, 0.5), 0.0);
        assert_eq!(onsets(&env, 0.01), Vec::<f64>::new());
        assert_eq!(sound_after(&env, 0.0, 0.01), None);
        assert_eq!(silence_after(&env, 0.0, 0.01, 0.3), None);
        assert_eq!(quantile(&env, 0.0, 6.0, 0.10), 0.0);
        assert_eq!(resumed_after(&env, 0.0, 0.01, 0.05, 0.5), None);
    }

    #[test]
    fn queries_past_the_end_find_nothing() {
        let samples = burst(2.0, 0.5, 100.0);
        let env = Envelope::new(&samples, RATE, 1.0);
        assert_eq!(sound_after(&env, 5.0, threshold(0.0, 0.01)), None);
        assert_eq!(silence_after(&env, 5.0, threshold(0.0, 0.01), 0.3), None);
        assert_eq!(quantile(&env, 5.0, 6.0, 0.10), 0.0);
    }

    #[test]
    fn a_quiet_tail_shorter_than_min_quiet_is_not_silence() {
        // Sound 0 to 0.9 s, then 0.1 s of quiet at the end. The tail run never
        // reaches min_quiet inside the recording, so no silence is reported.
        let samples = burst(1.0, 0.0, 900.0);
        let env = Envelope::new(&samples, RATE, 1.0);
        assert_eq!(silence_after(&env, 0.0, threshold(0.0, 0.01), 0.3), None);
    }

    #[test]
    fn quantile_zero_and_one_are_min_and_max() {
        let samples = burst(2.0, 0.0, 1000.0);
        let env = Envelope::new(&samples, RATE, 1.0);
        assert_eq!(quantile(&env, 0.0, 2.0, 0.0), 0.0);
        assert!(quantile(&env, 0.0, 2.0, 1.0) > 0.1);
    }

    #[test]
    fn quantile_endpoints_read_the_ends_of_the_window() {
        // Sound from 0 to 2 s, then silence to 6 s.
        let samples = burst(6.0, 0.0, 2000.0);
        let env = Envelope::new(&samples, RATE, 1.0);
        assert_eq!(quantile(&env, 0.0, 6.0, 0.0), 0.0);
        assert!(quantile(&env, 0.0, 6.0, 1.0) > 0.1);
    }

    #[test]
    fn collapse_merges_onsets_exactly_gap_apart() {
        // 0.0625 is exact in binary, so this pins the "at most gap" bound
        // without floating-point doubt.
        assert_eq!(collapse(&[2.0, 2.0625, 3.0], 0.0625), vec![2.0, 3.0]);
    }

    #[test]
    fn collapse_gap_boundary_merges_at_exactly_gap() {
        // 0.25 is exact in binary, so the boundary comparison is deterministic.
        assert_eq!(collapse(&[1.0, 1.25], 0.25), vec![1.0]);
        assert_eq!(collapse(&[1.0, 1.250001], 0.25), vec![1.0, 1.250001]);
        assert_eq!(collapse(&[1.0], 0.25), vec![1.0]);
    }

    #[test]
    fn threshold_minimum_holds_for_a_quiet_head() {
        assert_eq!(threshold(0.0, 0.01), 0.01);
        assert_eq!(threshold_factor(0.001, 8.0, 0.01), 0.01);
        assert!(threshold_factor(0.002, 8.0, 0.01) > 0.01);
    }

    #[test]
    fn index_at_clamps_negative_time_to_zero() {
        let samples = burst(1.0, 0.5, 10.0);
        let env = Envelope::new(&samples, RATE, 1.0);
        assert_eq!(env.index_at(-1.0), 0);
        assert_eq!(env.time(0), 0.0);
    }

    #[test]
    fn a_restart_gap_gives_the_return_of_sound() {
        // Speech through 1.0 s, a restart gap of 80 ms, speech again from 1.08 s.
        // The commit is at 0.95 s, so the stop starts 50 ms later, inside the window.
        let mut samples = burst(3.0, 0.0, 1000.0);
        for (s, b) in samples.iter_mut().zip(burst(3.0, 1.08, 400.0)) {
            *s += b;
        }
        let env = Envelope::new(&samples, RATE, 1.0);
        let at = resumed_after(&env, 0.95, threshold(0.0, 0.01), 0.05, 0.5).expect("resumed");
        assert!((at - 1.08).abs() < 0.002, "resumed {at}");
    }

    #[test]
    fn continuous_sound_after_a_commit_is_not_a_restart() {
        // Speech through 2.0 s, then a long pause. The stop begins 1.5 s after the commit,
        // which is outside the window, so there is no restart to time.
        let samples = burst(4.0, 0.0, 2000.0);
        let env = Envelope::new(&samples, RATE, 1.0);
        assert_eq!(
            resumed_after(&env, 0.5, threshold(0.0, 0.01), 0.05, 0.5),
            None
        );
    }

    #[test]
    fn a_restart_at_the_edge_of_the_window_counts() {
        // Quiet starts exactly stop_within after the commit. The bound is
        // inclusive: only a later start is rejected.
        let mut samples = burst(3.0, 0.0, 1000.0);
        for (s, b) in samples.iter_mut().zip(burst(3.0, 1.5, 400.0)) {
            *s += b;
        }
        let env = Envelope::new(&samples, RATE, 1.0);
        let at = resumed_after(&env, 0.5, threshold(0.0, 0.01), 0.05, 0.5).expect("resumed");
        assert!((at - 1.5).abs() < 0.002, "resumed {at}");
    }

    #[test]
    fn a_restart_just_outside_the_window_does_not_count() {
        // Same audio, but the commit is 10 ms earlier, so the quiet start is
        // outside the window.
        let mut samples = burst(3.0, 0.0, 1000.0);
        for (s, b) in samples.iter_mut().zip(burst(3.0, 1.5, 400.0)) {
            *s += b;
        }
        let env = Envelope::new(&samples, RATE, 1.0);
        assert_eq!(
            resumed_after(&env, 0.49, threshold(0.0, 0.01), 0.05, 0.5),
            None
        );
    }

    #[test]
    fn restart_stop_window_boundary_is_inclusive() {
        // Speech through 1.0 s, an 80 ms gap, speech again from 1.08 s.
        // The stop starts exactly 0.5 s after the commit, which still counts.
        let mut samples = burst(3.0, 0.0, 1000.0);
        for (s, b) in samples.iter_mut().zip(burst(3.0, 1.08, 400.0)) {
            *s += b;
        }
        let env = Envelope::new(&samples, RATE, 1.0);
        let at = resumed_after(&env, 0.5, threshold(0.0, 0.01), 0.05, 0.5);
        assert!((at.unwrap() - 1.08).abs() < 0.002, "resumed {at:?}");
        assert_eq!(
            resumed_after(&env, 0.499, threshold(0.0, 0.01), 0.05, 0.5),
            None
        );
    }
}
