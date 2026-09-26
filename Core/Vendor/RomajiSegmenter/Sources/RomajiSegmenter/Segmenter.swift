import Foundation

public enum SegmentLabel: Int, Sendable, Hashable {
    case english = 0
    case japanese = 1
}

public struct Segment: Sendable, Hashable {
    public let label: SegmentLabel
    public let text: String
    public init(label: SegmentLabel, text: String) {
        self.label = label
        self.text = text
    }
}

public struct SegmentCandidate: Sendable {
    public let score: Double
    public let segments: [Segment]

    /// segment_test.display (segment_test.py:92-93) と同じ書式。
    public var display: String {
        segments.map { $0.label == .english ? "[\($0.text)]" : $0.text }.joined(separator: " ")
    }
}

/// 区間推定の定数。tune_decoding.py が調整したもので、モデルには保存されていない。
public struct DecodingConfig: Sendable {
    public var switchPenalty: Double = 2.0
    public var englishBias: Double = 0.0
    public var shortEnglishPenalty: Double = 0.0
    public init() {}
}

/// romaji_model.segment_kbest (romaji_model.py:320-355) の移植。
public struct Segmenter: Sendable {
    public let scorer: Scorer
    public let checker: any RomajiChecker
    public var config: DecodingConfig

    public init(
        weights: Weights,
        checker: any RomajiChecker = KanaTableChecker(),
        config: DecodingConfig = DecodingConfig()
    ) {
        self.scorer = Scorer(weights: weights)
        self.checker = checker
        self.config = config
    }

    public static func bundled() throws -> Segmenter {
        Segmenter(weights: try Weights.bundled())
    }

    /// 英字の並びを上位 k 通りに区切る。
    ///
    /// - Parameter partial: 入力途中。末尾の日本語区間が打ちかけの子音で終わることを許す。
    public func segmentKBest(_ text: String, k: Int = 1, partial: Bool = false) throws -> [SegmentCandidate] {
        guard text.allSatisfy({ $0.isASCII }) else {
            throw RomajiSegmenterError.nonASCIIInput(text)
        }
        let ascii = Array(text.utf8)
        let n = ascii.count
        guard n > 0 else { return [] }

        // 対数オッズ → 確率 → クリップ → 累積和
        var probs = scorer.logits(ascii: ascii).map { 1 / (1 + Foundation.exp(-$0)) }
        if config.englishBias != 0 {
            // EN_BIAS が 0 のときは Python も `if EN_BIAS:` で素通りするので、ここも通らない
            probs = probs.map { p in
                1 / (1 + Foundation.exp(-(Foundation.log(p / (1 - p)) + config.englishBias)))
            }
        }
        var cumE = [Double](repeating: 0, count: n + 1)
        var cumJ = [Double](repeating: 0, count: n + 1)
        for t in 0 ..< n {
            // np.cumsum と同じく前から順に累算する (区間ごとに足し直すと丸めが変わる)
            let p = min(max(probs[t], 1e-6), 1 - 1e-6)
            cumE[t + 1] = cumE[t] + Foundation.log(p)
            cumJ[t + 1] = cumJ[t] + Foundation.log(1 - p)
        }

        let decision = checker.prepare(ascii)

        // best[j] は Python の dict と同じく挿入順を保つ。
        // slot.label == nil が "start" (best[0] のみ)。
        struct Cand {
            var score: Double
            var start: Int
            var label: SegmentLabel
            var prevSlot: Int    // best[start] の何番目の枠か (-1 = start)
            var prevRank: Int
        }
        struct Cell { var labels: [SegmentLabel?] = []; var cands: [[Cand]] = [] }

        var best = [Cell](repeating: Cell(), count: n + 1)
        best[0].labels = [nil]
        best[0].cands = [[Cand(score: 0, start: 0, label: .english, prevSlot: -1, prevRank: -1)]]

        for j in 1 ... n {
            for label in [SegmentLabel.english, SegmentLabel.japanese] {
                let cum = label == .english ? cumE : cumJ
                // (候補, 生成順) を貯める。Python の安定ソートを再現するため連番を持つ
                var cands: [(Cand, Int)] = []
                for i in 0 ..< j {
                    if label == .japanese {
                        let ok = decision.isRomaji(i, j)
                            || (partial && j == n && decision.isPartialRomaji(i, j))
                        if !ok { continue }
                    }
                    var segScore = cum[j] - cum[i]
                    if label == .english && j - i == 1 {
                        segScore -= config.shortEnglishPenalty
                    }
                    for (slot, prevLabel) in best[i].labels.enumerated() {
                        // 同じラベルの区間は連続させない (1 つにまとめる)
                        if prevLabel == label { continue }
                        let penalty = prevLabel == nil ? 0.0 : config.switchPenalty
                        for (rank, prev) in best[i].cands[slot].enumerated() {
                            cands.append((
                                Cand(score: prev.score + segScore - penalty,
                                     start: i, label: label, prevSlot: slot, prevRank: rank),
                                cands.count))
                        }
                    }
                }
                guard !cands.isEmpty else { continue }   // Python の `if cands:` と同じ
                // Swift の sort は安定性が保証されないので、生成順を明示的なタイブレークにする
                cands.sort { a, b in
                    a.0.score != b.0.score ? a.0.score > b.0.score : a.1 < b.1
                }
                best[j].labels.append(label)
                best[j].cands.append(cands.prefix(k).map(\.0))
            }
        }

        // Python: best[n]["english"] + best[n]["japanese"] の順に連結してから降順ソート
        var finals: [(Cand, Int)] = []
        for label in [SegmentLabel.english, SegmentLabel.japanese] {
            guard let slot = best[n].labels.firstIndex(of: label) else { continue }
            for c in best[n].cands[slot] { finals.append((c, finals.count)) }
        }
        finals.sort { a, b in a.0.score != b.0.score ? a.0.score > b.0.score : a.1 < b.1 }

        return finals.prefix(k).map { cand, _ in
            SegmentCandidate(score: cand.score, segments: path(cand, best: best, ascii: ascii))
        }

        func path(_ last: Cand, best: [Cell], ascii: [UInt8]) -> [Segment] {
            var out: [Segment] = []
            var cur = last
            var end = n
            while true {
                let text = String(decoding: ascii[cur.start ..< end], as: UTF8.self)
                out.append(Segment(label: cur.label, text: text))
                if cur.prevSlot < 0 { break }
                let prevCell = best[cur.start]
                guard prevCell.labels[cur.prevSlot] != nil else { break }
                end = cur.start
                cur = prevCell.cands[cur.prevSlot][cur.prevRank]
            }
            return out.reversed()
        }
    }
}
