import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@testable import Core

#if os(macOS)
/// 打っている途中で `composingText` だけが外から書き換えられたときの追従。
///
/// ここが崩れると「文の途中や打ち始めに英字が1文字残る」形で表に出る。
@Suite("日英混在入力 - 生入力の追従")
struct MixedInputResyncTests {
    /// 実機と同じローマ字テーブル。ライブラリ既定の .roman2kana とは違い `-` を `ー` にする
    static let japaneseStyle: InputStyle = .mapped(id: .defaultRomanToKana)

    /// SegmentsManager.tryMixedInsert と同じ手順で1文字ずつ打つ。
    struct Harness {
        static let japaneseStyle = MixedInputResyncTests.japaneseStyle
        var mixed = StatelessMixedInput()
        var composing = ComposingText()
        /// 混在入力に取り込めず通常経路に落ちた打鍵の数
        private(set) var fellThrough = 0

        mutating func type(_ character: Character) {
            if !mixed.isInSync(with: composing) {
                guard mixed.resync(with: composing, partial: true) else {
                    mixed.reset()
                    fellThrough += 1
                    composing.insertAtCursorPosition(String(character), inputStyle: Self.japaneseStyle)
                    return
                }
            }
            guard let plan = mixed.plan(appending: String(character), partial: true, japaneseStyle: Self.japaneseStyle) else {
                mixed.reset()
                fellThrough += 1
                composing.insertAtCursorPosition(String(character), inputStyle: Self.japaneseStyle)
                return
            }
            switch plan {
            case .rebuild(let rebuilt):
                composing = rebuilt
            case .append(let pieces):
                for piece in pieces {
                    composing.insertAtCursorPosition(piece.text, inputStyle: piece.style)
                }
            }
        }

        mutating func type(_ text: String) {
            for character in text { type(character) }
        }

