import Foundation
import os

/// 1打鍵ぶんの、IME 本体での処理時間を区間ごとに記録する。
///
/// 記録は `.debug` レベルで、ふだんは保存されない。見るときは、次を流しながら打つ。
///
///     log stream --level debug --style compact \
///       --predicate 'subsystem == "dev.boooowy.inputmethod.azooKeyMac" && category == "latency"'
///
/// Instruments (os_signpost) でも「key」の区間として見られる。打った文字は記録しない。
struct KeyLatencyTrace {
    private static let logger = Logger(subsystem: "dev.boooowy.inputmethod.azooKeyMac", category: "latency")
    private static let signposter = OSSignposter(logger: logger)

    private let eventID: UInt64
    private let application: String
    private let pendingKeyEventCount: Int
    private let start: ContinuousClock.Instant
    private var last: ContinuousClock.Instant
    private var phases: [(name: StaticString, milliseconds: Double)] = []
    private let signpostState: OSSignpostIntervalState

    /// - Parameters:
    ///   - application: 入力先のアプリの bundle identifier
    ///   - start: キーイベントを受け取った時刻
    ///   - pendingKeyEventCount: この打鍵を送る時点で、応答を待っている打鍵の数
    init(eventID: UInt64, application: String, pendingKeyEventCount: Int, start: ContinuousClock.Instant) {
        self.eventID = eventID
        self.application = application
        self.pendingKeyEventCount = pendingKeyEventCount
        self.start = start
        self.last = start
        self.signpostState = Self.signposter.beginInterval("key", id: Self.signposter.makeSignpostID())
    }

    /// 前の区切りからここまでを、`name` の区間として記録する
    mutating func mark(_ name: StaticString) {
        let now = ContinuousClock.now
        self.phases.append((name, Self.milliseconds(now - self.last)))
        self.last = now
    }

    func finish() {
        Self.signposter.endInterval("key", self.signpostState)
        let total = Self.milliseconds(ContinuousClock.now - self.start)
        let detail = self.phases
            .map { "\($0.name)=\(String(format: "%.2f", $0.milliseconds))" }
            .joined(separator: " ")
        Self.logger.debug(
            "key id=\(self.eventID, privacy: .public) app=\(self.application, privacy: .public) pending=\(self.pendingKeyEventCount, privacy: .public) total=\(String(format: "%.2f", total), privacy: .public) \(detail, privacy: .public)"
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
