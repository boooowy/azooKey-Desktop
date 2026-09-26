import Core
import Testing

@Suite("応答を待たずに打った文字を出す")
struct ProvisionalInputEchoTests {
    static func key(_ characters: String, keyCode: UInt16, modifiers: KeyEventCore.ModifierFlag = []) -> KeyEventCore {
        KeyEventCore(
            modifierFlags: modifiers,
            characters: characters,
            charactersIgnoringModifiers: characters,
            keyCode: keyCode
        )
    }

    /// #expect の中では mutating メソッドを呼べないので、先に受ける
    static func record(
        _ echo: inout ProvisionalInputEcho,
        _ eventID: UInt64,
        _ event: KeyEventCore,
        state: InputState = .composing,
        pending: Int = 0
    ) -> Bool {
        echo.record(eventID: eventID, event: event, inputLanguage: .japanese, acknowledgedInputState: state, pendingKeyEventCount: pending)
    }

    static let a = key("a", keyCode: 0)
    static let t = key("t", keyCode: 17)
    static let space = key(" ", keyCode: 49)
    static let enter = key("\r", keyCode: 36)

    @Test("変換中に打った文字を末尾に足し、応答が届いたぶんから外す")
    func echoAndAcknowledge() {
        var echo = ProvisionalInputEcho()
        let recorded1 = Self.record(&echo, 1, Self.t, state: .composing, pending: 0)
        #expect(recorded1)
        let recorded2 = Self.record(&echo, 2, Self.a, state: .composing, pending: 1)
        #expect(recorded2)
        #expect(echo.suffix == "ta")

        echo.acknowledge(eventID: 1)
        #expect(echo.suffix == "a")
        echo.acknowledge(eventID: 2)
        #expect(echo.suffix.isEmpty)
    }

    @Test("未入力の状態から打ち始めたときも出す (Ghostty で最初の文字が端末に漏れないように)")
    func startComposition() {
        var echo = ProvisionalInputEcho()
        let recorded1 = Self.record(&echo, 1, Self.a, state: .none, pending: 0)
        #expect(recorded1)
        #expect(echo.suffix == "a")
    }

    @Test("- は意図した ー を出す")
    func longVowel() {
        var echo = ProvisionalInputEcho()
        let recorded1 = Self.record(&echo, 1, Self.key("-", keyCode: 27), state: .composing, pending: 0)
        #expect(recorded1)
        #expect(echo.suffix == "ー")
    }

    @Test("文字を足さないキー (Space、Enter、ショートカット) は出さない")
    func nonInputKeys() {
        var echo = ProvisionalInputEcho()
        let recorded1 = Self.record(&echo, 1, Self.space, state: .composing, pending: 0)
        #expect(!recorded1)
        let recorded2 = Self.record(&echo, 2, Self.enter, state: .composing, pending: 0)
        #expect(!recorded2)
        let recorded3 = Self.record(&echo, 3, Self.key("a", keyCode: 0, modifiers: [.command]), state: .composing, pending: 0)
        #expect(!recorded3)
        let recorded4 = Self.record(&echo, 4, Self.key("a", keyCode: 0, modifiers: [.option]), state: .composing, pending: 0)
        #expect(!recorded4)
        #expect(echo.suffix.isEmpty)
    }

    @Test("候補選択中は、打った文字で何が起きるか分からないので出さない")
    func selecting() {
        var echo = ProvisionalInputEcho()
        let recorded1 = Self.record(&echo, 1, Self.a, state: .selecting, pending: 0)
        #expect(!recorded1)
    }

    @Test("文字を足していないキーの応答待ちがあるあいだは出さない")
    func pendingNonInputKey() {
        var echo = ProvisionalInputEcho()
        // Space (eventID 1) を送って応答待ち
        let recorded2 = Self.record(&echo, 2, Self.a, state: .composing, pending: 1)
        #expect(!recorded2)
        #expect(echo.suffix.isEmpty)
    }
}
