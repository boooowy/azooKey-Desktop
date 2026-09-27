import Testing

@testable import Core

@Suite("英単語の辞書")
struct EnglishLexiconTests {
    @Test("キャメルケースの語に区切る", arguments: [
        ("FiraCode", ["Fira", "Code"]),
        ("iPhone", ["i", "Phone"]),
        ("MGAApp", ["MGA", "App"]),
        // 略語のあとの小文字1文字は区切らない (略語 + 日本語の打ちかけ)
        ("PRo", ["PRo"]),
        ("AWS", ["AWS"])
    ])
    func camelCaseTokens(_ text: String, _ tokens: [String]) {
        #expect(EnglishLexicon.camelCaseTokens(text) == tokens)
    }

    @Test("語尾の s / es / ed / ing を外した形")
    func inflectionStems() {
        #expect(EnglishLexicon.inflectionStems("interpreters").contains("interpreter"))
        #expect(EnglishLexicon.inflectionStems("fixed").contains("fix"))
        // 短すぎる語は外さない
        #expect(EnglishLexicon.inflectionStems("is").isEmpty)
    }
}
