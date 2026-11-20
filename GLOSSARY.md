# Read Later

A reading app for people who read in a language they are learning. The reader pastes an article, hears it read aloud with a moving highlight, and taps a word for a short gloss in their own language without leaving the page. This glossary defines the terms the code and the UI use. Each concept has one term.

## The reader's experience

**Flow**:
The reader's uninterrupted attention on the text. Product decisions are judged by whether they preserve flow.
_Avoid_: immersion, engagement, focus

**Flow break**:
Any interruption to the act of reading: an unknown word, a lost place, a link, or an app switch.

**MVP**:
The smallest build that preserves flow. Saving and notes are excluded.
_Avoid_: v1, first release, phase 1

**Wash**:
The moving highlight that marks the word being spoken, so the reader can follow the audio and stay in flow.
_Avoid_: highlight, marker, cursor, karaoke

**Wash lead**:
How far, in words, the wash runs ahead of the voice.
_Avoid_: offset, latency

**Hold**:
The state where the reader has scrolled away from the wash, so auto-scroll stops following. The hold badge offers resume.
_Avoid_: pause (that is audio), lock, detach

**No-yank**:
The rule that auto-scroll never overrides the reader's own scroll.
_Avoid_: sticky scroll, follow

**Resume**:
Returning the wash to its position after a lookup, note or link, with playback and hold restored.

## App states

**App state**:
A state of the app the reader moves between, such as Entry and Reader.
_Avoid_: screen, view, page

**Entry**:
The app state where the reader pastes a link or text to open an article.
_Avoid_: view, paste screen, screen

**Reader**:
The app state showing one document: article body, playback controls, and overlays. Capitalized: the app state; lowercase 'reader' is the person.
_Avoid_: view, reading view, screen

## Playback

**Spoken word numbering**:
The numbering of words that are actually spoken. Progress, time left and scrubbing are computed here. Skipped regions have no number.
_Avoid_: timeline, word count

**Spoken-only progress**:
Progress and time left count spoken words only. The contrast is skipped content, which adds no words and no seconds. A page of tables cannot claim time it never speaks.
_Avoid_: accurate progress, honest denominator

**Skip**:
The wash jumps over a non-prose region without speaking it. The region adds no time to time left.
_Avoid_: mute, hide, omit

**Skipped region**:
A contiguous run of non-prose that the wash hops over. The meta line counts them as "M regions skipped by audio".
_Avoid_: gap, hole, dead zone

**Utterance**:
One string handed to the speech engine, normally one sentence. The engine's unit, not the linguist's.
_Avoid_: sentence (reserve that for text), chunk, phrase

**Spoken plan**:
The exact utterances handed to the speech engine for one document, with their offsets. The input to speech, as distinct from the extracted text.
_Avoid_: utterance plan, script, transcript, segment list

**Spoken plan invariant**:
The load-time check that every utterance is an exact slice of its block's text. Zero failures is the pass condition.
_Avoid_: karaoke invariant, validator, sanity check

**Drift**:
The gap between the wash's actual word and the word the Wash lead prescribes for the voice's current word. The target is zero: the wash keeps the prescribed lead. A recording of the screen and the audio together, made on a device, is the decisive evidence. Unit tests and desktop harness runs support it, but do not replace that recording. The spoken plan invariant does not measure drift: it checks that utterances slice their blocks.
_Avoid_: lag, desync, offset

## Playback controls

**Scrub**:
Dragging the progress control to preview a place; the audio seek commits on release.
_Avoid_: drag

**Step**:
Moving the wash by one utterance (normally one sentence).
_Avoid_: word step, sentence step

**Speed**:
The speech speed, chosen from the fixed steps.
_Avoid_: tempo, rate, pace

## Text and extraction

**Block**:
A unit of extracted content with a kind (paragraph, code, table, image) and a confidence. The unit the reader renders and the speech queue consumes.
_Avoid_: node, element, chunk

**Non-prose**:
Content that is not read aloud: code, tables, images, math, embeds and pull quotes. Headings are spoken.
_Avoid_: junk, noise

**Page chrome** (*chrome*):
Page furniture outside the article: navigation, ads, cookie banners and "skip to main content". Extraction removes it. The reader does not skip it. Write *page chrome* where "chrome" could mean the browser.
_Avoid_: boilerplate, clutter

**Pin**:
A copy of a page's HTML, stored so that extraction can be replayed byte for byte.
_Avoid_: fixture, snapshot, capture, sample

## Lookup and dictionaries

**Gloss**:
A short meaning in the gloss language, shown in place, without leaving the text. Not a definition, and not a sentence translation. The MVP gloss language is Traditional Chinese (zh_HK).
_Avoid_: definition, translation, meaning

**Language pair**:
The source language and the gloss language, set as one parameter. The MVP pair is English to Traditional Chinese (zh_HK). The vision is every pair.
_Avoid_: locale, direction

