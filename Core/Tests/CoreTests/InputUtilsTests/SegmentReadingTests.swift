import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@testable import Core

/// 候補選択中に、変換している文節の読みと残りの読みを出す (候補ウィンドウの見出し)。
///
/// Shift+←/→ で区切りが動くのは Zenzai が有効なときだけ (CI にはモデルがない) なので、
/// 区切りの計算そのものを確かめる。
@Suite("文節の読み")
struct SegmentReadingTests {
    static func composing(_ reading: String) -> ComposingText {
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(reading, inputStyle: .direct)
        return composingText
    }

    @Test("選んでいる候補の範囲で、変換する文節の読みと残りの読みに分ける")
    func split() {
        let reading = SegmentsManager.segmentReading(
            of: Self.composing("きょうのてんきははれです"),
            composingCount: .surfaceCount(8)
        )
        #expect(reading == .init(target: "きょうのてんきは", rest: "はれです"))
        #expect(ConverterSegmentReading(reading).isSplit)
    }

    @Test("入力全体を変換する候補では、残りの読みはない")
    func whole() {
        let reading = SegmentsManager.segmentReading(
            of: Self.composing("きょう"),
            composingCount: .surfaceCount(3)
        )
        #expect(reading == .init(target: "きょう", rest: ""))
        #expect(!ConverterSegmentReading(reading).isSplit)
    }

    @Test("候補選択中でなければ出さない")
    @MainActor
    func notSelecting() {
        let manager = SegmentsManager(
            kanaKanjiConverter: .withDefaultDictionary(),
            applicationDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            containerURL: nil,
            context: .init(useZenzai: false)
        )
        manager.insertAtCursorPosition("きょう", inputStyle: .direct)
        #expect(manager.getCurrentSegmentReading(inputState: .composing) == nil)
    }
}
