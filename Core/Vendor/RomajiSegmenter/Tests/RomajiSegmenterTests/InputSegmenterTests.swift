import Testing

@testable import RomajiSegmenter

@Suite("層6: 入力全体の分割 (記号を含む)")
struct InputSegmenterTests {
    static let golden = try! Golden.load(InputSegmentGolden.self, "input_segments")
    static let segmenter = Segmenter(weights: Golden.weights, lexicon: Lexicon.bundled())

    @Test("segment_input が Python と一致", arguments: golden.cases)
    func segmentInput(_ c: InputSegmentGolden.Case) throws {
        #expect(try Self.segmenter.segmentInput(c.text, partial: false).display == c.final,
                "text=\(c.text) (確定時)")
        #expect(try Self.segmenter.segmentInput(c.text, partial: true).display == c.partial,
                "text=\(c.text) (打ちかけ)")
    }

    @Test("英字の並びの切り出しが正規表現と一致")
    func letterRuns() {
        // ime_core.LETTER_RUN_RE = [A-Za-z]+(?:-+[A-Za-z]*)*|-+
        func runs(_ s: String) -> [String] {
            Segmenter.letterRuns(Array(s.utf8)).map { Segmenter.slice(Array(s.utf8), $0) }
        }
        #expect(runs("abc") == ["abc"])
        #expect(runs("a-b") == ["a-b"])          // ハイフンは英字の並びに取り込まれる
        #expect(runs("a--") == ["a--"])          // 末尾のハイフン群も飲む
        #expect(runs("---") == ["---"])          // ハイフンだけの並び
        #expect(runs("-a-") == ["-", "a-"])      // 先頭のハイフンは別の並び
        #expect(runs("a1b") == ["a", "b"])       // 数字は区切りになる
        #expect(runs("3jini") == ["jini"])
        #expect(runs("") == [])
        #expect(runs("123") == [])
    }

    @Test("ハイフンだけの並びは symbol になる")
    func hyphenOnlyIsSymbol() throws {
        let spans = try Self.segmenter.segmentInput("---")
        #expect(spans.count == 1)
        #expect(spans.first?.label == .symbol)
    }

    @Test("非 ASCII は throw する")
    func nonASCII() {
        #expect(throws: RomajiSegmenterError.self) {
            _ = try Self.segmenter.segmentInput("あ")
        }
    }
}
