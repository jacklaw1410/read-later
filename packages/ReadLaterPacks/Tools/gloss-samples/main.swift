// gloss-samples: picks the 20 headwords for the owner sample sheet and
// renders each through the real lookup path (SQLite index plus
// PackIndexStore.displayEntry), so the sheet shows the exact card string.
//
// Usage:
//   swift run --package-path packages/ReadLaterPacks gloss-samples <pack.gz> [--out-dir <dir>]
//
// Prints the 20 headwords to stdout and writes gloss-samples.md and
// gloss-samples.html beside the out dir. The selection rule is fixed and
// stated in the markdown it writes; rerunning the command on the same pack
// prints the same 20 words.
import Foundation
import ReadLaterPacks

struct SampleRecord: Sendable {
    var headword: String
    var phonetic: String
    var partOfSpeech: String
    var subtitle: String?
    var cardGloss: String
}

struct GlossSamples: Sendable {
    var records: [(word: String, phonetic: String, pos: String, gloss: String)] = []
    var byKey: [String: Int] = [:]
    var rawWords: Set<String> = []

    mutating func add(word: String, phonetic: String, pos: String, gloss: String) {
        rawWords.insert(word)
        let key = PackIndexStore.normalize(word)
        if byKey[key] == nil {
            byKey[key] = records.count
            records.append((word, phonetic, pos, gloss))
        }
    }

    func record(for word: String) -> (word: String, phonetic: String, pos: String, gloss: String)? {
        byKey[PackIndexStore.normalize(word)].map { records[$0] }
    }
}

func isLowerWord(_ w: String) -> Bool {
    guard let first = w.first, first.isLetter, first.isLowercase else { return false }
    return w.allSatisfy { ($0.isLetter && $0.isLowercase) || $0 == "'" || $0 == "-" }
}

func isPlainAlpha(_ w: String) -> Bool {
    w.count >= 2 && w.allSatisfy { $0.isLowercase && $0.isLetter && $0.isASCII }
}

/// True when every sense line is an abbreviation expansion. `aahs` ships
/// only `abbr.[軍] …`, the military acronym for AH, and the base-form note in
/// front of it names a different word. Such a card answers a question the
/// reader did not ask, so the sheet skips the word.
func abbreviationOnly(_ gloss: String) -> Bool {
    let lines = GlossRenderer.splitLines(gloss)
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard !lines.isEmpty else { return true }
    return lines.allSatisfy { GlossRenderer.prepare($0).pos?.hasPrefix("abbr") == true }
}

func mixedTag(_ gloss: String) -> Bool {
    let lines = GlossRenderer.splitLines(gloss).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard lines.count > 1 else { return false }
    let flags = lines.map { GlossRenderer.isTagged($0.trimmingCharacters(in: .whitespaces)) }
    return flags.contains(true) && flags.contains(false)
}

/// True when a line carries a base-form note *after* sense text, which is the
/// shape rule 3 targets: `摻奶的( milky的最高級 )`. A note that opens the line
/// (`(aah 的現在分詞) abbr.[軍] Armored Artillery Howitzer`) describes the
/// headword, not a sense, and it produced a card that answered a different
/// question: `aahhing` showed the military acronym for AH.
func parenInSense(_ gloss: String) -> Bool {
    for raw in GlossRenderer.splitLines(gloss) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard let open = line.firstIndex(where: { $0 == "(" || $0 == "（" }) else { continue }
        let closer: Character = line[open] == "(" ? ")" : "）"
        guard let close = line[line.index(after: open)...].firstIndex(of: closer) else { continue }
        let inner = line[line.index(after: open)..<close]
        guard GlossRenderer.pointerPhrases.contains(where: inner.contains) else { continue }
        let before = GlossRenderer.cleanLine(String(line[..<open]))
        guard !before.isEmpty else { continue }
        // An abbreviation entry is not a sense either: the card would show
        // the expansion of a different word.
        if GlossRenderer.prepare(line).pos?.hasPrefix("abbr") == true { continue }
        return true
    }
    return false
}

