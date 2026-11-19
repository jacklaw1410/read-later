# Read Later

A reading app for people who read in a language they are learning. The reader pastes an article, hears it read aloud with a moving highlight, and taps a word for a short gloss in their own language without leaving the page. This glossary defines the terms the code and the UI use. Each concept has one term.

## The reader's experience

**Flow**:
The reader's uninterrupted attention on the text. Product decisions are judged by whether they preserve flow.
_Avoid_: immersion, engagement, focus

**Flow break**:
Any moment the reader must leave the text to resolve something: an unknown word, a lost place, a link, or an app switch.

**MVP**:
The smallest build that preserves flow. Saving and notes are excluded.
_Avoid_: v1, first release, phase 1

**Wash**:
The moving highlight that marks the word being spoken.
_Avoid_: highlight, marker, cursor, karaoke

**Wash lead**:
How far the wash runs ahead of the voice. Currently half a word, because the eye runs ahead of the ear in a second language.
_Avoid_: offset, latency

**Hold**:
The state where the reader has scrolled away from the wash, so auto-scroll stops following. The hold badge offers resume.
_Avoid_: pause (that is audio), lock, detach

**No-yank**:
The rule that auto-scroll never overrides the reader's own scroll.
_Avoid_: sticky scroll, follow

**Resume**:
Returning the wash to its position after a lookup, note or link, with playback and hold restored.

## Playback

**Spoken index space**:
The numbering of words that are actually spoken. Progress, time left and scrubbing are computed here. Skipped regions have no index.
_Avoid_: timeline, word count

**Honest denominator**:
The rule that progress and time left count only spoken words. A page of tables cannot claim time it never speaks.
_Avoid_: accurate progress

**Skip**:
The action that passes over a region with no spoken words and no seconds. The class of content it passes over is non-prose.
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

**Karaoke invariant**:
The load-time check that every utterance is an exact slice of its block's text. Zero failures is the pass condition.
_Avoid_: validator, sanity check

**Drift**:
The wash pointing at a different word than the voice is speaking. The target is zero. A physical device is the decisive check. Unit tests and desktop harness runs support it, but do not replace a device check. The karaoke invariant does not measure drift: it checks that utterances slice their blocks.
_Avoid_: lag, desync, offset

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

**Pinned fixture** (a *pin*):
A frozen copy of a page's HTML, stored so that extraction can be replayed byte for byte.
_Avoid_: snapshot, capture, sample

## Lookup and dictionaries

**Gloss**:
A short meaning in the gloss language, shown in place, without leaving the text. Not a definition, and not a sentence translation. The MVP gloss language is Traditional Chinese (zh_HK).
_Avoid_: definition, translation, meaning

**Language pair**:
The source language and the gloss language, set as one parameter. The MVP pair is English to Traditional Chinese (zh_HK). The vision is every pair.
_Avoid_: locale, direction

**Built-in dictionary**:
The Apple dictionary for the chosen pair, already installed on the device, where the OS returns its text. In the MVP it is available on macOS only (`zh_TW-en.DrEye`). It costs nothing to ship. Availability varies by device.
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
The long tail of rare, unranked headwords. Readers tap them, so the pack keeps every headword.
_Avoid_: long tail, rare words

**Miss** (*miss state*):
A tap whose lookup returns no gloss. The miss state is what the card shows: not in dictionary, no network, or an accent variant was matched. A miss describes the result, not the reader or the word.
_Avoid_: error, failure, unknown word
