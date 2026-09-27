import Foundation

/// 英語区間が実在の単語かを調べる辞書。romaji_model.is_known_word (romaji_model.py) の移植。
///
/// 語は次の2つを合わせたもの (小文字)。
/// - `/usr/share/dict/words`: macOS 標準 (Webster's 2nd、パブリックドメイン)。同梱せず実行時に読む。
///   ない環境 (Linux) では読まない
/// - `Resources/english_tech.txt`: 技術用語・サービス名 (docker、github など。web2 にない)
public struct Lexicon: Sendable {
    public let words: Set<String>

    public init(words: Set<String>) {
        self.words = words
    }

    /// 同梱の技術用語と、あれば /usr/share/dict/words を読む
    public static func bundled() -> Lexicon {
        var words: Set<String> = []
        if let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let word = line.trimmingCharacters(in: .whitespaces)
                if !word.isEmpty {
                    words.insert(word.lowercased())
                }
            }
        }
        if let url = Bundle.module.url(forResource: "english_tech", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let word = line.trimmingCharacters(in: .whitespaces)
                // romaji_model.load_tech_words と同じく、# のコメントと英数字以外を含む行は除く
                if !word.isEmpty, !word.hasPrefix("#"), word.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                    words.insert(word.lowercased())
                }
            }
        }
        return Lexicon(words: words)
    }

    /// 英語として打った語が、実在の語 (の組み合わせ) か。
    ///
    /// - キャメルケースは語ごとに調べる (`FiraCode` → Fira + Code、`MGAApp` → MGA + App)
    /// - 大文字だけの2文字以上は略語とみなす (`AWS`、`PR`)
    /// - 語尾の s / es / ed / ing を外した形も調べる (辞書に複数形や活用形がないため)
    /// - 大文字の略語のあとに小文字が1文字だけ続く形 (`PRo`) は、略語 + 日本語の打ちかけなので実在の語としない
    public func isKnownWord(_ text: String) -> Bool {
        let tokens = Self.camelCaseTokens(text)
        guard !tokens.isEmpty else {
            return false
        }
        return tokens.allSatisfy { token in
            if token.count >= 2, token.allSatisfy(\.isUppercase) {
                return true
            }
            if token.dropFirst().contains(where: \.isUppercase) {
                return false
            }
            let word = token.lowercased()
            return words.contains(word) || Self.inflectionStems(word).contains(where: words.contains)
        }
    }

    /// 語尾の s / es / ed / ing を外した形
    public static func inflectionStems(_ word: String) -> [String] {
        ["s", "es", "ed", "ing"].compactMap { suffix in
            guard word.count > suffix.count + 2, word.hasSuffix(suffix) else {
                return nil
            }
            return String(word.dropLast(suffix.count))
        }
    }

    /// キャメルケースの語に区切る。
    ///
    /// - 小文字 → 大文字の境目 (`FiraCode` → Fira, Code、`iPhone` → i, Phone)
    /// - 大文字の並びのあとに、2文字以上の単語が続く境目 (`MGAApp` → MGA, App)
    /// - 大文字の並びのあとの小文字が1文字だけなら区切らない (`PRo` は1語のまま)
    public static func camelCaseTokens(_ text: String) -> [String] {
        let characters = Array(text)
        var tokens: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            if character.isUppercase, let last = current.last {
                let followingLowercase = characters[(index + 1)...].prefix(while: \.isLowercase).count
                if last.isLowercase || (last.isUppercase && followingLowercase >= 2) {
                    tokens.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    /// 英語区間の加点。romaji_model.lexicon_bonus と同じ。
    ///
    /// モデルがすでに英語寄りに見ている区間 (文字の対数オッズの平均が正) の、境目を決める手がかりにだけ使う。
    /// 大文字だけの語 (略語) には加点しない。
    func bonus(_ chunk: String, meanLogit: Double, config: DecodingConfig) -> Double {
        guard config.lexiconBonus != 0, meanLogit > 0 else {
            return 0
        }
        guard chunk.count >= config.lexiconMinLength, chunk.contains(where: \.isLowercase) else {
            return 0
        }
        return isKnownWord(chunk) ? config.lexiconBonus : 0
    }
}
