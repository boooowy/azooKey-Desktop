import Testing

@testable import RomajiSegmenter

@Suite("層2: 特徴量")
struct FeatureTests {
    static let golden = try! Golden.load(FeatureGolden.self, "features")

    @Test("特徴文字列が順序込みで Python と一致", arguments: golden.cases)
    func features(_ c: FeatureGolden.Case) {
        var b = FeatureBuilder(
            ascii: Array(c.text.utf8), window: Self.golden.window, cased: Self.golden.cased)
        #expect(b.features(at: c.i) == c.feats, "text=\(c.text) i=\(c.i)")
    }

    @Test("重みのヘッダが golden と揃っている")
    func weightHeader() {
        #expect(Golden.weights.window == Self.golden.window)
        #expect(Golden.weights.cased == Self.golden.cased)
        #expect(Golden.weights.featureCount == 1 << 20)
        #expect(Golden.weights.intercept == 2.5899218033917766)
    }

    @Test("cased=true なら 1 文字あたり 15 特徴")
    func featureCount() {
        var b = FeatureBuilder(ascii: Array("abc".utf8), window: 3, cased: true)
        #expect(b.featuresPerChar == 15)
        #expect(b.features(at: 0).count == 15)
    }

    @Test("1 文字入力でも shape はちょうど 5 文字")
    func singleChar() {
        var b = FeatureBuilder(ascii: Array("A".utf8), window: 3, cased: true)
        let feats = b.features(at: 0)
        #expect(feats.contains("s5:__U__"))
        // gram 側は小文字化される
        #expect(feats.contains("c:a"))
    }
}
