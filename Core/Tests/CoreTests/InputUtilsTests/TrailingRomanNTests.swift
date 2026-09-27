import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@testable import Core

#if os(macOS)
/// 末尾の「ん」を n 1つで打って Enter で確定しても、n が残らない。
@Suite("末尾の n")
@MainActor
struct TrailingRomanNTests {
    static func commit(_ text: String) -> String {
        let manager = SegmentsManager(
            kanaKanjiConverter: .withDefaultDictionary(),
            applicationDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            containerURL: nil,
            context: .init(useZenzai: false)
        )
        for character in text {
            manager.insertAtCursorPosition(String(character), inputStyle: .mapped(id: .defaultRomanToKana))
        }
        return manager.commitMarkedText(inputState: .composing)
    }

    @Test("ローマ字の末尾の n は「ん」にして確定する", arguments: ["kankyouhozen", "sa-fin", "douzin"])
    func romanN(_ input: String) {
        let committed = Self.commit(input)
        #expect(!committed.contains { $0.isASCII && $0.isLetter }, "\(committed)")
    }

    @Test("英語として打った末尾の n はそのまま", arguments: [
        ("korehaPython", "Python"),
        ("sorehaGoogleSignIn", "GoogleSignIn")
    ])
    func englishN(_ input: String, _ word: String) {
        #expect(Self.commit(input).hasSuffix(word))
    }
}
#endif
