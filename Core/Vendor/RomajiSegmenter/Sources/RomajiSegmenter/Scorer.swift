import Foundation

/// 各文字が英語である対数オッズ (decision_function) を計算する。
///
/// Python 側は `sigmoid(coef·x + intercept)` (romaji_model.py:302)。
/// クラス 1 = 英語。
public struct Scorer: Sendable {
    public let weights: Weights

    public init(weights: Weights) {
        self.weights = weights
    }

    /// 文字ごとの logit。`englishProbs` の元になる。
    ///
    /// p は 0/1 に飽和して誤差を隠すので、Python との突き合わせは logit で行う。
    public func logits(ascii: [UInt8]) -> [Double] {
        guard !ascii.isEmpty else { return [] }
        var builder = FeatureBuilder(ascii: ascii, window: weights.window, cased: weights.cased)
        let mask = weights.featureCount - 1
        var indices: [Int] = []
        indices.reserveCapacity(builder.featuresPerChar)

        var out = [Double](repeating: 0, count: ascii.count)
        weights.coef.withUnsafeBufferPointer { coef in
            for i in 0 ..< ascii.count {
                indices.removeAll(keepingCapacity: true)
                builder.forEachFeature(at: i) { bytes in
                    indices.append(Int(Int32(bitPattern: murmurHash3_x86_32(bytes, seed: 0)).magnitude) & mask)
                }
                // scipy の CSR は sum_duplicates() 後にインデックス昇順で並ぶ。
                // 同じ index に落ちた特徴 (ハッシュ衝突) は値が加算されるので、
                // 昇順に並べてから足すと丸め順序まで Python と揃う。
                indices.sort()
                var sum = weights.intercept
                for idx in indices {
                    sum += Double(coef[idx])
                }
                out[i] = sum
            }
        }
        return out
    }

    /// 文字ごとの英語確率。
    public func englishProbs(ascii: [UInt8]) -> [Double] {
        logits(ascii: ascii).map { 1 / (1 + Foundation.exp(-$0)) }
    }
}
