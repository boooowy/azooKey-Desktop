import Testing

@testable import RomajiSegmenter

@Suite("層4: 区間推定 DP")
struct SegmentationTests {
    static let segGolden = try! Golden.load(SegmentGolden.self, "segments")
    static let partialGolden = try! Golden.load(PartialGolden.self, "partial")
    static let segmenter = Segmenter(weights: Golden.weights)

    @Test("確定時の上位 3 件が Python と一致", arguments: segGolden.cases)
    func kbest(_ c: SegmentGolden.Case) throws {
        let got = try Self.segmenter.segmentKBest(c.text, k: Self.segGolden.k)
        #expect(got.count == c.kbest.count, "候補数が違う: \(c.text)")
        guard got.count == c.kbest.count else { return }
        for (rank, (g, e)) in zip(got, c.kbest).enumerated() {
            // 1-best と 2-best のスコア差は最小 8.3e-3、float32 の誤差は 2.9e-7。
            // 4.5 桁の余裕があるので display は許容誤差なしで比較できる
            #expect(g.display == e.display, "text=\(c.text) rank=\(rank)")
            #expect(abs(g.score - e.score.value) < 1e-5, "text=\(c.text) rank=\(rank)")
        }
    }

    @Test("打ちかけの 1-best が接頭辞ごとに Python と一致", arguments: partialGolden.cases)
    func partial(_ c: PartialGolden.Case) throws {
        let ascii = Array(c.text.utf8)
        #expect(c.displays.count == ascii.count)
        for n in 1 ... ascii.count {
            let prefix = String(decoding: ascii[0 ..< n], as: UTF8.self)
            let got = try Self.segmenter.segmentKBest(prefix, k: 1, partial: true)
            #expect(got.first?.display == c.displays[n - 1], "text=\(c.text) prefix=\(prefix)")
        }
    }

    @Test("非 ASCII は throw する")
    func nonASCII() {
        #expect(throws: RomajiSegmenterError.self) {
            _ = try Self.segmenter.segmentKBest("あいう")
        }
    }
}