**Built-in dictionary**:
The Apple dictionary for the chosen pair, already installed on the device, where the OS returns its text. In the MVP it is available on macOS only. It costs nothing to ship. Availability varies by device.
_Avoid_: system dictionary, Apple dictionary

**Capability pack**:
Downloadable data that adds a capability, such as a dictionary. Installed once, then used locally.
_Avoid_: bundle, add-on, plugin, extension

**Lexical pack**:
The one dictionary pack. It holds the headword, the Chinese gloss, the phonetic and the part of speech in one file. There is no smaller variant.
_Avoid_: glossary pack, gloss-only pack, lite/full, basic/pro

**Headword**:
The form a dictionary stores an entry under. A word on the page is not always a headword.
_Avoid_: lemma, entry, key

**Pointer gloss**:
A gloss that names another word instead of giving a meaning, for example `vi., vt. ovate的變形`. Lookup follows the pointer to the other word.
_Avoid_: cross-reference, stub entry

**Tail**:
The long tail of rare, unranked headwords. Readers tap them.
_Avoid_: long tail (say *tail*), rare words

**Miss** / **miss state**:
A miss is a tap whose lookup returns no gloss. The miss state is what the card shows: not in dictionary, no network, or an accent variant was matched. A miss describes the result, not the reader or the word.
_Avoid_: error, failure, unknown word

## Packs

**Decline**:
The reader's permanent choice not to install on this device. After a decline, the offer is not shown again; the pack can still be installed later.
_Avoid_: dismiss, reject

**Installed**:
A pack present locally and used for lookups.
_Avoid_: enabled, active

**Update**:
A newer pack available for an already installed one. Checked when pack management opens, not at launch.
_Avoid_: upgrade, new version, update available, updateVersion, isUpdateAvailable

**Pack management**:
The place where packs are installed, updated, or removed.
_Avoid_: dictionaries, add-ons, plugins

## Surfaces

**App chrome**:
The app-level bar of an app state: title, back, and/or action controls as needed. App chrome is the app's top bar; page chrome is page furniture outside the article.
_Avoid_: page chrome, header, toolbar, top bar


**Strip**:
The panel on the entry app state showing the detected kind. The paste control appears when the field is empty and the clipboard is non-empty.
_Avoid_: status strip, banner

**Loadline**:
The progress indicator through Fetch, Clean, and Ready on the entry app state.
_Avoid_: progress bar, stepper

**Rail**:
The playback control column beside the reader: speed and scrub.
_Avoid_: sidebar

**Bottom transport**:
The bottom playback controls: play, pause, and steps.
_Avoid_: bottom bar, player bar, transport bar

**Lookup card**:
The overlay panel for a lookup that resolved to a gloss. Never a SwiftUI sheet.
_Avoid_: sheet, modal, popup, popover, hit card

**Miss card**:
The overlay panel for a lookup with no gloss, showing the miss state and available actions. Never a SwiftUI sheet.
_Avoid_: sheet, modal, popup, popover, error card, failure card

## Library

**Library**:
The sheet listing started articles, with 'saved' as a flag on each row.
_Avoid_: saved list, history, browse list

**Reading position**:
Where reading stands in an article: its place, saved flag, and finished flag. Seeded into the wash on reopen. The place is the word index.
_Avoid_: row, record, entry

**Saved**:
A reader-chosen flag on a reading position, shown as a bookmark.
_Avoid_: bookmark, starred

**Finished**:
An article whose wash reached the last spoken word. Aligns with spoken-only progress: skipped regions add no spoken words.
_Avoid_: completed, done

**Refresh**:
Dropping the cached plan while keeping the place. Reopening refetches the article only when the plan is missing and a URL is stored.
_Avoid_: cache bust, reload

**Remove**:
Dropping the article and its place together.
_Avoid_: forget, delete

## Measurement

**Venue**:
Where a run happens. On iOS, the **simulator** (Xcode Simulator on a Mac) emulates the app, and a **physical device** (an iPhone) runs it. On macOS, the Mac is the physical device, so no simulator venue applies. The venue follows where the app runs, not which tool records it.
_Avoid_: device (alone), target, platform

**Evidence level**:
How much a run records. Level 1 is the telemetry alone. Level 2 is pure audio or pure screen plus the telemetry. Level 3 is screen and audio plus the timeline telemetry.
_Avoid_: tier (the MVP tiers already use it), grade, strength

**Telemetry**:
The app's timestamped measurement log, one JSON line per event.
_Avoid_: oplog (that name belongs to the sync log), trace, log

**Oplog**:
The append-only log of sync operations, replayed to bring a store up to date. It records changes, not measurements.
_Avoid_: telemetry, measurement log

**Timeline telemetry**:
Telemetry whose timestamps share a clock with a recording, so each event maps to a moment in the recording.
_Avoid_: synced log, timeline oplog

**Screen recording**, **audio recording**:
A recording of the picture alone, or of the sound alone. A recording of both is a screen and audio recording.
_Avoid_: video (unclear whether it has sound)
