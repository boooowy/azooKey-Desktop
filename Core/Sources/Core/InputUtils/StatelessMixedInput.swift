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
    /// 次の打鍵で必ず組み直すか。
    ///
    /// `resync` のあとは、生入力は合っていても **composingText の各要素の
    /// inputStyle が区間判定と一致している保証がない**。追記だけで済ませると、
    /// 既に入っている要素の style を直せず、英字が1文字残ったままになる。
    private var mustRebuild = false

    private let segmenter: Segmenter?
    /// 日本語区間に使う inputStyle。
    ///
    /// `.roman2kana` を決め打ちにすると、アプリが使っているローマ字テーブルと食い違う。
    /// 実際 azooKey-Desktop の既定テーブルは `-` を `ー` にするが、ライブラリ既定の
    /// `.roman2kana` はしない。呼び出し元から渡されたものを覚えて使う。
    private var japaneseStyle: InputStyle = .roman2kana

    init() {
        // 重みの読み込みに失敗してもIME全体は動かす。この機能だけ無効になる
        self.segmenter = try? Segmenter.bundled()
    }

    var isAvailable: Bool { segmenter != nil }
    var isEmpty: Bool { raw.isEmpty }

    /// `composingText` の入力要素から、打った ASCII を復元する。
    ///
    /// 復元できない要素 (文節区切り、こちらが入れた覚えのない非 ASCII) が
    /// 混じっていたら nil を返す。中途半端に復元すると、それを足がかりに
    /// 区間判定が崩れて英字が残るので、**諦めるほうが安全**。
    static func rawInput(of composingText: ComposingText) -> String? {
        var restored = ""
        for element in composingText.input {
            let character: Character
            switch element.piece {
            case .character(let c):
                character = c
            case .key(let intention, let input, _):
                // 通常経路で入った打鍵。ー のように意図が非 ASCII なら打った文字を使う
                character = if let intention, intention.isASCII { intention } else { input }
            case .compositionSeparator:
                // 生入力に対応する文字がない
                return nil
            }
            switch character {
            // japanesePunctuation で置き換えたぶんを打った文字に戻す
            case "。": restored.append(".")
            case "、": restored.append(",")
            case "ー": restored.append("-")
            default:
                guard character.isASCII else { return nil }
                restored.append(character)
            }
        }
        return restored
    }

    /// `composingText` が外から書き換えられたときに、生入力を実態に合わせ直す。
    ///
    /// 部分確定 (prefixComplete) や再アクティブ化で composingText だけが短くなると、
    /// 生入力に前の入力の残りカスが残る。そのまま打ち続けると、残りカスを含めた
    /// 文字列を区間判定してしまい、文頭に英字が1文字残るなどの崩れ方をする。
    ///
    /// 合わせ直せなかったら false。呼び出し側はこの入力を諦めること。
    mutating func resync(with composingText: ComposingText, partial: Bool) -> Bool {
        guard let restored = Self.rawInput(of: composingText) else { return false }
        guard !restored.isEmpty else {
            reset()
            return true
        }
        guard let spans = try? segmenter?.segmentInput(restored, partial: partial), !spans.isEmpty else {
            return false
        }
        raw = restored
        lastSpans = spans
        // 既に入っている要素の style は信用できないので、次の打鍵で組み直す
        mustRebuild = true
        return true
    }

    /// 生入力と composingText が食い違っていないか。
    ///
    /// 長さだけでなく中身まで見る。長さが合っていても中身がずれていれば、
    /// その差分がそのまま変な英字として出てくる。
    func isInSync(with composingText: ComposingText) -> Bool {
        Self.rawInput(of: composingText) == raw
    }

    mutating func reset() {
        raw = ""
        lastSpans = []
        rebuildCount = 0
        mustRebuild = false
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

        /// ログ用のラベル
        var kindDescription: String {
            switch self {
            case .rebuild: "rebuild"
            case .append: "append"
            }
        }
    }

    /// 文字を追加して、ComposingText の更新方法を決める。
    /// 扱えない入力なら nil を返す (呼び出し側は通常の経路に倒す)。
    mutating func plan(appending string: String, partial: Bool, japaneseStyle: InputStyle = .roman2kana) -> Plan? {
        guard let segmenter, string.allSatisfy(\.isASCII), !string.isEmpty else { return nil }
        self.japaneseStyle = japaneseStyle
        let oldMask = Self.mask(lastSpans)
        raw += string
        guard let spans = try? segmenter.segmentInput(raw, partial: partial) else {
            raw.removeLast(string.count)
            return nil
        }
        lastSpans = spans
        let newMask = Self.mask(spans)

        guard !mustRebuild, newMask.count > oldMask.count, newMask.starts(with: oldMask) else {
            // 既に打ってあった文字のラベルが変わった (Slac → Slack など)、
            // あるいは resync 直後で既存要素の style を信用できない
            mustRebuild = false
            rebuildCount += 1
            return .rebuild(Self.composingText(from: spans, japaneseStyle: japaneseStyle))
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
                pieces.append((Self.longVowelMarks(text), japaneseStyle))
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

    /// 削除を取り込んだ結果、ComposingText をどうすべきか。
    enum DeletePlan {
        /// ラベルが変わっていない → composingText を末尾から削るだけでよい。
        /// 組み直すと azooKey 側が変換をやり直すことがあるので、避けられるなら避ける
        case deleteInPlace
        /// 短くなったことで前方のラベルが変わった → 組み直す
        case rebuild(ComposingText)
    }

    /// 末尾から削って、ComposingText の更新方法を決める。
    mutating func deleteBackward(count: Int = 1, partial: Bool) -> DeletePlan {
        let oldMask = Self.mask(lastSpans).dropLast(min(count, raw.utf8.count))
        raw.removeLast(min(count, raw.count))
        guard let segmenter, !raw.isEmpty else {
            lastSpans = []
            mustRebuild = false
            return .rebuild(ComposingText())
        }
        let spans = (try? segmenter.segmentInput(raw, partial: partial)) ?? []
        lastSpans = spans
        let newMask = Self.mask(spans)
        if !mustRebuild, newMask.elementsEqual(oldMask) {
            return .deleteInPlace
        }
        mustRebuild = false
        rebuildCount += 1
        return .rebuild(Self.composingText(from: spans, japaneseStyle: japaneseStyle))
    }

    /// 今の生入力から必ず組み直す (削除のとき。短くなると前方のラベルも変わりうる)。
    mutating func rebuild(partial: Bool) -> ComposingText {
        guard let segmenter, !raw.isEmpty else {
            lastSpans = []
            return ComposingText()
        }
        let spans = (try? segmenter.segmentInput(raw, partial: partial)) ?? []
        lastSpans = spans
        mustRebuild = false
        rebuildCount += 1
        return Self.composingText(from: spans, japaneseStyle: japaneseStyle)
    }

    static func mask(_ spans: [InputSpan]) -> [InputLabel] {
        spans.flatMap { span in [InputLabel](repeating: span.label, count: span.text.utf8.count) }
    }

    /// 区間の並びから ComposingText を作る。
    static func composingText(from spans: [InputSpan], japaneseStyle: InputStyle = .roman2kana) -> ComposingText {
        var composing = ComposingText()
        var previousLabel: InputLabel?
        for span in spans {
            switch span.label {
            case .japanese:
                composing.insertAtCursorPosition(Self.longVowelMarks(span.text), inputStyle: japaneseStyle)
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

    /// 日本語区間の `-` を長音記号 `ー` にする。
    ///
    /// azooKey のローマ字テーブルは `-` をそのまま通す (`.roman2kana` も
    /// `.mapped(id: .defaultRomanToKana)` も実測で変換しない) ので、
    /// jev_classify の `_KANA["-"] == "ー"` と同じことを自前でやる。
    /// 英語区間の `-` はハイフンのままにしたいので、日本語区間にだけ効かせる。
    static func longVowelMarks(_ text: String) -> String {
        text.contains("-") ? String(text.map { $0 == "-" ? "ー" : $0 }) : text
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
