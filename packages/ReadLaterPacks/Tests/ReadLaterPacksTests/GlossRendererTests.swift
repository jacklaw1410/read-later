import Foundation
import Testing

@testable import ReadLaterPacks

/// The three gloss rules against stored strings, plus the pointer case end
/// to end with a synthetic index. Raw glosses below are pasted from the real
/// `dictionary.en-zh-HK.lexical` pack; the expectations are the exact card
/// strings. No network in the default run.
@Suite("Gloss rendering")
struct GlossRendererTests {
    @Test("a pointer gloss names its base word")
    func pointerBase() {
        #expect(GlossRenderer.pointerBaseWord(in: "vi., vt. ovate的變形") == "ovate")
        #expect(GlossRenderer.pointerBaseWord(in: "n. A-list的變形") == "A-list")
        #expect(GlossRenderer.pointerBaseWord(in: "(Afrikaaner 的複數) n.,adj. = Afrikaner") == "Afrikaaner")
        #expect(GlossRenderer.pointerBaseWord(in: "a. 卵形的") == nil)
        #expect(GlossRenderer.pointerBaseWord(in: "pron. 我們") == nil)
    }

    @Test("pointer-only means a pointer and no meaning of its own")
    func pointerOnly() {
        #expect(GlossRenderer.isPointerOnly("vi., vt. ovate的變形"))
        #expect(GlossRenderer.isPointerOnly("n. A-list的變形"))
        // A pointer note plus a real sense is not pointer-only: the card
        // shows the sense instead of resolving.
        #expect(!GlossRenderer.isPointerOnly("(a-frame 的複數) [機] A型架"))
        // Own senses beside the grammar note: not a pointer.
        #expect(!GlossRenderer.isPointerOnly("a. 牛奶的, 像牛奶的, 摻奶的( milky的最高級 )"))
        #expect(!GlossRenderer.isPointerOnly("n. 咖啡館, 酒店"))
    }

