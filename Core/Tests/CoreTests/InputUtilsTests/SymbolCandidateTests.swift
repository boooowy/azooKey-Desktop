import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@testable import Core

#if os(macOS)
/// 記号は全角にしてしまうので、半角が要るときは変換候補から選べる必要がある。
/// azooKey 側に仕組みがある (DicdataStore の 記号に対する半角・全角変換 と
/// weakRelatingSymbolGroups) ことを実際に変換して確かめる。
@Suite("記号の候補")
struct SymbolCandidateProbe {
    @MainActor
    @Test("全角記号から半角や別の記号を選べる", arguments: [
        ("。", [".", "．", "、", "・"]),
        ("、", [",", "，", "。", "・"]),
        // `/` を `・` にしている代わりに、打ったキーで出せる記号を候補に足している
        ("・", ["／", "/", "？", "?", "･", "…"]),
    ])
    func candidatesForSymbols(_ symbol: String, _ expected: [String]) {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        do {
            var composing = ComposingText()
            composing.insertAtCursorPosition(symbol, inputStyle: .direct)
            let result = converter.requestCandidates(
                composing,
                options: ConvertRequestOptions(
                    N_best: 10,
                    requireJapanesePrediction: .disabled,
                    requireEnglishPrediction: .disabled,
                    keyboardLanguage: .ja_JP,
                    learningType: .nothing,
                    memoryDirectoryURL: tmp,
                    sharedContainerURL: tmp,
                    textReplacer: .withDefaultEmojiDictionary(),
                    specialCandidateProviders: SegmentsManager.specialCandidateProviders,
                    metadata: .init(appVersionString: "test")
                )
            )
            let texts = result.mainResults.map { $0.text }
            #expect(texts.first == symbol, "第1候補は打った記号そのもの")
            for candidate in expected {
                // 候補ウィンドウをスクロールせずに届く位置にあること
                #expect(texts.prefix(10).contains(candidate),
                        "\(symbol) の候補10件に \(candidate) が無い: \(texts.prefix(12))")
            }
        }
    }
}
#endif
