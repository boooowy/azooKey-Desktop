import ConverterServerCore
import Core
import Foundation

/// IME 本体 (`azooKeyMacInputController`) と同じ手順で、変換サーバーにキーイベントを送る。
///
/// 実機と違うのは XPC の通信とアプリの画面だけ。
/// - サーバーに送るかアプリに流すかは、IME 本体と同じ `ConverterClientEventRouter` で決める
/// - コマンドは実機と同じく JSON にエンコードして `ConverterServer` に渡す
/// - 応答の `insertText` を「文書」に足す。アプリに流したキーはその文字を足す
@MainActor
final class ReplaySession {
    struct Options {
        var liveConversionEnabled = true
        var enablePredictiveTyping = false
        var enableTypoCorrection = false
        /// テキスト欄に、打ち始める前から書かれている文 (実機でアプリから渡る前の文脈の代わり)
        var leadingText = ""
    }

    private let server: ConverterServer
    private let options: Options
    private let sessionID = UUID().uuidString
    private var isOpen = false
    private var eventID: UInt64 = 0

    /// アプリのテキスト欄に書かれた文字列
    private(set) var document = ""
    private(set) var inputState: ConverterInputState = .none
    private(set) var inputLanguage: InputLanguage = .japanese
    private(set) var lastSnapshot: ConverterSessionSnapshot = .empty

    init(server: ConverterServer, options: Options) {
        self.server = server
        self.options = options
    }

    /// キーを1つ押す。サーバーの処理にかかった時間を返す (アプリに流したキーは nil)
    @discardableResult
    func press(_ event: KeyEventCore) async throws -> Duration? {
        let disposition = ConverterClientEventRouter.disposition(
            event: event,
            context: .init(
                acknowledgedInputState: self.inputState,
                acknowledgedInputLanguage: self.inputLanguage,
                hasPendingKeyEvents: false,
                liveConversionEnabled: self.options.liveConversionEnabled
            )
        )
        guard disposition == .sendToServer else {
            // IME が処理せず、アプリがそのキーを受け取る
            self.document += event.characters == "\r" ? "\n" : (event.characters ?? "")
            return nil
        }

        self.eventID &+= 1
        let request = ConverterKeyEventRequest(
            eventID: self.eventID,
            event: event,
            inputStyle: .defaultRomanToKana,
            liveConversionEnabled: self.options.liveConversionEnabled,
            enableDebugWindow: false,
            enableSuggestion: false,
            enablePredictiveTyping: self.options.enablePredictiveTyping,
            enableTypoCorrection: self.options.enableTypoCorrection,
            optionDirectInputText: event.characters,
            context: ConverterTextContext(
                leftSideContext: String((self.options.leadingText + self.document).suffix(ConverterTextContext.transportCharacterLimit)),
                rightSideContext: nil
            ),
            activation: self.isOpen ? nil : ConverterSessionActivation(
                config: ConverterSessionConfig(
                    aiBackendPreference: .off,
                    openAIModelName: "",
                    openAIEndpoint: "",
                    openAIAPIKey: .init(""),
                    includeContextInAITransform: false
                ),
                inputLanguage: self.inputLanguage
            )
        )
        let command: ConverterServerCommand = self.isOpen
            ? .session(sessionID: self.sessionID, command: .handleKeyEvent(request))
            : .openSession(sessionID: self.sessionID, command: .handleKeyEvent(request))
        self.isOpen = true

        let data = try ConverterServerCodec.encode(command)
        let start = ContinuousClock.now
        let responseData = try await self.server.handleCommandData(data)
        let elapsed = ContinuousClock.now - start
        let response = try ConverterServerCodec.decodeResponse(from: responseData)

        for effect in response.effects {
            // IME 本体も insertText 以外 (fallthroughToApplication など) では文書に何も書かない
            if case .insertText(let text) = effect {
                self.document += text
            }
        }
        self.inputState = response.inputState
        if let inputLanguage = response.inputLanguage {
            self.inputLanguage = inputLanguage
        }
        self.lastSnapshot = response.snapshot
        return elapsed
    }

    /// 変換中の文字列が残っているか
    var isComposing: Bool {
        !self.lastSnapshot.isEmpty
    }

    func close() async {
        guard self.isOpen else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.server.closeSession(self.sessionID) { _ in
                continuation.resume()
            }
        }
    }
}
