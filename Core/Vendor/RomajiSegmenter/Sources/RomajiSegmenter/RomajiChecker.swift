// 「この区間はローマ字として読み切れるか」の判定。
//
// 既定は jev-test の _KANA テーブルの忠実移植 (KanaTableChecker)。
// IME に組み込むときは azooKey の roman2kana を使った実装に差し替えられるよう、
// protocol 越しに注入する。RomajiSegmenter 本体は変換エンジンに依存しない。

/// テキスト 1 本に対する判定器。
///
/// DP は区間 (i, j) について O(n²) 回問い合わせるので、`prepare` の中で
/// 表を作り込んでよい設計にしてある。
public struct RomajiDecision: Sendable {
    /// ascii[i ..< j] がローマ字として読み切れるか
    public let isRomaji: @Sendable (Int, Int) -> Bool
    /// 打ちかけの子音で終わることを許す版 (入力途中の末尾区間だけで使う)
    public let isPartialRomaji: @Sendable (Int, Int) -> Bool

    public init(
        isRomaji: @escaping @Sendable (Int, Int) -> Bool,
        isPartialRomaji: @escaping @Sendable (Int, Int) -> Bool
    ) {
        self.isRomaji = isRomaji
        self.isPartialRomaji = isPartialRomaji
    }
}

public protocol RomajiChecker: Sendable {
    /// ASCII バイト列 1 本に対する判定器を作る。
    func prepare(_ ascii: [UInt8]) -> RomajiDecision
    /// 打ちかけの末尾として許す文字列 (既定は _KANA 由来の 84 個)。
    var partialTails: [String] { get }
}

extension RomajiChecker {
    /// 素朴な `isRomaji` 実装から `RomajiDecision` を組み立てる。
    ///
    /// `isPartialRomaji` は Python (romaji_model.py:313-317) と同じく
    /// 「末尾 m 文字 (1≤m≤3) を落とした残りが読み切れ、落とした分が tails にある」で導出する。
    /// 片方だけズレる事故を防ぐため、差し替え時もこの導出を使うのが既定。
    public func decision(
        count n: Int, ascii: [UInt8], isRomaji: @escaping @Sendable (Int, Int) -> Bool
    ) -> RomajiDecision {
        let tails = TailSet(partialTails)
        return RomajiDecision(
            isRomaji: isRomaji,
            isPartialRomaji: { i, j in
                if isRomaji(i, j) { return true }
                for m in 1 ... 3 where m <= j - i {
                    if isRomaji(i, j - m) && tails.contains(ascii, j - m, j) { return true }
                }
                return false
            }
        )
    }
}

/// 打ちかけ末尾の集合。長さ 1/2/3 をバイトを詰めた整数の Set で持ち、
/// 引くときに文字列を作らない。
@usableFromInline
struct TailSet: Sendable {
    @usableFromInline var len1: Set<UInt32> = []
    @usableFromInline var len2: Set<UInt32> = []
    @usableFromInline var len3: Set<UInt32> = []

    @usableFromInline
    init(_ tails: [String]) {
        for t in tails {
            let b = Array(t.utf8)
            switch b.count {
            case 1: len1.insert(UInt32(b[0]))
            case 2: len2.insert(UInt32(b[0]) << 8 | UInt32(b[1]))
            case 3: len3.insert(UInt32(b[0]) << 16 | UInt32(b[1]) << 8 | UInt32(b[2]))
            default: break   // _TAILS の最大長は 3
            }
        }
    }

    @usableFromInline
    func contains(_ ascii: [UInt8], _ i: Int, _ j: Int) -> Bool {
        switch j - i {
        case 1: return len1.contains(UInt32(ascii[i]))
        case 2: return len2.contains(UInt32(ascii[i]) << 8 | UInt32(ascii[i + 1]))
        case 3: return len3.contains(UInt32(ascii[i]) << 16 | UInt32(ascii[i + 1]) << 8 | UInt32(ascii[i + 2]))
        default: return false
        }
    }
}
