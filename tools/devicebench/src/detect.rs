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
        Envelope { sample_rate, hop, rms }
    }

    /// Recording time, in seconds, at the start of window `index`.
    pub fn time(&self, index: usize) -> f64 {
        (index * self.hop) as f64 / self.sample_rate
    }

    /// First window at or after `seconds`.
    pub fn index_at(&self, seconds: f64) -> usize {
        ((seconds * self.sample_rate) / self.hop as f64).ceil().max(0.0) as usize
    }
}

/// Median RMS over the first `seconds` of the recording. The recording must
/// start in quiet, so this value is the room and device noise.
pub fn noise_floor(env: &Envelope, seconds: f64) -> f32 {
    let end = env.index_at(seconds).min(env.rms.len()).max(1);
    let mut head = env.rms[..end].to_vec();
    head.sort_by(|a, b| a.partial_cmp(b).unwrap());
    head[head.len() / 2]
}

/// A level that counts as sound: eight times the noise floor, never below `min`.
pub fn threshold(floor: f32, min: f32) -> f32 {
    (floor * 8.0).max(min)
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
            out[start + i] = (0.8 * (2.0 * std::f64::consts::PI * 1000.0 * i as f64 / RATE).sin()) as f32;
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
    fn sound_after_finds_the_first_loud_window() {
        let samples = burst(2.0, 1.2, 50.0);
        let env = Envelope::new(&samples, RATE, 1.0);
        let at = sound_after(&env, 1.0, threshold(0.0, 0.01)).expect("sound");
        assert!((at - 1.2).abs() < 0.001);
    }
}
