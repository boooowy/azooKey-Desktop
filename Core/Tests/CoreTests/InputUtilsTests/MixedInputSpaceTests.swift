import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@testable import Core

#if os(macOS)
/// 英語と判定した区間の直後の Space は、変換ではなく半角スペースの入力になる。
/// その判定に使う `endsWithEnglish` と、スペースを挟んだ入力の組み立て。
@Suite("日英混在入力 - 英単語の区切りのスペース")
struct MixedInputSpaceTests {
    typealias Harness = MixedInputResyncTests.Harness

    @Test("大文字で打った英単語の直後は英語の区間で終わる")
    func endsWithEnglishAfterCapitalizedWord() {
        var harness = Harness()
        harness.type("Slack")
        #expect(harness.mixed.endsWithEnglish)
    }

    @Test("日本語の直後は英語の区間で終わらない (Space は変換のまま)")
    func doesNotEndWithEnglishAfterJapanese() {
        var harness = Harness()
        harness.type("sorede")
        #expect(!harness.mixed.endsWithEnglish)
    }

    @Test("英単語のあとのスペースの直後は英語の区間で終わらない (2回目の Space は変換)")
    func doesNotEndWithEnglishAfterSpace() {
        var harness = Harness()
        harness.type("Slack ")
        #expect(!harness.mixed.endsWithEnglish)
    }

    @Test("スペースは半角のまま入り、続きの日本語はかなになる")
    func spaceStaysHalfWidth() {
        var harness = Harness()
        harness.type("Slack de")
        #expect(harness.composing.convertTarget == "Slack で")
        #expect(harness.mixed.isInSync(with: harness.composing))
        #expect(harness.fellThrough == 0)
    }

    // MARK: スペースで英語とつながった英単語

    /// 1文字ずつ打ったあとの区間を、区間判定の表示形式 ([英語] <記号> 日本語) で返す
    static func spans(typing text: String) -> (display: String, harness: Harness) {
        var harness = Harness()
        harness.type(text)
        return (harness.mixed.lastSpans.display, harness)
    }

    @Test("英文の途中のローマ字としても読める語は英語のまま残る")
    func keepsShortEnglishWordsInSentence() {
        let (display, harness) = Self.spans(typing: "henshinhaThank you for help deiikana")
        #expect(display == "henshinha [Thank] < > [you] < > [for] < > [help] < > deiikana")
        #expect(harness.composing.convertTarget == "へんしんはThank you for help でいいかな")
        #expect(harness.fellThrough == 0)
    }

    @Test("打ちかけの語も英語とつながり、生入力とずれない")
    func joinsWhileTyping() {
        var harness = Harness()
        harness.type("Thank y")
        #expect(harness.fellThrough == 0)
        harness.type("ou")
        #expect(harness.mixed.endsWithEnglish)
        #expect(harness.composing.convertTarget == "Thank you")
        #expect(harness.mixed.isInSync(with: harness.composing))
        #expect(harness.fellThrough == 0)
    }

    @Test("英語でもよく使う助詞は英語に挟まれたときだけ英語になり、ほかの助詞は日本語のまま")
    func joinsParticleOnlyBetweenEnglishWords() {
        #expect(Self.spans(typing: "want to go").display == "[want] < > [to] < > [go]")
        #expect(Self.spans(typing: "Slack no").harness.composing.convertTarget == "Slack の")
        #expect(Self.spans(typing: "Slack de").harness.composing.convertTarget == "Slack で")
        #expect(Self.spans(typing: "Slack de meeting suru").display == "[Slack] < > de < > [meeting] < > suru")
    }

    // MARK: 日本語にくっついた助詞

    @Test("日本語にくっついた小文字の助詞は、英語と判定されても日本語にする", arguments: [
        ("defo-ruto", "でふぉーると"),
        ("kyouhadefo-rutode", "きょうはでふぉーるとで"),
        ("GitHubdePRwodasu", "GitHubでPRをだす"),
        ("Slack de meeting suru", "Slack で meeting する"),
        ("want to go", "want to go")
    ])
    func absorbsParticleIntoJapanese(input: String, expected: String) {
        let (_, harness) = Self.spans(typing: input)
        #expect(harness.composing.convertTarget == expected)
        #expect(harness.mixed.isInSync(with: harness.composing))
        #expect(harness.fellThrough == 0)
    }
}
#endif
