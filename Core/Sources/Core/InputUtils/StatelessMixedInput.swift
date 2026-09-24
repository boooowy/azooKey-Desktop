import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import RomajiSegmenter

/// 日英混在入力 (モード切り替えなしで打つ) の状態。
///
/// 打った ASCII をそのまま保持し、1打鍵ごとに区間判定して
/// `ComposingText` を「区間ごとに違う inputStyle」で組み直す。
///
/// - 日本語と判定した区間 → `.roman2kana` (azooKey がかなに変換する)
/// - 英語と判定した区間   → `.direct`     (そのまま通す)
///
/// 1回の `requestCandidates` で変換できるので、Zenzai が文全体を見られる。
///
/// 組み直しは**区間のラベルが変わったときだけ**行う。毎回作り直すと
/// azooKey の追記時の速い経路 (`lastOperation = .insert`) を潰すため。
/// この「組み直した回数」がそのまま、打鍵中のちらつきの指標になる。
struct StatelessMixedInput {
    /// 打った生の ASCII (変換前)
    private(set) var raw: String = ""
    /// 直前の区間判定の結果。ラベルが変わったかの判定に使う
    private var lastSpans: [InputSpan] = []
    /// 組み直した回数 (ちらつきの指標)
    private(set) var rebuildCount: Int = 0

    private let segmenter: Segmenter?

    init() {
        // 重みの読み込みに失敗してもIME全体は動かす。この機能だけ無効になる
        self.segmenter = try? Segmenter.bundled()
    }

    var isAvailable: Bool { segmenter != nil }
    var isEmpty: Bool { raw.isEmpty }

    mutating func reset() {
        raw = ""
        lastSpans = []
        rebuildCount = 0
    }

    /// 打鍵を取り込んだ結果、ComposingText をどうすべきか。
    enum Plan {
        /// 既に打ってあった文字のラベルが変わった → 全部組み直す
        case rebuild(ComposingText)
        /// 変わっていない → 追加分だけ、**その文字自身のラベルに応じた** style で追記する
        ///
        /// ComposingText は入力要素ごとに style を持つので、区間の切れ目は関係なく
        /// 1文字ずつの style さえ合っていれば同じ結果になる。
        case append([(text: String, style: InputStyle)])
    }

    /// 文字を追加して、ComposingText の更新方法を決める。
    /// 扱えない入力なら nil を返す (呼び出し側は通常の経路に倒す)。
    mutating func plan(appending string: String, partial: Bool) -> Plan? {
        guard let segmenter, string.allSatisfy(\.isASCII), !string.isEmpty else { return nil }
        let oldMask = Self.mask(lastSpans)
        raw += string
        guard let spans = try? segmenter.segmentInput(raw, partial: partial) else {
            raw.removeLast(string.count)
            return nil
        }
        lastSpans = spans
        let newMask = Self.mask(spans)

        guard newMask.count > oldMask.count, newMask.starts(with: oldMask) else {
            // 既に打ってあった文字のラベルが変わった (Slac → Slack など)
            rebuildCount += 1
            return .rebuild(Self.composingText(from: spans))
        }

        // 追加分だけを、ラベルが連続する塊にまとめて追記する
        let rawBytes = Array(raw.utf8)
        var pieces: [(text: String, style: InputStyle)] = []
        var previousLabel: InputLabel? = oldMask.last
        var i = oldMask.count
        while i < newMask.count {
            let label = newMask[i]
            var j = i
            while j < newMask.count, newMask[j] == label { j += 1 }
            let text = String(decoding: rawBytes[i ..< j], as: UTF8.self)
            switch label {
            case .japanese:
                pieces.append((text, .roman2kana))
            case .english:
                pieces.append((text, .direct))
            case .symbol:
                pieces.append((Self.japanesePunctuation(text, previousLabel: previousLabel), .direct))
            }
            previousLabel = label
            i = j
        }
        return .append(pieces)
    }

    /// 末尾から1文字削る。空になったら false を返す。
    mutating func deleteBackward(count: Int = 1) -> Bool {
        guard !raw.isEmpty else { return false }
        raw.removeLast(min(count, raw.count))
        return true
    }

    /// 今の生入力から必ず組み直す (削除のとき。短くなると前方のラベルも変わりうる)。
    mutating func rebuild(partial: Bool) -> ComposingText {
        guard let segmenter, !raw.isEmpty else {
            lastSpans = []
            return ComposingText()
        }
        let spans = (try? segmenter.segmentInput(raw, partial: partial)) ?? []
        lastSpans = spans
        rebuildCount += 1
        return Self.composingText(from: spans)
    }

    static func mask(_ spans: [InputSpan]) -> [InputLabel] {
        spans.flatMap { span in [InputLabel](repeating: span.label, count: span.text.utf8.count) }
    }

    /// 区間の並びから ComposingText を作る。
    static func composingText(from spans: [InputSpan]) -> ComposingText {
        var composing = ComposingText()
        var previousLabel: InputLabel?
        for span in spans {
            switch span.label {
            case .japanese:
                composing.insertAtCursorPosition(span.text, inputStyle: .roman2kana)
            case .english:
                composing.insertAtCursorPosition(span.text, inputStyle: .direct)
            case .symbol:
                composing.insertAtCursorPosition(
                    japanesePunctuation(span.text, previousLabel: previousLabel), inputStyle: .direct)
            }
            previousLabel = span.label
        }
        return composing
    }

    /// 日本語区間の直後の `.` `,` を `。` `、` にする。
    ///
    /// azooKey の roman2kana は ASCII の `.` `,` をそのまま通す (実測) ので、
    /// ここで自前で置き換える。ime_core.compose (ime_core.py:57-58) と同じ規則で、
    /// **チャンクの先頭 1 文字だけ**が対象。
    static func japanesePunctuation(_ text: String, previousLabel: InputLabel?) -> String {
        guard previousLabel == .japanese, let first = text.first else { return text }
        switch first {
        case ".": return "。" + text.dropFirst()
        case ",": return "、" + text.dropFirst()
        default: return text
        }
    }
}
