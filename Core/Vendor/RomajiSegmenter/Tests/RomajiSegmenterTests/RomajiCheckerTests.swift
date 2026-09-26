import Testing

@testable import RomajiSegmenter

@Suite("層5: RomajiChecker")
struct RomajiCheckerTests {
    static let golden = try! Golden.load(RomajiGolden.self, "romaji")
    static let checker = KanaTableChecker()

    /// 文字列全体に対する判定 (Python の is_romaji(s) / is_partial_romaji(s) と同じ)
    static func judge(_ s: String) -> (romaji: Bool, partial: Bool) {
        let ascii = Array(s.utf8)
        let d = checker.prepare(ascii)
        return (d.isRomaji(0, ascii.count), d.isPartialRomaji(0, ascii.count))
    }

    @Test("is_romaji / is_partial_romaji が Python と一致", arguments: golden.cases)
    func judgements(_ c: RomajiGolden.Case) {
        let got = Self.judge(c.s)
        #expect(got.romaji == c.romaji, "is_romaji(\(c.s))")
        #expect(got.partial == c.partial, "is_partial_romaji(\(c.s))")
    }

    @Test("テーブルの件数が Python と一致")
    func tableCounts() {
        #expect(KanaTable.entries.count == Self.golden.kanaKeyCount)   // 157
        #expect(KanaTable.matchKeys.count == 155)                      // nn と n' を除く
        #expect(Set(KanaTable.partialTails) == Set(Self.golden.tails)) // 84
    }

    @Test("大文字を含む語は必ず false")
    func uppercaseIsNeverRomaji() {
        // この性質が DP で「大文字は実質 english を強制する」効果を生んでいる
        for s in ["Slack", "GitHub", "A", "Ab", "aB", "SLACK", "Kono"] {
            #expect(Self.judge(s).romaji == false, "\(s)")
            #expect(Self.judge(s).partial == false, "\(s)")
        }
        // 小文字なら読めるものもある
        #expect(Self.judge("kono").romaji == true)
    }
}
