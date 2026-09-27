import Core

/// 実機の NSEvent と同じ形のキーイベントを作る (US 配列)。
///
/// `charactersIgnoringModifiers` は NSEvent と同じく Shift だけは反映する (Shift+o → "O")。
enum Keyboard {
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50
    ]

    /// Shift を押して打つ記号と、そのキーの Shift なしの文字
    private static let shiftedSymbols: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\",
        ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"
    ]

    static let space = KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)
    static let enter = KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36)

    /// 1文字を打つキーイベント。US 配列で打てない文字なら nil
    static func event(for character: Character) -> KeyEventCore? {
        if character == " " {
            return space
        }
        let text = String(character)
        if let base = shiftedSymbols[character], let keyCode = keyCodes[base] {
            return KeyEventCore(modifierFlags: [.shift], characters: text, charactersIgnoringModifiers: text, keyCode: keyCode)
        }
        if character.isUppercase, let lower = character.lowercased().first, let keyCode = keyCodes[lower] {
            return KeyEventCore(modifierFlags: [.shift], characters: text, charactersIgnoringModifiers: text, keyCode: keyCode)
        }
        guard let keyCode = keyCodes[character] else {
            return nil
        }
        return KeyEventCore(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: keyCode)
    }
}
