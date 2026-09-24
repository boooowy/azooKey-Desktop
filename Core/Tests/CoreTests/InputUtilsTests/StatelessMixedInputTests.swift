import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@testable import Core

#if os(macOS)
@Suite("日英混在入力")
struct StatelessMixedInputTests {
    /// 1 文字ずつ打った結果の ComposingText を組み立てる (SegmentsManager.tryMixedInsert と同じ手順)。
    static func type(_ text: String) throws -> ComposingText {
        var mixed = StatelessMixedInput()
        try #require(mixed.isAvailable, "重みを読み込めていない (Bundle.module が解決できない)")
        var composing = ComposingText()
        for character in text {
            // #require の中では mutating メソッドを呼べないので、先に受ける
            let planned = mixed.plan(appending: String(character), partial: true)
            let plan = try #require(planned, "\(character) を取り込めなかった")
            switch plan {
            case .rebuild(let rebuilt):
                composing = rebuilt
            case .append(let pieces):
                for piece in pieces {
                    composing.insertAtCursorPosition(piece.text, inputStyle: piece.style)
                }
            }
        }
        return composing
    }

    @Test("英語区間がローマ字変換されずそのまま残る")
    func englishStaysLiteral() throws {
        // 英語区間の 2 文字目以降が roman2kana に落ちると Slack が Sぁck になる
        #expect(try Self.type("kononaiyoudeSlacknisousinsiteoite").convertTarget
                == "このないようでSlackにそうしんしておいて")
    }

    @Test("記号は日本語区間の直後だけ 。、 になる")
    func punctuation() throws {
        #expect(try Self.type("kononaiyoudeSlacknisousinsiteoite.").convertTarget
                == "このないようでSlackにそうしんしておいて。")
    }

    @Test("英単語が複数あっても崩れない", arguments: [
        ("AWStoGCPnochigaiwoshiraberu", "AWSとGCPのちがいをしらべる"),
        ("bugwofixshitekaradeploysuru", "bugをfixしてからdeployする"),
    ])
    func multipleEnglishWords(_ input: String, _ expected: String) throws {
        #expect(try Self.type(input).convertTarget == expected)
    }

    /// かな部分の綴りに依存せず「英語がそのまま残ること」だけを確かめる。
    /// 期待値を手で書くと書き間違いで落ちるので、こちらの形も持っておく。
    @Test("英語と判定された語はそのまま残る", arguments: [
        ("kononaiyoudeSlacknisousinsiteoite", ["Slack"]),
        ("SlackdeDMshimasu", ["Slack", "DM"]),
        ("PRnoreviewwoonegaishimasu", ["PR", "review"]),
        ("GitHubnobranchwokaetekudasai", ["GitHub", "branch"]),
    ])
    func englishWordsSurvive(_ input: String, _ words: [String]) throws {
        let target = try Self.type(input).convertTarget
        for word in words {
            #expect(target.contains(word), "\(input) の変換対象 \(target) に \(word) が残っていない")
        }
    }

    /// モデルが英語を見逃す既知のケース。移植のバグではなく、Python 側も同じ判定をする
    /// (regression_test.py で元から落ちている 8 件のうちの 1 つ)。
    ///
    /// `issue` は `i` + `ssu` + `e` とローマ字として読めてしまうため、日本語区間にされる。
    /// 改善するならモデルの再学習 (ステップ4) の仕事。
    @Test("既知の限界: ローマ字として読める英単語は見逃す", arguments: [
        // issue = i + ssu + e とローマ字として読めるので日本語区間にされる
        ("kyouhaGitHubnoissuewomiteta", "きょうはGitHubのいっすえをみてた"),
        // VSCode の末尾 e が次の de と結びついて [VSCod] + ede に割れる
        ("VSCodedeTypeScriptwokaku", "VSCodえでTypeScriptをかく"),
    ])
    func knownLimitation(_ input: String, _ expected: String) throws {
        #expect(try Self.type(input).convertTarget == expected)
    }

    @Test("日本語だけなら素のローマ字入力と同じ")
    func japaneseOnly() throws {
        #expect(try Self.type("kyouhaiitenkidesu").convertTarget == "きょうはいいてんきです")
    }

    @Test("打ちかけの子音が残る")
    func partialConsonant() throws {
        #expect(try Self.type("kyouhaiitenkides").convertTarget == "きょうはいいてんきでs")
    }
}
#endif
