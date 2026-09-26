// ime_core.segment_input (ime_core.py:23-39) の移植。
//
// 打った文字列全体を (english / japanese / symbol) の並びにする。
// 英字の並び (長音の - を含む) だけを区間判定モデルにかけ、数字・記号はそのまま通す。
//
// 記号を 。、 に置き換えるかどうかは IME 側の方針なのでここではやらない
// (ime_core.compose:57-58 相当は利用側の責務)。

public enum InputLabel: Sendable, Hashable {
    case english
    case japanese
    case symbol
}

public struct InputSpan: Sendable, Hashable {
    public let label: InputLabel
    public let text: String
    public init(label: InputLabel, text: String) {
        self.label = label
        self.text = text
    }
}

extension Segmenter {
    /// 入力全体を区間の並びにする。
    ///
    /// - Parameter partial: 入力途中。**入力の末尾に接している英字の並びだけ**が
    ///   打ちかけの子音で終わることを許される (ime_core.py:33)。
    public func segmentInput(_ text: String, partial: Bool = false) throws -> [InputSpan] {
        guard text.allSatisfy({ $0.isASCII }) else {
            throw RomajiSegmenterError.nonASCIIInput(text)
        }
        let ascii = Array(text.utf8)
        var result: [InputSpan] = []
        var pos = 0
        for run in Self.letterRuns(ascii) {
            if run.lowerBound > pos {
                result.append(InputSpan(label: .symbol, text: Self.slice(ascii, pos ..< run.lowerBound)))
            }
            let text = Self.slice(ascii, run)
            if text.contains(where: { $0 != "-" }) {
                // 打ちかけを許すのは、入力の末尾に接している英字の並びだけ
                let best = try segmentKBest(text, k: 1, partial: partial && run.upperBound == ascii.count)
                result += (best.first?.segments ?? []).map {
                    InputSpan(label: $0.label == .english ? .english : .japanese, text: $0.text)
                }
            } else {
                // ハイフンだけの並びは長音にせず記号として通す
                result.append(InputSpan(label: .symbol, text: text))
            }
            pos = run.upperBound
        }
        if pos < ascii.count {
            result.append(InputSpan(label: .symbol, text: Self.slice(ascii, pos ..< ascii.count)))
        }
        return result
    }

    /// `[A-Za-z]+(?:-+[A-Za-z]*)*|-+` (ime_core.py:19) と同じ切り出し。
    static func letterRuns(_ ascii: [UInt8]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var i = 0
        while i < ascii.count {
            if isLetter(ascii[i]) {
                let start = i
                while i < ascii.count, isLetter(ascii[i]) { i += 1 }
                // (?:-+[A-Za-z]*)* — ハイフン群と英字群の繰り返しを貪欲に飲む
                while i < ascii.count, ascii[i] == hyphen {
                    while i < ascii.count, ascii[i] == hyphen { i += 1 }
                    while i < ascii.count, isLetter(ascii[i]) { i += 1 }
                }
                runs.append(start ..< i)
            } else if ascii[i] == hyphen {
                let start = i
                while i < ascii.count, ascii[i] == hyphen { i += 1 }
                runs.append(start ..< i)
            } else {
                i += 1
            }
        }
        return runs
    }

    static let hyphen = UInt8(ascii: "-")

    static func isLetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    static func slice(_ ascii: [UInt8], _ range: Range<Int>) -> String {
        String(decoding: ascii[range], as: UTF8.self)
    }
}

extension Array where Element == InputSpan {
    /// ime_core.display (ime_core.py:69-71) と同じ書式。テストとデバッグ用。
    public var display: String {
        map { span in
            switch span.label {
            case .english: "[\(span.text)]"
            case .symbol: "<\(span.text)>"
            case .japanese: span.text
            }
        }.joined(separator: " ")
    }
}