        /// スペース (変換) で azooKey が入れる文節区切り
        mutating func insertSeparator() {
            composing.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: Self.japaneseStyle)])
        }
    }

    // MARK: 生入力の復元

    @Test("句点を含んでいても生入力を復元できる")
    func restoreThroughPunctuation() {
        // 。は打った . を置き換えたもの。打った文字に戻せないと生入力を見失う
        var harness = Harness()
        harness.type("sorede.")
        #expect(harness.composing.convertTarget == "それで。")
        #expect(StatelessMixedInput.rawInput(of: harness.composing) == "sorede.")
        #expect(harness.mixed.isInSync(with: harness.composing))
    }

    @Test("読点も復元できる")
    func restoreThroughComma() {
        var harness = Harness()
        harness.type("sorede,")
        #expect(harness.composing.convertTarget == "それで、")
        #expect(StatelessMixedInput.rawInput(of: harness.composing) == "sorede,")
    }

    @Test("文節区切りが入っていたら復元しない")
    func separatorIsNotRestorable() {
        var composing = ComposingText()
        composing.insertAtCursorPosition("kyou", inputStyle: Self.japaneseStyle)
        composing.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: Self.japaneseStyle)])
        // 生入力に対応する文字がないので、中途半端に復元せず諦める
        #expect(StatelessMixedInput.rawInput(of: composing) == nil)
    }

    @Test("長さが同じでも中身が違えばずれと判定する")
    func syncChecksContent() {
        var harness = Harness()
        harness.type("slack")
        var other = ComposingText()
        other.insertAtCursorPosition("stack", inputStyle: Self.japaneseStyle)
        #expect(!harness.mixed.isInSync(with: other))
    }

    // MARK: 合わせ直したあとは必ず組み直す

    /// 合わせ直せるのは「打った文字列」だけで、**既に入っている要素の
    /// inputStyle が区間判定と合っている保証はない**。追記で済ませると、
    /// 違う style で入った文字がそのまま残り、英字が1文字残る。
    @Test("合わせ直した直後の打鍵は追記でなく組み直しになる")
    func resyncForcesRebuild() throws {
        var mixed = StatelessMixedInput()
        try #require(mixed.isAvailable)
        // 通常経路で先に入ってしまった1文字 (style は区間判定と無関係)
        var composing = ComposingText()
        composing.insertAtCursorPosition("k", inputStyle: .direct)

        #expect(!mixed.isInSync(with: composing))
        // #expect / #require の中では mutating メソッドを呼べないので先に受ける
        let resynced = mixed.resync(with: composing, partial: true)
        #expect(resynced)

        let planned = mixed.plan(appending: "y", partial: true, japaneseStyle: Self.japaneseStyle)
        let plan = try #require(planned)
        #expect(plan.kindDescription == "rebuild", "追記で済ませると k の style を直せない")
    }

    @Test("通常経路で1文字入ってしまっても続きを打てば直る")
    func recoversFromForeignFirstCharacter() throws {
        var harness = Harness()
        // 通常経路で入った1文字 (混在入力は空のまま)
        harness.composing.insertAtCursorPosition("d", inputStyle: .direct)
        harness.type("aibukitaidoori")
        #expect(harness.composing.convertTarget == "だいぶきたいどおり")
        #expect(harness.fellThrough == 0, "生入力は復元できるはず")
    }

    // MARK: 記号

    /// azooKey の既定ローマ字テーブルは記号を扱わないので、こちらで置き換えている。
    /// **文脈は見ない**: 行頭の `・` で箇条書きを書いたり `。` を単体で打ったりしたいため。
    @Test("記号はどこでも全角になる", arguments: [
        // 箇条書き: 直前に何も無くても ・ になる
        ("/kajougaki", "・かじょうがき"),
        // 単体の 。 、
        (".", "。"),
        (",", "、"),
        ("kore/are", "これ・あれ"),
        ("kore/are/sore", "これ・あれ・それ"),
        ("korehaiitenkidesu.", "これはいいてんきです。"),
        ("Slack/Teams", "Slack・Teams"),
        // 代償: 半角で打てなくなる。半角が要るときは変換候補から選ぶ
        ("example.com", "example。com"),
    ])
    func symbolsBecomeFullWidth(_ input: String, _ expected: String) {
        var harness = Harness()
        harness.type(input)
        #expect(harness.composing.convertTarget == expected)
        #expect(harness.fellThrough == 0)
    }

    @Test("チャンクの中の記号はすべて置き換わる")
    func allSymbolsInChunk() {
        var harness = Harness()
        harness.type("kore//are")
        #expect(harness.composing.convertTarget == "これ・・あれ")
        var other = Harness()
        other.type("kore...")
        #expect(other.composing.convertTarget == "これ。。。")
    }

    @Test("・ から打った文字を復元できる")
    func restoreThroughNakaguro() {
        var harness = Harness()
        harness.type("kore/are")
        #expect(StatelessMixedInput.rawInput(of: harness.composing) == "kore/are")
        #expect(harness.mixed.isInSync(with: harness.composing))
    }

    // MARK: 削除

    @Test("ラベルが変わらない削除は組み直さない")
    func deleteKeepsComposingTextWhenLabelsUnchanged() throws {
        var mixed = StatelessMixedInput()
        try #require(mixed.isAvailable)
        for character in "kyouhaiitenki" {
            _ = mixed.plan(appending: String(character), partial: true, japaneseStyle: Self.japaneseStyle)
        }
        let plan = mixed.deleteBackward(count: 1, partial: true)
        guard case .deleteInPlace = plan else {
            Issue.record("組み直しが走った: 毎回組み直すと azooKey が変換をやり直して削除が重くなる")
            return
        }
    }

    @Test("削除でラベルが変わるときは組み直す")
    func deleteRebuildsWhenLabelsChange() throws {
        var mixed = StatelessMixedInput()
        try #require(mixed.isAvailable)
        // 打ちきると日本語、1文字削ると英語に割れる並び
        for character in "konomesse-" {
            _ = mixed.plan(appending: String(character), partial: true, japaneseStyle: Self.japaneseStyle)
        }
        let plan = mixed.deleteBackward(count: 1, partial: true)
        guard case .rebuild(let rebuilt) = plan else {
            Issue.record("kono [messe] に割れるので組み直しが要る")
            return
        }
        #expect(rebuilt.convertTarget == "このmesse")
    }

    // MARK: 実際に出た症状

    @Test("句点のあとスペース変換を挟んでも英字が残らない")
    func punctuationThenSeparator() {
        var harness = Harness()
        harness.type("sorede.")
        harness.insertSeparator()
        harness.type("daibukitaidoorininarimasita")
        // 区切りは復元できないので通常経路に落ちるが、英字が残ってはいけない
        #expect(harness.composing.convertTarget == "それで。だいぶきたいどおりになりました")
    }

    // MARK: 長音記号

    @Test("打鍵の意図が非 ASCII でも取りこぼさない")
    func nonASCIIIntentionFallsBackToKey() {
        // 日本語入力では `-` キーの意図は `ー`。そのまま渡すと区間判定できず、
        // 混在入力がそこで止まって直前の英字判定が凍る
        let pieces: [InputPiece] = [.key(intention: "ー", input: "-", modifiers: [])]
        #expect(SegmentsManager.mixedInputString(pieces) == "-")
        // 大文字は shift の意図を尊重する (英語判定の唯一の手がかり)
        #expect(SegmentsManager.mixedInputString([.key(intention: "S", input: "s", modifiers: [.shift])]) == "S")
    }

    @Test("日本語区間の - だけを ー にする")
    func longVowelOnlyInJapanese() {
        #expect(StatelessMixedInput.longVowelMarks("messe-ji") == "messeーji")
        #expect(StatelessMixedInput.longVowelMarks("slack") == "slack")
    }

    @Test("長音記号をまたいでも組み直される")
    func longVowelMark() {
        var harness = Harness()
        for character in "konomesse-jiwotutaetai" {
            harness.type(character)
        }
        #expect(harness.composing.convertTarget == "このめっせーじをつたえたい")
    }

    @Test("そのまま打ち切れば英字は残らない", arguments: [
        ("kyounotenkihaharedesu.", "きょうのてんきははれです。"),
        ("daibukitaidoorinokekkaninarimasita", "だいぶきたいどおりのけっかになりました"),
        ("joukinoyounikaishichokugonieijiganyuuryokusaremasu.",
         "じょうきのようにかいしちょくごにえいじがにゅうりょくされます。"),
    ])
    func straightThrough(_ input: String, _ expected: String) {
        var harness = Harness()
        harness.type(input)
        #expect(harness.composing.convertTarget == expected)
        // 普通に打っているだけでずれ検知に引っかかってはいけない
        #expect(harness.fellThrough == 0)
    }
}
#endif
