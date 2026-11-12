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
        #expect(GlossRenderer.render(gloss: "pron. 我們\\n[經] 美國") == "我們\n[經] 美國")
        #expect(
            GlossRenderer.render(gloss: "n. 通路, 入口\\nvt. 訪問\\n[計] 訪問, 存取\\n[醫] 通道")
                == "通路, 入口\n訪問\n[計] 訪問, 存取"
        )
    }

    @Test("a grammar parenthetical naming the base form is dropped")
    func parentheticalStrip() {
        #expect(
            GlossRenderer.render(gloss: "a. 牛奶的, 像牛奶的, 摻奶的( milky的最高級 )")
                == "牛奶的, 像牛奶的, 摻奶的"
        )
        #expect(
            GlossRenderer.render(gloss: "v. 逗留( linger的第三人稱單數 ); 緩慢消失")
                == "逗留; 緩慢消失"
        )
        // A parenthetical without a base form is sense text and stays.
        #expect(
            GlossRenderer.render(gloss: "(very best) 最好的, 最優秀的, 最酷的")
                == "(very best) 最好的, 最優秀的, 最酷的"
        )
    }

    @Test("inline part-of-speech tags never reach the card")
    func posStrip() {
        #expect(
            GlossRenderer.render(gloss: "n. 偶然發現珍寶的運氣/才能, 易遇奇緣的運氣")
                == "偶然發現珍寶的運氣/才能, 易遇奇緣的運氣"
        )
        #expect(GlossRenderer.render(gloss: "vi., vt. 穿著, 打扮") == "穿著, 打扮")
        #expect(GlossRenderer.render(gloss: "abbr. 測試") == "測試")
    }

    @Test("literal backslash-n escapes split like real newlines")
    func literalNewlines() {
        #expect(GlossRenderer.render(gloss: "pron. 我們\\n[經] 美國") == "我們\n[經] 美國")
    }

    @Test("the card shows at most four lines, in source order")
    func lineCap() {
        #expect(GlossRenderer.maxLines == 4)
        let six = (1 ... 6).map { "n. 義\($0)" }.joined(separator: "\\n")
        #expect(GlossRenderer.renderLines(gloss: six) == ["義1", "義2", "義3", "義4"])
        #expect(GlossRenderer.renderLines(gloss: six).count == GlossRenderer.maxLines)
    }

    @Test("pointer case end to end: tapped spelling stays, base gloss shows")
    func pointerEndToEnd() async throws {
        let tsv = [
            "ovate\t'әuveit\t\ta. 卵形的\\n[醫] 卵圓形的(葉)",
            "ovated\t\t\tvi., vt. ovate的變形",
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
        #expect(pointed.gloss == "卵形的\n[醫] 卵圓形的(葉)")

        let plain = try #require(store.displayEntry(for: "us"))
        #expect(plain.tapped == "us")
        #expect(plain.subtitle == nil)
        #expect(plain.gloss == "我們\n[經] 美國")

        let accented = try #require(store.displayEntry(for: "café"))
        #expect(accented.tapped == "café")
        #expect(accented.subtitle == "cafe")
        #expect(accented.gloss == "咖啡館, 酒店")

        #expect(store.displayEntry(for: "zzzqqq") == nil)
    }
}
