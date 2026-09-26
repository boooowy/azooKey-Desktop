import Core
import Testing

/// 文節を区切って最初の文節だけ確定したら、残りを次の変換対象 (候補選択) にする。
@Suite("文節を確定したあとの状態")
struct InputStateSegmentCommitTests {
    static func event(_ characters: String, keyCode: UInt16) -> KeyEventCore {
        KeyEventCore(modifierFlags: [], characters: characters, charactersIgnoringModifiers: characters, keyCode: keyCode)
    }

    static func selecting(_ event: KeyEventCore, _ userAction: UserAction) -> (ClientAction, ClientActionCallback) {
        InputState.selecting.event(
            eventCore: event,
            userAction: userAction,
            inputLanguage: .japanese,
            liveConversionEnabled: true,
            enableDebugWindow: false,
            enableSuggestion: false
        )
    }

    @Test("Enter で確定して残りがあれば、残りの候補選択に移る")
    func enter() {
        let (action, callback) = Self.selecting(Self.event("\r", keyCode: 36), .enter)
        guard case .submitSelectedCandidate = action,
              case .basedOnSubmitCandidate(ifIsEmpty: .none, ifIsNotEmpty: .selecting) = callback else {
            Issue.record("got \(action), \(callback)")
            return
        }
    }

    @Test("数字キーで候補を選んで残りがあれば、残りの候補選択に移る")
    func number() {
        let (action, callback) = Self.selecting(Self.event("1", keyCode: 18), .number(.one))
        guard case .selectNumberCandidate(1) = action,
              case .basedOnSubmitCandidate(ifIsEmpty: .none, ifIsNotEmpty: .selecting) = callback else {
            Issue.record("got \(action), \(callback)")
            return
        }
    }
}
