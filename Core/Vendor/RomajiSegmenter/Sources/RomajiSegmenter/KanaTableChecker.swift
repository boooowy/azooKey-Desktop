// segment_test.is_romaji (segment_test.py:55-65) の忠実移植。
//
// 大事な性質: この実装は小文字化しない。よって大文字を含む区間は必ず false になり、
// DP 上 japanese になれない (= 大文字が実質 english を強制する)。

/// jev-test の _KANA テーブルによる判定。RomajiSegmenter の既定。
public struct KanaTableChecker: RomajiChecker {
    /// 先頭バイトごとにまとめたキー (照合を 1 バケット ≒ 10 件に絞るため)
    private let buckets: [[[UInt8]]]
    public let partialTails: [String]

    public init(
        matchKeys: [String] = KanaTable.matchKeys,
        partialTails: [String] = KanaTable.partialTails
    ) {
        var buckets = [[[UInt8]]](repeating: [], count: 256)
        for key in matchKeys {
            let b = Array(key.utf8)
            guard let first = b.first else { continue }
            buckets[Int(first)].append(b)
        }
        self.buckets = buckets
        self.partialTails = partialTails
    }

    public func prepare(_ ascii: [UInt8]) -> RomajiDecision {
        let n = ascii.count
        // table[i * (n+1) + j] = ascii[i ..< j] が読み切れるか。
        // is_romaji(s) の再帰先は必ず同じ j なので、i を降順に回せば依存が解ける。
        var table = [Bool](repeating: false, count: (n + 1) * (n + 1))
        let vowelsN: Set<UInt8> = Set("aiueon".utf8)
        let vowelsY: Set<UInt8> = Set("aiueoy".utf8)
        let nByte = UInt8(ascii: "n")

        for i in stride(from: n, through: 0, by: -1) {
            table[i * (n + 1) + i] = true      // is_romaji("") == True
            guard i < n else { continue }
            for j in (i + 1) ... n {
                var ok = false
                // 促音: 同じ子音の連続 (n 以外)
                if j - i >= 2, ascii[i] == ascii[i + 1], !vowelsN.contains(ascii[i]),
                   table[(i + 1) * (n + 1) + j] {
                    ok = true
                }
                // ん: 末尾の n、または母音・y 以外が続く n
                if !ok, ascii[i] == nByte, j - i == 1 || !vowelsY.contains(ascii[i + 1]),
                   table[(i + 1) * (n + 1) + j] {
                    ok = true
                }
                // かなのキーに前方一致
                if !ok {
                    for key in buckets[Int(ascii[i])] {
                        let end = i + key.count
                        guard end <= j, table[end * (n + 1) + j] else { continue }
                        var match = true
                        for k in 1 ..< key.count where ascii[i + k] != key[k] {
                            match = false
                            break
                        }
                        if match { ok = true; break }
                    }
                }
                table[i * (n + 1) + j] = ok
            }
        }
        // Sendable なクロージャに渡すため、ここで不変にする
        let filled = table
        let width = n + 1
        return decision(count: n, ascii: ascii) { i, j in filled[i * width + j] }
    }
}
