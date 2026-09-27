import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import RomajiSegmenter
import Testing

@testable import Core

#if os(macOS)
@Suite("日英混在入力")
struct StatelessMixedInputTests {
    /// 実機と同じローマ字テーブル
    static let japaneseStyle: InputStyle = .mapped(id: .defaultRomanToKana)

    /// 1 文字ずつ打った結果の ComposingText を組み立てる (SegmentsManager.tryMixedInsert と同じ手順)。
    static func type(_ text: String) throws -> ComposingText {
        var mixed = StatelessMixedInput()
        try #require(mixed.isAvailable, "重みを読み込めていない (Bundle.module が解決できない)")
        var composing = ComposingText()
        for character in text {
            // #require の中では mutating メソッドを呼べないので、先に受ける
            let planned = mixed.plan(appending: String(character), partial: true, japaneseStyle: Self.japaneseStyle)
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

    @Test("「ん」を nn で打っても先頭の英単語に吸われない", arguments: [
        // 区間判定のモデルは innsuto-ru を [in] nsuto-ru と判定する
        ("innsuto-ru", "いんすとーる"),
        ("innsuto-ruwosuru", "いんすとーるをする")
    ])
    func doubleNStaysJapanese(_ input: String, _ expected: String) throws {
        #expect(try Self.type(input).convertTarget == expected)
    }

    @Test("辞書にない英単語で区切った判定を、実在の単語になる区切りに選び直す", arguments: [
        // 区間判定のモデルは [Maci] ppai、[Pytho] noboeru、[Vi] miine と判定することがある
        ("Macippaikatta", "Macいっぱいかった"),
        ("Pythonoboeru", "Pythonおぼえる"),
        ("Vimiine", "Vimいいね"),
        ("Chromeakete", "Chromeあけて")
    ])
    func unknownEnglishResegmented(_ input: String, _ expected: String) throws {
        #expect(try Self.type(input).convertTarget == expected)
    }

    @Test("辞書にない正しい語や、正しい区切りは崩さない", arguments: [
        // 辞書にない語を、辞書にある短い語まで削らない (runt、free)
        ("runtimenofurumai", "runtimeのふるまい"),
        ("freeenihanai", "freeeにはない"),
        // 複数形、略語 + 単語
        ("Interpretersha", "Interpretersは"),
        ("MGAAppoyobiMrs", "MGAAppおよびMrs"),
        // 英単語のすぐあとに母音で始まる日本語
        ("GitHubikounokeikaku", "GitHubいこうのけいかく"),
        ("PRokurimasu", "PRおくります"),
        ("AWSunnyou", "AWSうんよう"),
        ("Slackiinedesune", "Slackいいねですね")
    ])
    func correctSegmentationsKept(_ input: String, _ expected: String) throws {
        #expect(try Self.type(input).convertTarget == expected)
    }

    @Test("大文字の英単語に、隣のローマ字を含めない", arguments: [
        // 区間判定のモデルは [OKna] no [deCommit] と判定する
        ("dousakakuninnhaOKnanodeCommitsite", "どうさかくにんはOKなのでCommitして"),
        ("OKnanode", "OKなので"),
        // 英単語に挟まれた助詞: モデルは [GitHubdePR]、[ChatGPTyaCodex] と判定することがある
        ("GitHubdePRwodasu", "GitHubでPRをだす"),
        ("ChatGPTyaCodexnimo", "ChatGPTやCodexにも"),
        // 略語のあとの1文字: [AWSb] enkyou
        ("AWSbenkyoumaeha", "AWSべんきょうまえは")
    ])
    func mixedCaseParticles(_ input: String, _ expected: String) throws {
        #expect(try Self.type(input).convertTarget == expected)
    }

    @Test("大文字と小文字の境目の補正は、英単語そのものを崩さない", arguments: [
        // かなに変換しきれない (s)、1文字だけ (i)、直後が大文字だけの語 (re)
        ("URLsdesu", "URLsです"),
        ("macOSnoappude-to", "macOSのあっぷでーと"),
        ("reCAPTCHAwotoku", "reCAPTCHAをとく"),
        ("GitHubdePRwodasu", "GitHubでPRをだす")
    ])
    func mixedCaseWordsStayEnglish(_ input: String, _ expected: String) throws {
        #expect(try Self.type(input).convertTarget == expected)
    }

    @Test("nn の補正は英単語のあとの な行や、大文字で打った名前を崩さない", arguments: [
        ("Openninaru", "Openになる"),
        ("Annsanhakitayo", "Annさんはきたよ")
    ])
    func doubleNCorrectionKeepsEnglish(_ input: String, _ expected: String) throws {
        #expect(try Self.type(input).convertTarget == expected)
    }

    @Test("nn を英語区間と日本語区間にまたがらせた判定だけを補正対象にする")
    func splitsDoubleN() {
        func split(_ english: String, _ japanese: String) -> Bool {
            StatelessMixedInput.splitsDoubleN(
                InputSpan(label: .english, text: english),
                InputSpan(label: .japanese, text: japanese)
            )
        }
        #expect(split("in", "nsuto"))
        #expect(split("inn", "suto"))
        // な行・にゃ行、打ちかけの n は英単語のあとに普通に来る
        #expect(!split("amazon", "no"))
        #expect(!split("java", "nyuumon"))
        #expect(!split("amazon", "n"))
        // 大文字を含む英語区間は意図して英語で打ったものとみなす
        #expect(!split("Glenn", "san"))
        #expect(!split("Pen", "ndaigaku"))
    }

    @Test("英単語が複数あっても崩れない", arguments: [
        ("AWStoGCPnochigaiwoshiraberu", "AWSとGCPのちがいをしらべる"),
        ("bugwofixshitekaradeploysuru", "bugをfixしてからdeployする")
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
        ("GitHubnobranchwokaetekudasai", ["GitHub", "branch"])
    ])
    func englishWordsSurvive(_ input: String, _ words: [String]) throws {
        let target = try Self.type(input).convertTarget
        for word in words {
            #expect(target.contains(word), "\(input) の変換対象 \(target) に \(word) が残っていない")
        }
    }

    /// 以前のモデル (v5) が英語を見逃していたケース。
    /// `issue` は `i` + `ssu` + `e` とローマ字として読めてしまい、`VSCode` は末尾の e が次の de と
    /// 結びついて `[VSCod] ede` に割れていた。技術用語を学習に入れたモデル (v6) で直った。
    @Test("ローマ字としても読める英単語を英語と判定する", arguments: [
        ("kyouhaGitHubnoissuewomiteta", "きょうはGitHubのissueをみてた"),
        ("VSCodedeTypeScriptwokaku", "VSCodeでTypeScriptをかく")
    ])
    func englishReadableAsRomaji(_ input: String, _ expected: String) throws {
        #expect(try Self.type(input).convertTarget == expected)
    }

    @Test("日本語だけなら素のローマ字入力と同じ")
    func japaneseOnly() throws {
        #expect(try Self.type("kyouhaiitenkidesu").convertTarget == "きょうはいいてんきです")
    }

    /// 部分確定 (prefixComplete) や再アクティブ化で composingText だけが短くなると、
    /// 生入力に前の入力の残りカスが残る。そのまま打つと文頭に英字が1文字残る。
    ///
    /// 例: 生入力に n が残った状態で notoori と打つと nnotoori を区間判定してしまい、
    /// [n] notoori となって「nの通り」になる。
    @Test("生入力がずれても文頭に英字が残らない")
    func resyncAfterDesync() throws {
        var mixed = StatelessMixedInput()
        try #require(mixed.isAvailable)

        // n を打ってから、確定で composingText だけが空になった状況を作る
        let planned = mixed.plan(appending: "n", partial: true, japaneseStyle: Self.japaneseStyle)
        _ = try #require(planned)
        var composing = ComposingText()
        composing.stopComposition()
        #expect(!mixed.isInSync(with: composing), "ずれた状態を作れていない")

        // ずれを検知して合わせ直す (SegmentsManager.tryMixedInsert と同じ手順)
        let resynced = mixed.resync(with: composing, partial: true)
        #expect(resynced)
        #expect(mixed.isInSync(with: composing))

        for character in "notoori" {
            let step = mixed.plan(appending: String(character), partial: true, japaneseStyle: Self.japaneseStyle)
            let plan = try #require(step)
            switch plan {
            case .rebuild(let rebuilt):
                composing = rebuilt
            case .append(let pieces):
                for piece in pieces {
                    composing.insertAtCursorPosition(piece.text, inputStyle: piece.style)
                }
            }
        }
        // ずれが残っていると "nのとおり" になる
        #expect(composing.convertTarget == "のとおり")
    }

    @Test("ずれたまま打つと文頭に英字が残ることの確認 (修正前の症状)")
    func desyncSymptom() throws {
        // resync を挟まないと再現する。resync が要る根拠として固定しておく
        var mixed = StatelessMixedInput()
        try #require(mixed.isAvailable)
        let first = mixed.plan(appending: "n", partial: true, japaneseStyle: Self.japaneseStyle)
        _ = try #require(first)
        var composing = ComposingText()   // 確定で空になった composingText
        for character in "notoori" {
            let step = mixed.plan(appending: String(character), partial: true, japaneseStyle: Self.japaneseStyle)
            let plan = try #require(step)
            switch plan {
            case .rebuild(let rebuilt):
                composing = rebuilt
            case .append(let pieces):
                for piece in pieces {
                    composing.insertAtCursorPosition(piece.text, inputStyle: piece.style)
                }
            }
        }
        #expect(composing.convertTarget == "nのとおり", "この症状が出なくなったらテストの前提を見直す")
    }

    @Test("英語や記号の直前の n は ん になる", arguments: [
        ("takusanCLIkara", "たくさんCLIから"),
        ("takusannCLIkara", "たくさんCLIから"),
        ("kanAPI", "かんAPI"),
        ("sanninAIwo", "さんいんAIを"),
        ("hon.", "ほん。"),
        // n のあとに母音が続く日本語は、な行のまま
        ("AmazonnoPR", "AmazonのPR"),
        ("GlennsanhaPR", "GlennさんはPR")
    ])
    func syllabicNBeforeEnglish(input: String, expected: String) throws {
        let composing = try Self.type(input)
        #expect(composing.convertTarget == expected)
        // ん にした n も、打った文字として復元できる (次の打鍵で組み直すときに要る)
        #expect(StatelessMixedInput.rawInput(of: composing) == input)
    }

    @Test("英語を消して末尾に戻った n は、ん から n に戻る")
    func syllabicNRevertsOnDelete() throws {
        var mixed = StatelessMixedInput()
        try #require(mixed.isAvailable)
        for character in "takusanC" {
            _ = mixed.plan(appending: String(character), partial: true, japaneseStyle: Self.japaneseStyle)
        }
        guard case .rebuild(let rebuilt) = mixed.deleteBackward(partial: true) else {
            Issue.record("ん を n に戻すには組み直しが要る")
            return
        }
        #expect(rebuilt.convertTarget == "たくさn")
    }

    @Test("打ちかけの子音が残る")
    func partialConsonant() throws {
        #expect(try Self.type("kyouhaiitenkides").convertTarget == "きょうはいいてんきでs")
    }
}
#endif
