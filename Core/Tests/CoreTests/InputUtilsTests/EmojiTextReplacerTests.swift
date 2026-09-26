import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@testable import Core

#if os(macOS)
/// 絵文字辞書は起動中変わらないので1回だけ作る。打鍵ごとに作り直さない。
@Suite("絵文字辞書")
struct EmojiTextReplacerTests {
    @Test("使い回す辞書で絵文字を引ける")
    func search() {
        let results = SegmentsManager.emojiTextReplacer.getSearchResult(query: "ねこ", target: [.emoji])
        #expect(!results.isEmpty)
    }
}
#endif