@main
struct Main {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fputs("usage: gloss-samples <pack.gz> [--out-dir <dir>]\n", stderr)
            exit(2)
        }
        let packURL = URL(fileURLWithPath: args[1])
        var outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let i = args.firstIndex(of: "--out-dir"), i + 1 < args.count {
            outDir = URL(fileURLWithPath: args[i + 1])
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let id = "dictionary.en-zh-HK.lexical"
        let archive = work.appendingPathComponent("\(id).pack.gz")
        try FileManager.default.copyItem(at: packURL, to: archive)
        let sqlite = try PackIndexBuilder.build(archiveURL: archive, directory: work)
        let store = PackIndexStore(sqliteURL: sqlite)

        // Full-text scan for classification. Parses the same TSV the index
        // builder reads, so the classes match the shipped pack exactly.
        let tsvURL = work.appendingPathComponent("\(id).tsv.tmp")
        try Gzip.gunzip(archive: archive, to: tsvURL)
        let text = try String(contentsOf: tsvURL, encoding: .utf8)
        var table = GlossSamples()
        var order: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4, !parts[0].isEmpty else { continue }
            let gloss = parts[3...].joined(separator: "\t")
                .replacingOccurrences(of: "\\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !gloss.isEmpty else { continue }
            table.add(word: parts[0], phonetic: parts[1], pos: parts[2], gloss: gloss)
            order.append(parts[0])
        }

        func resolvedGloss(_ word: String) -> String? {
            store.displayEntry(for: word)?.gloss
        }

        // Pointer: alphabetical, lowercase, pointer-only, resolves to a gloss
        // that carries Chinese.
        var pointer: [String] = []
        for word in order.sorted() where pointer.count < 5 {
            guard isLowerWord(word), word.count >= 4 else { continue }
            guard let rec = table.record(for: word), GlossRenderer.isPointerOnly(rec.gloss) else { continue }
            guard let gloss = resolvedGloss(word),
                  gloss.unicodeScalars.contains(where: { $0.value > 255 })
            else { continue }
            pointer.append(word)
        }

        // Mixed-tag: alphabetical, plain lowercase alpha words.
        var mixed: [String] = []
        for word in order.sorted() where mixed.count < 5 {
            guard isPlainAlpha(word), !pointer.contains(word) else { continue }
            guard let rec = table.record(for: word), !abbreviationOnly(rec.gloss),
                  mixedTag(rec.gloss)
            else { continue }
            mixed.append(word)
        }

        // Parenthetical: alphabetical; a base-form note follows sense text.
        var paren: [String] = []
        for word in order.sorted() where paren.count < 5 {
            guard isPlainAlpha(word), !pointer.contains(word), !mixed.contains(word) else { continue }
            guard let rec = table.record(for: word), !abbreviationOnly(rec.gloss),
                  parenInSense(rec.gloss)
            else { continue }
            paren.append(word)
        }

        // Ordinary: three fixed common words.
        let ordinary = ["serendipity", "cafe", "water"].filter { table.record(for: $0) != nil }

        // Accent: tapped spellings absent from the pack that resolve through
        // accent folding. Fixed probe order; the first two that resolve win.
        let probes = ["café", "cliché", "façade", "naïve", "fiancée", "résumé", "protégé", "piñata", "coöperate", "über"]
        var accent: [String] = []
        for tapped in probes where accent.count < 2 {
            guard !table.rawWords.contains(tapped),
                  let display = store.displayEntry(for: tapped),
                  display.subtitle != nil
            else { continue }
            accent.append(tapped)
        }

        let picked = pointer + mixed + paren + ordinary + accent
        guard picked.count == 20, Set(picked).count == 20 else {
            fputs("selection failed: \(picked.count) words, \(Set(picked).count) distinct\n", stderr)
            exit(1)
        }

        func sample(_ tapped: String) throws -> SampleRecord {
            guard let display = store.displayEntry(for: tapped) else {
                fputs("missing entry for \(tapped)\n", stderr)
                exit(1)
            }
            let stored = table.record(for: display.subtitle ?? tapped) ?? table.record(for: tapped)
            return SampleRecord(
                headword: tapped,
                phonetic: stored?.phonetic ?? "",
                partOfSpeech: stored?.pos ?? "",
                subtitle: display.subtitle,
                cardGloss: display.gloss
            )
        }

        let groups: [(String, [SampleRecord])] = try [
            ("Pointer glosses — resolved through the base word", pointer.map(sample)),
            ("Mixed-tag entries — untagged first, at most one tagged line", mixed.map(sample)),
            ("Grammar parentheticals — the base-form note is dropped", paren.map(sample)),
            ("Ordinary words", ordinary.map(sample)),
            ("Accent variants — tapped spelling over the stored headword", accent.map(sample)),
        ]

        for word in picked { print(word) }
        try writeMarkdown(groups: groups, picked: picked, packURL: packURL, outDir: outDir)
        try writeHTML(groups: groups, outDir: outDir)
    }

    static func writeMarkdown(
        groups: [(String, [SampleRecord])],
        picked: [String],
        packURL: URL,
        outDir: URL
    ) throws {
        var md = """
        # Gloss sample sheet — 20 headwords, rendered by the lookup path

        Each card string below is the exact output of
        `PackIndexStore.displayEntry(for:)` on the installed index: the three
        gloss rules from `spec/dictionary-packs.md` §4 already ran. The card
        shows at most \(GlossRenderer.maxLines) gloss lines, in source order.

        Reproduce the list:

        ```bash
        swift run --package-path packages/ReadLaterPacks gloss-samples \(packURL.lastPathComponent)
        ```

        Selection rule (fixed; alphabetical over the pack's headwords):

        - Pointer (5): lowercase words whose gloss holds only a pointer and
          whose base word resolves to a Chinese gloss.
        - Mixed-tag (5): plain lowercase words with untagged and tagged lines.
        - Parenthetical (5): plain lowercase words where a base-form note
          follows sense text, so rule 3 changes the line.
        - Ordinary (3): fixed — `serendipity`, `cafe`, `water`.
        - Accent (2): fixed probe order — the first two diacritic spellings
          absent from the pack that resolve through accent folding.

        A word whose only sense is an abbreviation expansion is skipped: `aahs`
        ships only `abbr.[軍] Armored Artillery Howitzer`, and a card that
        describes AH instead of "said aah" answers the wrong question.

        Pointer-only here means the gloss names a base word and carries no
        Chinese of its own (7,109 headwords). The 28,151 count in the review
        also counts rows that pair a pointer note with a tagged sense (e.g.
        `(a-frame 的複數) [機] A型架`); those render their own sense, so the
        card shows the meaning instead of resolving.

        The pack's `pos` column is empty for all 770,238 headwords, so `pos`
        reads — on every row below; the card's meta line shows the phonetic
        only. The part of speech reaches the card from the inline tag on each
        sense line and sits in front of it (`n. 速率, 速度`). Sensitive to the
        rule: the tag moves, it does not disappear.

        """
        for (title, samples) in groups {
            md += "\n## \(title)\n\n"
            for s in samples {
                md += "### \(s.headword)\n\n"
                md += "- phonetic: \(s.phonetic.isEmpty ? "—" : s.phonetic)\n"
                md += "- pos: \(s.partOfSpeech.isEmpty ? "—" : s.partOfSpeech)\n"
                if let sub = s.subtitle { md += "- subtitle: \(sub)\n" }
                md += "- card shows:\n\n```\n\(s.cardGloss)\n```\n\n"
            }
        }
        try md.write(to: outDir.appendingPathComponent("gloss-samples.md"), atomically: true, encoding: .utf8)
    }

    static func writeHTML(groups: [(String, [SampleRecord])], outDir: URL) throws {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var body = ""
        for (title, samples) in groups {
            body += "<h2>\(esc(title))</h2>\n"
            for s in samples {
                body += "<article class=\"card\">\n"
                body += "<h3 lang=\"en\">\(esc(s.headword))</h3>\n"
                if let sub = s.subtitle { body += "<p class=\"sub\" lang=\"en\">\(esc(sub))</p>\n" }
                let meta = [s.phonetic, s.partOfSpeech].filter { !$0.isEmpty }.joined(separator: " · ")
                if !meta.isEmpty { body += "<p class=\"meta\" lang=\"en\">\(esc(meta))</p>\n" }
                body += "<div class=\"gloss\">"
                body += s.cardGloss.split(separator: "\n").map { "<p>\(esc(String($0)))</p>" }.joined()
                body += "</div>\n</article>\n"
            }
        }
        let html = """
        <!DOCTYPE html>
        <html lang="zh-Hant-HK">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Gloss sample sheet — 20 headwords</title>
        <style>
        :root { color-scheme: light; }
        body { font-family: -apple-system, "Songti TC", "PMingLiU", serif; max-width: 40rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.6; }
        h1 { font-size: 1.25rem; }
        h2 { font-size: 1rem; margin-top: 2rem; border-top: 1px solid #ccc; padding-top: 1rem; }
        .card { border: 1px solid #ddd; border-radius: 12px; padding: 1rem 1.25rem; margin: 1rem 0; }
        .card h3 { font-size: 1.2rem; margin: 0; font-family: -apple-system, sans-serif; }
        .sub { color: #666; font-size: 0.8rem; margin: 0.1rem 0 0; font-family: -apple-system, sans-serif; }
        .meta { color: #666; font-size: 0.8rem; margin: 0.25rem 0 0; font-family: -apple-system, sans-serif; }
        .gloss { font-size: 0.95rem; margin-top: 0.5rem; }
        .gloss p { margin: 0.25rem 0; }
        .note { color: #666; font-size: 0.85rem; }
        </style>
        </head>
        <body>
        <h1>Gloss sample sheet — 20 headwords</h1>
        <p class="note">Rendered by the lookup path (<code>PackIndexStore.displayEntry</code>). The card shows at most \(GlossRenderer.maxLines) lines. Judge whether each gloss reads right in Traditional Chinese.</p>
        \(body)
        </body>
        </html>

        """
        try html.write(to: outDir.appendingPathComponent("gloss-samples.html"), atomically: true, encoding: .utf8)
    }
}
