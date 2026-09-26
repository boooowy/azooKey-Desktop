import Testing

@testable import RomajiSegmenter

@Suite("層3: スコアラ")
struct LogitTests {
    static let golden = try! Golden.load(LogitGolden.self, "logits")
    static let scorer = Scorer(weights: Golden.weights)

    @Test("文字ごとの logit が Python と一致", arguments: golden.cases)
    func logits(_ c: LogitGolden.Case) {
        let got = Self.scorer.logits(ascii: Array(c.text.utf8))
        #expect(got.count == c.logits.count, "文字数が違う: \(c.text)")
        guard got.count == c.logits.count else { return }
        for (i, (g, e)) in zip(got, c.logits).enumerated() {
            // float32 重みによる誤差の見積もりは 4e-6 程度。1e-4 なら十分な余裕がある
            #expect(abs(g - e.value) < 1e-4, "text=\(c.text) i=\(i) got=\(g) want=\(e.value)")
        }
    }
}
