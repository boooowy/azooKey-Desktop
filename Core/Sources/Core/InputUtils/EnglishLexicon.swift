import RomajiSegmenter

/// 英語の区間が実在の単語かを調べるための辞書。
///
/// 区間判定 (RomajiSegmenter の `Segmenter`) と同じ `Lexicon` を共有する。
/// `/usr/share/dict/words` (macOS 標準、同梱しない) と、同梱の技術用語 (docker、github など) を合わせたもの。
enum EnglishLexicon {
    /// 初めて使うときに読む (数十 ms)。区間判定の `Segmenter` にも同じものを渡し、二重に読まない
    static let shared = Lexicon.bundled()

    static var words: Set<String> {
        shared.words
    }

    /// 英語として打った語が、実在の語 (の組み合わせ) か。規則は `Lexicon.isKnownWord` を参照
    static func isKnownWord(_ text: String) -> Bool {
        shared.isKnownWord(text)
    }

    static func camelCaseTokens(_ text: String) -> [String] {
        Lexicon.camelCaseTokens(text)
    }

    static func inflectionStems(_ word: String) -> [String] {
        Lexicon.inflectionStems(word)
    }
}
