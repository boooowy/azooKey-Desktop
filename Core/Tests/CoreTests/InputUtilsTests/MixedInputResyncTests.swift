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
    /// SegmentsManager.tryMixedInsert と同じ手順で1文字ずつ打つ。
    struct Harness {
        var mixed = StatelessMixedInput()
        var composing = ComposingText()
        /// 混在入力に取り込めず通常経路に落ちた打鍵の数
        private(set) var fellThrough = 0

        mutating func type(_ character: Character) {
            if !mixed.isInSync(with: composing) {
                guard mixed.resync(with: composing, partial: true) else {
                    mixed.reset()
                    fellThrough += 1
                    composing.insertAtCursorPosition(String(character), inputStyle: .roman2kana)
                    return
                }
            }
            guard let plan = mixed.plan(appending: String(character), partial: true) else {
                mixed.reset()
                fellThrough += 1
                composing.insertAtCursorPosition(String(character), inputStyle: .roman2kana)
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
            composing.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: .roman2kana)])
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
        composing.insertAtCursorPosition("kyou", inputStyle: .roman2kana)
        composing.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: .roman2kana)])
        // 生入力に対応する文字がないので、中途半端に復元せず諦める
        #expect(StatelessMixedInput.rawInput(of: composing) == nil)
    }

    @Test("長さが同じでも中身が違えばずれと判定する")
    func syncChecksContent() {
        var harness = Harness()
        harness.type("slack")
        var other = ComposingText()
        other.insertAtCursorPosition("stack", inputStyle: .roman2kana)
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

        let planned = mixed.plan(appending: "y", partial: true)
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
