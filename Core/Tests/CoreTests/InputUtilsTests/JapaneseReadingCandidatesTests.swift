import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@testable import Core

#if os(macOS)
/// 区間判定が英語と誤判定した区間を、変換 (Space) のときに日本語として読み直す。
@Suite("日本語として読み直した候補")
@MainActor
struct JapaneseReadingCandidatesTests {
    /// 実機と同じローマ字テーブル
    static let japaneseStyle: InputStyle = .mapped(id: .defaultRomanToKana)

    /// 1文字ずつ打って Space を押したときと同じ手順で、候補を返す
    static func convert(_ text: String) -> (SegmentsManager, [Candidate]) {
        let manager = SegmentsManager(
            kanaKanjiConverter: .withDefaultDictionary(),
            applicationDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            containerURL: nil,
            context: .init(useZenzai: false)
        )
        for character in text {
            manager.insertAtCursorPosition(String(character), inputStyle: Self.japaneseStyle)
        }
        // enterCandidateSelectionMode と同じ
        manager.insertCompositionSeparator(inputStyle: Self.japaneseStyle, skipUpdate: true)
        manager.update(requestRichCandidates: true)
        guard case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
            return (manager, [])
        }
        return (manager, candidates)
    }

    @Test("windou は wiんどう と判定されるが、Space で ウィンドウ を選べる")
    func windou() throws {
        let (manager, candidates) = Self.convert("windou")
        #expect(manager.convertTarget.hasPrefix("wi"))
        let texts = candidates.map(\.text)
        let index = try #require(texts.firstIndex(of: "ウィンドウ"), "\(texts.prefix(10))")
        // Space 2回で届く位置 (先頭のすぐ後ろ) に差し込む
        #expect((1 ... JapaneseReadingCandidatesTests.maxIndex).contains(index))

        // 選んで確定すると、入力が全部消える
        manager.requestSelectingRow(index)
        let selected = try #require(manager.selectedCandidate)
        manager.prefixCandidateCommited(selected, leftSideContext: "")
        #expect(manager.isEmpty)
    }

    static let maxIndex = SegmentsManager.japaneseReadingCandidateCount + 1

    /// 1文字ずつ打った StatelessMixedInput と ComposingText を返す
    static func type(_ text: String) throws -> (StatelessMixedInput, ComposingText) {
        var mixed = StatelessMixedInput()
        var composing = ComposingText()
        for character in text {
            let planned = mixed.plan(appending: String(character), partial: true, japaneseStyle: Self.japaneseStyle)
            switch try #require(planned) {
            case .rebuild(let rebuilt):
                composing = rebuilt
            case .append(let pieces):
                for piece in pieces {
                    composing.insertAtCursorPosition(piece.text, inputStyle: piece.style)
                }
            }
        }
        return (mixed, composing)
    }

    @Test("小文字の英語区間だけを日本語として読み直す", arguments: [
        ("windou", "うぃんどう"),
        ("windouwohiraku", "うぃんどうをひらく")
    ])
    func reading(_ input: String, _ expected: String) throws {
        let (mixed, composing) = try Self.type(input)
        let reading = try #require(mixed.japaneseReadingComposingText(matching: composing))
        #expect(reading.convertTarget == expected)
    }

    @Test("読み直す区間がなければ nil", arguments: ["Slacknisousin", "konnnitiha"])
    func noReading(_ input: String) throws {
        let (mixed, composing) = try Self.type(input)
        #expect(mixed.japaneseReadingComposingText(matching: composing) == nil)
    }

    @Test("英語のつもりで小文字で打った語は、半端な読み直し候補を出さない")
    func englishWordHasNoReadingCandidates() {
        // window を読み直すと うぃんどw になり、英字が残る
        let (_, candidates) = Self.convert("window")
        #expect(!candidates.contains { $0.text.hasPrefix("ウィンド") && $0.text.contains("w") })
    }

    @Test("読み直した候補は先頭の候補のすぐ後ろに入り、重複しない")
    func insertion() {
        func candidate(_ text: String) -> Candidate {
            Candidate(text: text, value: 0, composingCount: .inputCount(1), lastMid: 0, data: [])
        }
        let list = ["wiんどう", "wiんどー", "ウィンドウ"].map(candidate)
        let merged = SegmentsManager.insertingJapaneseReadingCandidates(
            ["ウィンドウ", "wiんどう"].map(candidate),
            into: list
        )
        #expect(merged.map(\.text) == ["wiんどう", "ウィンドウ", "wiんどー"])
    }

    @Test("履歴学習で覚えた読み直し候補は、先頭の候補より前に出す")
    func learnedReadingCandidateComesFirst() {
        func candidate(_ text: String, learned: Bool) -> Candidate {
            var element = DicdataElement(word: text, ruby: text, cid: 0, mid: 0, value: 0)
            if learned {
                element.metadata = .isLearned
            }
            return Candidate(text: text, value: 0, composingCount: .inputCount(1), lastMid: 0, data: [element])
        }
        let list = [candidate("defおると", learned: false), candidate("defオルト", learned: false)]
        let merged = SegmentsManager.insertingJapaneseReadingCandidates(
            [candidate("デフォると", learned: false), candidate("デフォルト", learned: true)],
            into: list
        )
        #expect(merged.map(\.text) == ["デフォルト", "defおると", "デフォると", "defオルト"])

        // 先頭の候補も覚えているなら、今までどおり先頭を優先する
        let learnedFirst = SegmentsManager.insertingJapaneseReadingCandidates(
            [candidate("デフォルト", learned: true)],
            into: [candidate("defおると", learned: true)]
        )
        #expect(learnedFirst.map(\.text) == ["defおると", "デフォルト"])
    }

    @Test("deforuto で デフォルト を選ぶと、次からは先頭に出る")
    func learnedDefault() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SegmentsManager(
            kanaKanjiConverter: .withDefaultDictionary(),
            applicationDirectoryURL: directory,
            containerURL: nil,
            context: .init(useZenzai: false)
        )
        func convert() -> [Candidate] {
            for character in "deforuto" {
                manager.insertAtCursorPosition(String(character), inputStyle: Self.japaneseStyle)
            }
            manager.insertCompositionSeparator(inputStyle: Self.japaneseStyle, skipUpdate: true)
            manager.update(requestRichCandidates: true)
            guard case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
                return []
            }
            return candidates
        }

        let before = convert().map(\.text)
        let index = try #require(before.firstIndex(of: "デフォルト"), "\(before.prefix(10))")
        #expect(index != 0)
        manager.requestSelectingRow(index)
        manager.prefixCandidateCommited(try #require(manager.selectedCandidate), leftSideContext: "")
        manager.stopComposition()

        let after = convert().map(\.text)
        #expect(after.first == "デフォルト", "\(after.prefix(10))")
    }
}
#endif
