import Foundation

/// 結果を Markdown のレポートにする
enum Report {
    static func markdown(results: [ReplayResult], baseline: [ReplayResult]?, settings: String) -> String {
        var lines: [String] = []
        let total = results.count
        let enterErrors = results.filter(\.enterVerdict.isObviousError)
        let broken = results.filter { !$0.enterVerdict.brokenEnglishWords.isEmpty }
        let leftover = results.filter(\.enterVerdict.hasLeftoverLetters)
        let withExpected = results.filter { $0.expected != nil }
        let matched = withExpected.filter { $0.enterVerdict.matchesExpected == true }
        let rescuable = enterErrors.filter { $0.rescuableBySpace == true }

        lines.append("# 打鍵の再生の結果")
        lines.append("")
        lines.append("- 設定: \(settings)")
        lines.append("- 件数: \(total)")
        lines.append("")
        lines.append("## 集計 (打って Enter で確定した場合)")
        lines.append("")
        lines.append("| 指標 | 件数 | 割合 |")
        lines.append("|---|---|---|")
        lines.append("| 明らかな誤り (下の2つのどちらか) | \(enterErrors.count) | \(percent(enterErrors.count, total)) |")
        lines.append("| 英単語が崩れた | \(broken.count) | \(percent(broken.count, total)) |")
        lines.append("| 英字が残った | \(leftover.count) | \(percent(leftover.count, total)) |")
        lines.append("| 正解と一致 (参考値) | \(matched.count) / \(withExpected.count) | \(percent(matched.count, withExpected.count)) |")
        lines.append("| 明らかな誤りのうち Space で救える | \(rescuable.count) / \(enterErrors.count) | \(percent(rescuable.count, enterErrors.count)) |")
        lines.append("")

        let keyTimes = results.flatMap(\.keyMilliseconds).sorted()
        let spaceTimes = results.compactMap(\.spaceMilliseconds).sorted()
        let enterTimes = results.compactMap(\.enterMilliseconds).sorted()
        lines.append("## 応答時間 (変換サーバーの処理、ms)")
        lines.append("")
        lines.append("| | 件数 | p50 | p90 | 最大 |")
        lines.append("|---|---|---|---|---|")
        lines.append(timingRow("打鍵", keyTimes))
        lines.append(timingRow("Space", spaceTimes))
        lines.append(timingRow("Enter", enterTimes))
        lines.append("")

        if let baseline {
            lines += diffSection(results: results, baseline: baseline)
        }

        lines.append("## 英単語が崩れた")
        lines.append("")
        lines += table(broken) { "崩れた: \($0.enterVerdict.brokenEnglishWords.joined(separator: ", "))" }
        lines.append("## 英字が残った")
        lines.append("")
        lines += table(leftover.filter { $0.enterVerdict.brokenEnglishWords.isEmpty }) { _ in "" }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func diffSection(results: [ReplayResult], baseline: [ReplayResult]) -> [String] {
        let before = Dictionary(baseline.map { ($0.keystrokes, $0) }, uniquingKeysWith: { first, _ in first })
        var regressed: [ReplayResult] = []
        var fixed: [ReplayResult] = []
        for result in results {
            guard let old = before[result.keystrokes] else {
                continue
            }
            if result.enterVerdict.isObviousError && !old.enterVerdict.isObviousError {
                regressed.append(result)
            } else if !result.enterVerdict.isObviousError && old.enterVerdict.isObviousError {
                fixed.append(result)
            }
        }
        var lines = ["## 前回からの差分", "", "- 新しく崩れた: \(regressed.count) 件", "- 直った: \(fixed.count) 件", ""]
        if !regressed.isEmpty {
            lines.append("### 新しく崩れた")
            lines.append("")
            lines += table(regressed) { result in
                "前回: \(before[result.keystrokes]?.enterOutput ?? "")"
            }
        }
        if !fixed.isEmpty {
            lines.append("### 直った")
            lines.append("")
            lines += table(fixed) { result in
                "前回: \(before[result.keystrokes]?.enterOutput ?? "")"
            }
        }
        return lines
    }

    private static func table(_ results: [ReplayResult], note: (ReplayResult) -> String) -> [String] {
        guard !results.isEmpty else {
            return ["(なし)", ""]
        }
        var lines = ["| 打鍵 | 確定 (Enter) | 正解 | Space で救える | メモ |", "|---|---|---|---|---|"]
        for result in results {
            let rescuable = switch result.rescuableBySpace {
            case .some(true): "○"
            case .some(false): "×"
            case .none: "-"
            }
            lines.append("| `\(result.keystrokes)` | \(escape(result.enterOutput)) | \(escape(result.expected ?? "")) | \(rescuable) | \(escape(note(result))) |")
        }
        lines.append("")
        return lines
    }

    private static func timingRow(_ label: String, _ sorted: [Double]) -> String {
        guard let last = sorted.last else {
            return "| \(label) | 0 | - | - | - |"
        }
        func at(_ ratio: Double) -> Double {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * ratio))]
        }
        return "| \(label) | \(sorted.count) | \(format(at(0.5))) | \(format(at(0.9))) | \(format(last)) |"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func percent(_ count: Int, _ total: Int) -> String {
        total == 0 ? "-" : String(format: "%.1f%%", Double(count) / Double(total) * 100)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "↵")
    }
}
