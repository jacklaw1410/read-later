# devicebench

Measures the reader on the phone with the Mac microphone. The plan is
`read-later-research/spec/device-verification-latency.md`. This crate
implements its sections 2 to 4. It does not run the app.

## Commands

```
cargo build --release
B=target/release/readlater-devicebench

$B record --seconds 60 --out run.wav            # Mac microphone, 32-bit float mono
$B onsets --wav run.wav                          # click and sound onsets, in seconds
$B align --telemetry telemetry.jsonl --wav run.wav  # phone events mapped onto the recording
$B gen --out clicks.wav --times 1,2,3 --seconds 5   # test clicks for the speaker
```

`align` prints CSV on stdout:

```
session,event,phone_t,rec_t,response_ms,silence_level
```

- `tap.pause` gives the time from the tap to silence (M2). Silence is the first
  quiet run of at least `--silence` seconds (default 0.3 s), so a short gap
  between words does not count. The silence level is the quiet level of the 6 s
  window after the tap, times `--quiet-factor` (default 1.5), and never below
  four times the noise floor of the recording. The level is in the last column.
- `tap.play` and `scrub.commit` give the time from the event to the first sound (M3, M4).
- A click is a cluster of onsets. Its first onset is the click. A click is
  matched to the phone's spacing with a 0.03 s tolerance, and 0.08 s for the
  first step. Sessions with a stray peak still match.
- The offset and the clock error go to stderr:
  `offset ... clock error ... ms over clicks 2 to N, click 1 residual ... ms`.
  Click 1 starts late in every run seen so far, so the error skips it.
- `--click-factor` sets the click threshold as a multiple of the noise floor
  (default 8). A quiet recording may need 4.
- `--clock-session ID` takes the clicks from one app launch and applies the
  offset to the taps of other launches, through the phone's wall clock (`iso`).
  Use it when the markers and the taps are in different sessions.

## Clock alignment

The app logs `marker.request` for each click (debug build, `--debug.marker=N`).
Each event carries `t`, the telemetry time. The click reaches the Mac at recording
time `O_i`, and `outputLatency` is the session output latency, so:

    offset = median(O_i - (t_i + outputLatency_i))
    recording time = phone t + offset

The plan's `δ` is the phone clock minus the Mac clock, so `δ = -offset`.

`align` matches the clicks by their spacing. Speech also makes onsets, so
"the first N onsets" would be wrong. The clock error is the largest distance of
clicks 2 onward from the median. Click 1 is reported apart, because its cold-start
delay is real and appears in every run. Report the error with every batch.

## Protocol for one run

1. Start the recording (`record`) before the app launch. Keep the room quiet
   for the first 0.5 s, because that window sets the noise floor.
2. Launch the Debug app with `--debug.marker=3`. The marker plays three clicks,
   starting 2 s after launch.
3. Run the test (taps, scrubs). Stop the recording after the run.
4. Copy the telemetry log from the phone (`devicectl device copy from`, section 6 of the plan).
5. `align` the telemetry log against the WAV.

## Limits

- The threshold is eight times the noise floor, with a floor of 0.01 RMS. A
  quiet room is needed. Check the onset list for false clicks.
- Detection uses 1 ms RMS windows. Onset precision is about 1 ms, but the
  clock error is usually larger, because it includes the output path.
- Sound from before a tap is not removed. Begin each response measurement in
  silence.
- Input is the first channel only. The MacBook microphone has one channel.

## Tests

```
cargo test
```

The unit tests use synthetic signals. They cover onset timing, silence and the
gap rule, the clock fit, click matching and telemetry parsing.
