import Foundation

/// 英語の区間が実在の単語かを調べるための単語の集合。
///
/// macOS に標準で入っている `/usr/share/dict/words` (Webster's 2nd、約23万語、パブリックドメイン) を
/// 実行時に読む。同梱しないのでライセンスを気にしなくてよい。ファイルがない環境 (Linux の CI) では空になり、
/// これを使う補正は何もしない。
enum EnglishLexicon {
    static let path = "/usr/share/dict/words"

    /// 小文字にした単語。初めて使うときに読む (数十 ms)
    static let words: Set<String> = {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    /// 英語として打った語が、実在の語 (の組み合わせ) か。
    ///
    /// - キャメルケースは語ごとに調べる (`FiraCode` → Fira + Code、`MGAApp` → MGA + App)
    /// - 大文字だけの2文字以上は略語とみなす (`AWS`、`PR`)
    /// - 語尾の s / es / ed / ing を外した形も調べる (辞書に複数形や活用形がないため)
    /// - 大文字の略語のあとに小文字が1文字だけ続く形 (`PRo`) は、略語 + 日本語の打ちかけなので実在の語としない
    static func isKnownWord(_ text: String) -> Bool {
        let tokens = camelCaseTokens(text)
        guard !tokens.isEmpty else {
            return false
        }
        return tokens.allSatisfy { token in
            if token.count >= 2, token.allSatisfy(\.isUppercase) {
                return true
            }
            if token.dropFirst().contains(where: \.isUppercase) {
                // 略語 + 小文字1文字 (PRo)
                return false
            }
            let word = token.lowercased()
            return words.contains(word) || inflectionStems(word).contains(where: words.contains)
        }
    }

    /// 語尾の s / es / ed / ing を外した形
    static func inflectionStems(_ word: String) -> [String] {
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
    static func camelCaseTokens(_ text: String) -> [String] {
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
}
