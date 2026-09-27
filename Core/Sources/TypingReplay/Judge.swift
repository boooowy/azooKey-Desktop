import Foundation

/// 評価用の組 (jev-test の `data/cases*.json` と同じ形)
struct ReplayCase: Codable {
    /// 打鍵列 (大文字は Shift で打つ)
    var inputCased: String?
    /// 打鍵列 (小文字)。`input_cased` がなければこちらを使う
    var input: String?
    /// 正解に含まれる英単語 (小文字)
    var english: [String]
    /// 正解。正解は1つに決まらないので、一致は参考値
    var expected: String?
    var source: String?

    enum CodingKeys: String, CodingKey {
        case inputCased = "input_cased"
        case input, english, expected, source
    }

    var keystrokes: String {
        inputCased ?? input ?? ""
    }
}

/// 確定した文字列の判定。
///
/// 正解の表記がどうであれ誤りと言えるもの (英単語が崩れた・英字が残った) を主な指標にする。
struct Verdict: Codable, Equatable {
    /// 正解に含まれるのに、出力にそのまま含まれない英単語 (例: iPhonえ)
    var brokenEnglishWords: [String]
    /// 正解の英単語以外の英字が残った (例: OKnaの、wiんどう)
    var hasLeftoverLetters: Bool
    /// 正規化した出力が正解と同じ (参考値。正解がなければ nil)
    var matchesExpected: Bool?

    /// 明らかな誤り
    var isObviousError: Bool {
        !brokenEnglishWords.isEmpty || hasLeftoverLetters
    }

    static func judge(output: String, replayCase: ReplayCase) -> Verdict {
        let lowered = output.lowercased()
        let broken = replayCase.english.filter { !lowered.contains($0.lowercased()) }

        // 正解の英単語を取り除いたあとに英字が残っていれば、崩れて残った英字
        var rest = lowered
        for word in replayCase.english.sorted(by: { $0.count > $1.count }) {
            rest = rest.replacingOccurrences(of: word.lowercased(), with: "")
        }
        let leftover = rest.contains { $0.isASCII && $0.isLetter }

        return Verdict(
            brokenEnglishWords: broken,
            hasLeftoverLetters: leftover,
            matchesExpected: replayCase.expected.map { normalize(output) == normalize($0) }
        )
    }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
    }
}

/// 1件の結果
struct ReplayResult: Codable {
    var keystrokes: String
    var expected: String?
    var english: [String]
    /// A. 打って Enter で確定した文字列 (ライブ変換の表示)
    var enterOutput: String
    var enterVerdict: Verdict
    /// B. 打って Space を押したときの候補 (上位10件)
    var spaceCandidates: [String]
    /// B. Space のあと Enter で確定しきった文字列
    var spaceOutput: String
    var spaceVerdict: Verdict
    /// 正解が Space の候補に入っているか (Enter で崩れても Space で救えるか)
    var rescuableBySpace: Bool?
    /// 打鍵ごとの応答時間 (ms)
    var keyMilliseconds: [Double]
    var spaceMilliseconds: Double?
    var enterMilliseconds: Double?
}
