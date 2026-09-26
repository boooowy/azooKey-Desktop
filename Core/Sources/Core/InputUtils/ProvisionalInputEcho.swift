import KanaKanjiConverterModule

/// 変換サーバーの応答を待たずに、打った文字をマークテキストの末尾に出しておくための状態。
///
/// 変換サーバーは別プロセスで、打鍵ごとに変換 (と Zenzai による予測) を終えてから応答する。
/// 実測で平均 14ms、重いときは 30〜50ms かかり、その間は打った文字が画面に出ない。
/// ここでは打った文字をすぐ出しておき、応答が届いたら正しい内容で置き換える。
///
/// 変換結果そのものには手を出さない。途中で変わりうるのは、末尾に足した
/// 応答待ちの文字だけ (`t` → `ta` → 「た」のように、ローマ字がかなになるなど)。
///
/// 送った順に応答が返ることを前提にしている (`ConverterServerClient` はキーイベントを順番に送る)。
public struct ProvisionalInputEcho: Sendable {
    public struct Entry: Sendable, Equatable {
        public var eventID: UInt64
        public var text: String
    }

    /// 応答待ちで、末尾に足している文字
    public private(set) var entries: [Entry] = []

    public init() {}

    /// マークテキストの末尾に足す文字列
    public var suffix: String {
        entries.map(\.text).joined()
    }

    /// キーイベントを送る直前に呼ぶ。末尾に足したら true。
    ///
    /// - Parameters:
    ///   - acknowledgedInputState: 最後に受け取った応答の入力状態
    ///   - pendingKeyEventCount: この打鍵より前に送って、まだ応答がないキーイベントの数
    public mutating func record(
        eventID: UInt64,
        event: KeyEventCore,
        inputLanguage: InputLanguage,
        acknowledgedInputState: InputState,
        pendingKeyEventCount: Int
    ) -> Bool {
        // 変換中 (または未入力) の状態で文字を足すときだけ。候補選択中などは
        // 打った文字で何が起きるか (確定するか、など) を応答を見るまで決められない
        switch acknowledgedInputState {
        case .none, .composing:
            break
        default:
            return false
        }
        // 応答待ちの中に文字を足していないキー (Space、Enter、削除など) があれば、
        // その結果を見るまで表示を読めない
        guard pendingKeyEventCount == entries.count else {
            return false
        }
        guard let text = Self.typedText(event: event, inputLanguage: inputLanguage) else {
            return false
        }
        entries.append(Entry(eventID: eventID, text: text))
        return true
    }

    /// `eventID` までの応答を受け取ったので、そこまでの暫定の文字を外す。
    public mutating func acknowledge(eventID: UInt64) {
        entries.removeAll { $0.eventID <= eventID }
    }

    public mutating func reset() {
        entries = []
    }

    /// 打鍵がそのまま文字として入る場合、その文字列。
    static func typedText(event: KeyEventCore, inputLanguage: InputLanguage) -> String? {
        // ショートカットや Option での直接入力は対象外
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else {
            return nil
        }
        let text: String
        switch UserAction.getUserAction(eventCore: event, inputLanguage: inputLanguage) {
        case .input(let pieces):
            // `-` は ー のように、意図した文字を出す
            text = pieces.inputString(preferIntention: true)
        case .number(let number):
            text = [number.inputPiece].inputString(preferIntention: true)
        default:
            return nil
        }
        // 制御文字などは出さない
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && $0.value >= 0x20 }) else {
            return nil
        }
        return text
    }
}
