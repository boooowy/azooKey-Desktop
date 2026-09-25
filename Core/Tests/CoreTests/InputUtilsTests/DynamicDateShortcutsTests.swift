import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@testable import Core

#if os(macOS)
/// 日付・時刻ショートカットは定数。打鍵ごとに作り直さない。
@Suite("日付ショートカット")
struct DynamicDateShortcutsTests {
    @Test("7書式 × 5相対日 + 月年時刻6件")
    func count() {
        #expect(SegmentsManager.dynamicDateShortcuts.count == 7 * 5 + 6)
    }

    @Test("必要な読みがそろっている")
    func rubies() {
        let rubies = Set(SegmentsManager.dynamicDateShortcuts.map(\.ruby))
        #expect(rubies == ["オトトイ", "キノウ", "キョウ", "アシタ", "アサッテ", "コンゲツ", "コトシ", "イマ"])
    }

    /// 現在時刻を含んでいたら、定数として持ち回してはいけない。
    @Test("テンプレート文字列に現在時刻が埋まっていない")
    func isTemplateNotSnapshot() {
        let first = SegmentsManager.dynamicDateShortcuts
        let again = SegmentsManager.dynamicDateShortcuts
        #expect(first.map(\.word) == again.map(\.word))
        // <date format="..." ...> という遅延評価のテンプレート
        #expect(SegmentsManager.dynamicDateShortcuts.allSatisfy { $0.word.hasPrefix("<date ") })
    }
}
#endif