    @Test("untagged lines come first, then at most one tagged line")
    func untaggedFirst() {
        #expect(GlossRenderer.render(gloss: "pron. 我們\\n[經] 美國") == "pron. 我們\n[經] 美國")
        #expect(
            GlossRenderer.render(gloss: "n. 通路, 入口\\nvt. 訪問\\n[計] 訪問, 存取\\n[醫] 通道")
                == "n. 通路, 入口\nvt. 訪問\n[計] 訪問, 存取"
        )
    }

    @Test("a grammar parenthetical naming the base form is dropped")
    func parentheticalStrip() {
        #expect(
            GlossRenderer.render(gloss: "a. 牛奶的, 像牛奶的, 摻奶的( milky的最高級 )")
                == "adj. 牛奶的, 像牛奶的, 摻奶的"
        )
        #expect(
            GlossRenderer.render(gloss: "v. 逗留( linger的第三人稱單數 ); 緩慢消失")
                == "v. 逗留; 緩慢消失"
        )
        // The pack writes `的過去時` as well as `的過去式`; both name a base
        // form and both go.
        #expect(
            GlossRenderer.render(gloss: "(aah 的過去時) abbr.[軍] Armored Artillery Howitzer, 裝甲榴彈炮")
                == "abbr. [軍] Armored Artillery Howitzer, 裝甲榴彈炮"
        )
        // A parenthetical without a base form is sense text and stays. It was
        // read as a label only because no label was in front of it; the
        // pointer label now takes that slot.
        #expect(
            GlossRenderer.render(gloss: "(very best) 最好的, 最優秀的, 最酷的")
                == "(very best) 最好的, 最優秀的, 最酷的"
        )
    }

    @Test("the inline part-of-speech tag moves in front of its sense")
    func posPrefix() {
        #expect(
            GlossRenderer.render(gloss: "n. 偶然發現珍寶的運氣/才能, 易遇奇緣的運氣")
                == "n. 偶然發現珍寶的運氣/才能, 易遇奇緣的運氣"
        )
        // A run of tags stays one run: the reader sees the kinds, not a
        // truncated list.
        #expect(GlossRenderer.render(gloss: "vi., vt. 穿著, 打扮") == "vi., vt. 穿著, 打扮")
        #expect(GlossRenderer.render(gloss: "abbr. 測試") == "abbr. 測試")
        // Multi-line: each line keeps its own tag, so the two senses of
        // `speed` stay apart.
        #expect(
            GlossRenderer.render(gloss: "n. 速率, 速度\\nvi. 加速\\nvt. 促進")
                == "n. 速率, 速度\nvi. 加速\nvt. 促進"
        )
        #expect(GlossRenderer.posPrefix("n. 速率") == "n.")
        #expect(GlossRenderer.posPrefix("vi., vt. 穿著") == "vi., vt.")
        #expect(GlossRenderer.posPrefix("我們") == nil)
        // Sense text that happens to start with a letter is not a tag.
        #expect(GlossRenderer.posPrefix("A型架") == nil)
        // `a.` is the pack's adjective tag on 37,044 rows and sits beside the
        // article tag `art.`, so the card says `adj.`.
        #expect(GlossRenderer.posPrefix("a. 慢的") == "adj.")
        #expect(GlossRenderer.posPrefix("adj. 慢的") == "adj.")
        #expect(GlossRenderer.posPrefix("adj. 慢的") == GlossRenderer.posPrefix("a. 慢的"))
        // A tag that names nothing a reader can use goes; its sense stays.
        #expect(GlossRenderer.render(gloss: "un. 秋葵") == "秋葵")
        #expect(GlossRenderer.render(gloss: "vbl. 歸咎；責備") == "歸咎；責備")
    }

    @Test("literal backslash-n escapes split like real newlines")
    func literalNewlines() {
        #expect(GlossRenderer.render(gloss: "pron. 我們\\n[經] 美國") == "pron. 我們\n[經] 美國")
    }

    @Test("the card shows at most four lines, in source order")
    func lineCap() {
        #expect(GlossRenderer.maxLines == 4)
        let six = (1 ... 6).map { "n. 義\($0)" }.joined(separator: "\\n")
        #expect(
            GlossRenderer.renderLines(gloss: six)
                == ["n. 義1", "n. 義2", "n. 義3", "n. 義4"]
        )
        #expect(GlossRenderer.renderLines(gloss: six).count == GlossRenderer.maxLines)
    }

    @Test("an ending that settles the kind of word names it")
    func suffixLabel() {
        #expect(GlossRenderer.suffixLabel("abaser") == "n.")
        #expect(GlossRenderer.suffixLabel("a-listers") == "n.")
        #expect(GlossRenderer.suffixLabel("abdicative") == "adj.")
        #expect(GlossRenderer.suffixLabel("abandonedly") == "adv.")
        // A participle is a form of its base word, so its ending decides
        // nothing: `ovated` is an adjective because `ovate` is one.
        #expect(GlossRenderer.suffixLabel("ovated") == nil)
        #expect(GlossRenderer.suffixLabel("abandoning") == nil)
        // An ending too short to carry meaning is ignored.
        #expect(GlossRenderer.suffixLabel("er") == nil)
    }

    @Test("the pointer label names the tapped word, unless the ending disagrees")
    func pointerLabelChoice() {
        // The ending agrees with the pointer: the pointer wins, and the base
        // word's verb tag goes.
        #expect(
            GlossRenderer.pointerLabel(pointer: "n.", base: "vt.", tapped: "abaser") == "n."
        )
        #expect(
            GlossRenderer.pointerLabel(pointer: "adj.", base: "vt.", tapped: "abdicative") == "adj."
        )
        // The pointer copies the base's tag on a participle, and the word is an
        // adjective: the base line's own label stands.
        #expect(
            GlossRenderer.pointerLabel(pointer: "vi., vt.", base: "adj.", tapped: "ovated") == "adj."
        )
        // No label on the base line: the pointer is the only label there is.
        #expect(
            GlossRenderer.pointerLabel(pointer: "n.", base: nil, tapped: "abaculi") == "n."
        )
        // No pointer label: nothing to add.
        #expect(GlossRenderer.pointerLabel(pointer: nil, base: "n.", tapped: "men") == "n.")
    }

    @Test("one label governs a pointer card, and only the first line wears it")
    func pointerCardLabel() {
        #expect(
            GlossRenderer.render(gloss: "vt. 正式放棄\nvi. 退位, 退出, 辭職", label: "adj.")
                == "adj. 正式放棄\n退位, 退出, 辭職"
        )
        // The first line already names the label: it is not repeated.
        #expect(
            GlossRenderer.render(gloss: "adj. 卵形的\n[醫] 卵圓形的(葉)", label: "adj.")
                == "adj. 卵形的\n[醫] 卵圓形的(葉)"
        )
        // An untagged base line takes the label.
        #expect(
            GlossRenderer.render(gloss: "鑲嵌用的小石[玻璃]磚, 嵌塊", label: "n.")
                == "n. 鑲嵌用的小石[玻璃]磚, 嵌塊"
        )
    }

    @Test("pointer case end to end: tapped spelling stays, base gloss shows")
    func pointerEndToEnd() async throws {
        let tsv = [
            "ovate\t'әuveit\t\ta. 卵形的\\n[醫] 卵圓形的(葉)",
            "ovated\t\t\tvi., vt. ovate的變形",
            "abaser\t\t\tn. abase的變形",
            "abase\t\t\tvt. 降低...的地位, 貶抑",
            "abdicative\t\t\ta. abdicate的變形",
            "abdicate\t\t\tvt. 正式放棄\\nvi. 退位, 退出, 辭職",
            "abaculi\t\t\tn. abaculus的變形",
            "abaculus\t\t\t鑲嵌用的小石[玻璃]磚, 嵌塊",
            "cafe\tka'fei\t\tn. 咖啡館, 酒店",
            "us\tʌs\t\tpron. 我們\\n[經] 美國",
        ].joined(separator: "\n") + "\n"
        let build = try packTestDirectory()
        let source = try syntheticArchive(tsv, in: build, id: "dictionary.en-zh-HK.lexical")
        let bytes = try Data(contentsOf: source)
        let manifest = try packTestManifest(data: bytes)

        let directory = try packTestDirectory()
        let state = await PackService.install(
            manifest: manifest,
            archiveURL: URL(string: "https://example.com/pack.gz")!,
            directory: directory,
            appVersion: "0.1.0",
            download: passthroughDownload(bytes)
        )
        #expect(state == .installed(version: manifest.version))
        let store = PackIndexStore(
            sqliteURL: directory.appendingPathComponent("dictionary.en-zh-HK.lexical.sqlite")
        )

        let pointed = try #require(store.displayEntry(for: "ovated"))
        #expect(pointed.tapped == "ovated")
        #expect(pointed.subtitle == "ovate")
        #expect(pointed.gloss == "adj. 卵形的\n[醫] 卵圓形的(葉)")

        // A noun over a verb sense: the card must not promise a verb.
        let noun = try #require(store.displayEntry(for: "abaser"))
        #expect(noun.gloss == "n. 降低...的地位, 貶抑")

        // An adjective over two verb lines: one label, on the first line.
        let adjective = try #require(store.displayEntry(for: "abdicative"))
        #expect(adjective.gloss == "adj. 正式放棄\n退位, 退出, 辭職")

        // An untagged base line still gets the kind of word.
        let untagged = try #require(store.displayEntry(for: "abaculi"))
        #expect(untagged.gloss == "n. 鑲嵌用的小石[玻璃]磚, 嵌塊")

        let plain = try #require(store.displayEntry(for: "us"))
        #expect(plain.tapped == "us")
        #expect(plain.subtitle == nil)
        #expect(plain.gloss == "pron. 我們\n[經] 美國")

        let accented = try #require(store.displayEntry(for: "café"))
        #expect(accented.tapped == "café")
        #expect(accented.subtitle == "cafe")
        #expect(accented.gloss == "n. 咖啡館, 酒店")

        #expect(store.displayEntry(for: "zzzqqq") == nil)
    }
}
