// romaji_model.char_features (romaji_model.py:51-64) の移植。
//
// 大小文字の扱いが 3 通りに分かれるのがこの実装の要点:
//   - c: / gN@ 特徴 … 小文字化した text を "^"*WINDOW … "$"*WINDOW で挟む   (py:52)
//   - s: 系の特徴  … 元の大小のまま。padding は固定 2 文字 ("^^" / "$$") で
//                     WINDOW とは連動しない                                  (py:61-63)
//   - isRomaji     … 小文字化しない (KanaTableChecker を参照)
//
// 特徴文字列は 1 文字あたり 15 個 (WINDOW=3, cased=true のとき):
//   c: 1 個 + gN@ 9 個 (n=2,3,4 それぞれ n 通り) + shape 5 個

/// 1 文字分の特徴を組み立てるバッファ。
/// 打鍵ごとに呼ばれるので、String を 15×n 個作らずバイト列を使い回す。
public struct FeatureBuilder {
    /// 小文字化したうえで "^"*window … "$"*window で挟んだバイト列
    @usableFromInline let padded: [UInt8]
    /// 元の大小から作った shape 文字列 ("^^" + text + "$$" と同じ長さ)
    @usableFromInline let shape: [UInt8]
    @usableFromInline let window: Int
    @usableFromInline let cased: Bool
    @usableFromInline let count: Int

    @usableFromInline var scratch: [UInt8] = []

    public init(ascii: [UInt8], window: Int, cased: Bool) {
        self.window = window
        self.cased = cased
        self.count = ascii.count

        var padded = [UInt8](repeating: UInt8(ascii: "^"), count: window)
        padded.reserveCapacity(ascii.count + window * 2)
        for b in ascii {
            // Python の str.lower() は ASCII 範囲ではこれと一致する
            padded.append(b >= 0x41 && b <= 0x5A ? b + 0x20 : b)
        }
        padded.append(contentsOf: [UInt8](repeating: UInt8(ascii: "$"), count: window))
        self.padded = padded

        // shape: isupper→U / islower→l / それ以外→_
        // "^" "$" "-" 数字はいずれも _ になる。padding は WINDOW と無関係に 2 文字
        var shape = [UInt8(ascii: "_"), UInt8(ascii: "_")]
        shape.reserveCapacity(ascii.count + 4)
        for b in ascii {
            if b >= 0x41 && b <= 0x5A {
                shape.append(UInt8(ascii: "U"))
            } else if b >= 0x61 && b <= 0x7A {
                shape.append(UInt8(ascii: "l"))
            } else {
                shape.append(UInt8(ascii: "_"))
            }
        }
        shape.append(contentsOf: [UInt8(ascii: "_"), UInt8(ascii: "_")])
        self.shape = shape

        self.scratch = [UInt8](repeating: 0, count: 16)
    }

    /// 1 文字あたりの特徴数。
    public var featuresPerChar: Int { 1 + (2 ... window + 1).reduce(0, +) + (cased ? 5 : 0) }

    /// 位置 i の特徴を 1 つずつ body に渡す。Python の char_features と同じ順序。
    @inlinable
    public mutating func forEachFeature(at i: Int, _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
        let c = i + window

        // c:<padded[c]>
        emit(prefix: "c:", bytes: padded, range: c ..< c + 1, body)

        // g{n}@{start-c}:<padded[start ..< start+n]>
        for n in 2 ... (window + 1) {
            for start in (c - n + 1) ... c {
                emitGram(n: n, offset: start - c, range: start ..< start + n, body)
            }
        }

        guard cased else { return }
        // shape[i ..< i+5] は常にちょうど 5 文字 (shape の長さが count+4 のため)
        let s = i
        emit(prefix: "s:", bytes: shape, range: s + 2 ..< s + 3, body)
        emit(prefix: "s3:", bytes: shape, range: s + 1 ..< s + 4, body)
        emit(prefix: "s5:", bytes: shape, range: s ..< s + 5, body)
        emit(prefix: "sl:", bytes: shape, range: s + 1 ..< s + 3, body)
        emit(prefix: "sr:", bytes: shape, range: s + 2 ..< s + 4, body)
    }

    @inlinable
    mutating func emit(
        prefix: StaticString, bytes: [UInt8], range: Range<Int>,
        _ body: (UnsafeBufferPointer<UInt8>) -> Void
    ) {
        scratch.removeAll(keepingCapacity: true)
        prefix.withUTF8Buffer { scratch.append(contentsOf: $0) }
        scratch.append(contentsOf: bytes[range])
        scratch.withUnsafeBufferPointer(body)
    }

    @inlinable
    mutating func emitGram(
        n: Int, offset: Int, range: Range<Int>,
        _ body: (UnsafeBufferPointer<UInt8>) -> Void
    ) {
        scratch.removeAll(keepingCapacity: true)
        scratch.append(UInt8(ascii: "g"))
        appendInt(n)
        scratch.append(UInt8(ascii: "@"))
        appendInt(offset)   // 0 または負。Python の f"{start-c}" と同じ表記
        scratch.append(UInt8(ascii: ":"))
        scratch.append(contentsOf: padded[range])
        scratch.withUnsafeBufferPointer(body)
    }

    @inlinable
    mutating func appendInt(_ v: Int) {
        if v < 0 { scratch.append(UInt8(ascii: "-")) }
        let m = v.magnitude
        if m >= 10 {
            scratch.append(UInt8(ascii: "0") + UInt8(m / 10))
        }
        scratch.append(UInt8(ascii: "0") + UInt8(m % 10))
    }

    /// デバッグ・テスト用。Python の char_features と同じ文字列配列を返す。
    public mutating func features(at i: Int) -> [String] {
        var out: [String] = []
        out.reserveCapacity(featuresPerChar)
        forEachFeature(at: i) { out.append(String(decoding: $0, as: UTF8.self)) }
        return out
    }
}
