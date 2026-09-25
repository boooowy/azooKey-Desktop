import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// こちらで全角に置き換えた記号から、**同じキーで出したい他の記号**を候補に出す。
///
/// `/` を `・` にしている (StatelessMixedInput.japaneseSymbols) ので、
/// そのままでは `/` `／` `?` `？` を打つ手段が無くなる。azooKey の記号グループ
/// (`DicdataStore.weakRelatingSymbolGroups`) には `・` と `/` の関係が無いため、
/// ここで補う。
///
/// `。` `、` は azooKey 側が既に `.` `．` `,` `，` を出すので何もしない。
struct TypedSymbolCandidateProvider: SpecialCandidateProvider {
    /// 置き換えた記号 → 同じキーで出したい記号 (出したい順)
    static let alternatives: [String: [String]] = [
        "・": ["／", "/", "？", "?"]
    ]

    func provideCandidates(
        converter _: KanaKanjiConverter,
        inputData: ComposingText,
        options _: ConvertRequestOptions
    ) -> [Candidate] {
        let target = inputData.convertTarget
        guard let alternatives = Self.alternatives[target] else {
            return []
        }
        return alternatives.enumerated().map { index, text in
            // 打った記号そのもの (-14) のすぐ下に置く。
            // azooKey 側は半角化 (-19) と関連記号 (-34 以下) を出すので、その前に来る
            let value = PValue(-15 - index)
            return Candidate(
                text: text,
                value: value,
                composingCount: .inputCount(inputData.input.count),
                lastMid: MIDData.一般.mid,
                data: [
                    DicdataElement(word: text, ruby: target, cid: .zero, mid: MIDData.一般.mid, value: value)
                ]
            )
        }
    }
}
