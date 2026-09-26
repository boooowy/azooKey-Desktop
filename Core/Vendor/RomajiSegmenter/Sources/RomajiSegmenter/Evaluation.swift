// Python の評価スクリプトと同じ指標を出すための補助。
//   real_test.english_mask / seg_mask  (real_test.py:26-37)
//   eval_a.spans / error_type          (eval_a.py:48-63)
//   eval_incremental.settled_len       (eval_incremental.py:31-35)

public enum Evaluation {
    /// 正解の英語部分を E、それ以外を . で表す。英単語は入力中に出現順に現れる。
    public static func englishMask(text: String, english: [String]) -> String {
        let ascii = Array(text.utf8)
        var mask = [UInt8](repeating: UInt8(ascii: "."), count: ascii.count)
        var pos = 0
        for word in english {
            let w = Array(word.utf8)
            guard let i = indexOf(w, in: ascii, from: pos) else { continue }
            for k in i ..< (i + w.count) { mask[k] = UInt8(ascii: "E") }
            pos = i + w.count
        }
        return String(decoding: mask, as: UTF8.self)
    }

    public static func segMask(_ segments: [Segment]) -> String {
        segments.map {
            String(repeating: $0.label == .english ? "E" : ".", count: $0.text.utf8.count)
        }.joined()
    }

    /// マスク中の "E+" の区間。
    public static func spans(_ mask: String) -> [(Int, Int)] {
        let b = Array(mask.utf8)
        var out: [(Int, Int)] = []
        var i = 0
        while i < b.count {
            guard b[i] == UInt8(ascii: "E") else { i += 1; continue }
            var j = i
            while j < b.count, b[j] == UInt8(ascii: "E") { j += 1 }
            out.append((i, j))
            i = j
        }
        return out
    }

    public static func errorType(truth: String, pred: String) -> String {
        let ts = spans(truth), ps = spans(pred)
        func overlaps(_ a: (Int, Int), _ b: (Int, Int)) -> Bool { a.0 < b.1 && b.0 < a.1 }
        let missed = ts.filter { t in !ps.contains { overlaps(t, $0) } }
        let extra = ps.filter { p in !ts.contains { overlaps(p, $0) } }
        if ts.isEmpty { return "② 英語なし文に誤検出" }
        if ps.isEmpty { return "③ 英語を全く検出できず" }
        if !missed.isEmpty && !extra.isEmpty { return "④ 見逃し+誤検出" }
        if !missed.isEmpty { return "③ 一部の英語を見逃し" }
        if !extra.isEmpty { return "④ 余分な英語区間" }
        return "① 境界のずれ"
    }

    /// 長さ typed まで打った時点で「打ち終わった」とみなす範囲
    /// (今打っている最後の区間の手前まで)。
    public static func settledLength(truth: String, typed: Int) -> Int {
        let b = Array(truth.utf8).prefix(typed)
        guard let last = b.last else { return 0 }
        var start = b.count - 1
        while start > 0, b[start - 1] == last { start -= 1 }
        return start
    }

    static func indexOf(_ needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var i = from
        while i + needle.count <= haystack.count {
            if Array(haystack[i ..< i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }
}
