# ADR-0003 — willSpeakRangeOfSpeechString is the wash source of truth

Status: accepted · Date: 2026-11-12

## Decision

The karaoke wash follows `speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)`
and nothing else. The synthesizer queue holds 2 utterances of prefetch.
At load, the spoken-plan invariant runs: every spoken sentence must be
an exact slice of its block text, and any failure blocks playback.

## Context

The callback delivers an NSRange per word; the reader maps it with
`docRange = charOffset + range.location`. Measured over a full
4,500-word article (623 sentences, 4,483 callbacks, 26.4 minutes) the
map drifted 0 times (`spec/target-design.md` §TTS,
`spec/state-machines.md` §Truth,
`evidence/2026-11-10-playback-endurance/`). Rate 1.0 is the reference
pace at about 140 words per minute. The synthesizer cold start was
1,139.7 ms in the harness (1.1–2.6 s across runs), so pre-warm stays
required; the absolute 700 ms gate is withdrawn and the measure is now
staged (T0–T7, `spec/device-test-plan.md` D2a–D2c).

The block plan carries each sentence as an `(offset, length, text)`
slice of its block (`spec/non-prose-classification.md`, block model).
The builder exits non-zero without writing when a sentence is not an
exact slice, and the run holds 0 failures over 12,240 sentences.

## Consequences

- No timer, no estimated pace, no second position source. Word 0 is
  visible immediately and the ring never points at a table cell.
- Prefetch 2 is the default in `SpeechController.speak`; changing it
  is a measured change, not a tuning constant.
- The invariant runs before the first utterance, so a bad plan fails
  at load instead of mid-sentence.

## Rejected

- Timer-driven highlight. Drifts with rate, voice and language, and
  the drift is silent.
- Android-style range-start-only callbacks. iOS gives the full range;
  the end is measured on Android, not here (`spec/engineering.md` §1.2).
