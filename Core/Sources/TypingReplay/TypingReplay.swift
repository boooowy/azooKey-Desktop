import ConverterServerCore
import Core
import Foundation

/// 評価用の文を、実機の変換サーバーのコードに打鍵して、崩れたものを探す。
///
/// ビルドは `--build-system native` で行う (ConverterServer と同じ。既定の build system だと
/// Zenzai の Metal 初期化で abort する。`Tools/embed_converter_server.sh` を参照)。
///
///     swift build -c release --package-path Core --product typing-replay --build-system native
///     Core/.build/release/typing-replay \
///       --cases ../jev-test/data/cases_dev.json \
///       --resources "/Library/Input Methods/azooKeyMac.app/Contents/Resources" \
///       --out /tmp/replay [--baseline /tmp/replay-old/results.json] [--limit 50] \
///       [--predictive-typing] [--typo-correction] [--inference-limit 7] [--learning] \
///       [--profile システムエンジニア] [--leading-text 打ち始める前からテキスト欄にある文]
///
/// 実行には Zenzai のモデルが要る (`--resources`)。学習データは一時ディレクトリに置き、
/// 実機の学習データには触れない。学習は結果が打つ順に左右されないよう、既定では切る。
@main
enum TypingReplay {
    struct Arguments {
        var casesURL: URL
        var resourcesURL: URL
        var outputURL: URL
        var baselineURL: URL?
        var limit: Int?
        var options = ReplaySession.Options()
        /// 実機の既定値 (5)。前に書いた設定が残っていても、結果が左右されないよう明示する
        var inferenceLimit = 5
        var learning = false
        /// Zenzai のプロフィール (設定の「プロフィール」)。既定は空
        var profile = ""
    }

    @MainActor
    static func main() async {
        do {
            let arguments = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            try await run(arguments)
        } catch {
            FileHandle.standardError.write(Data("typing-replay: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func run(_ arguments: Arguments) async throws {
        var cases = try JSONDecoder().decode([ReplayCase].self, from: Data(contentsOf: arguments.casesURL))
        if let limit = arguments.limit {
            cases = Array(cases.prefix(limit))
        }
        let baseline = try arguments.baselineURL.map {
            try JSONDecoder().decode([ReplayResult].self, from: Data(contentsOf: $0))
        }

        // 設定はこのプロセスの UserDefaults にだけ書く (実機の IME は App Group の共有コンテナを読む)。
        // 終わったら元に戻す
        let previousLearning = Config.Learning().value
        let previousInferenceLimit = Config.ZenzaiInferenceLimit().value
        let previousProfile = Config.ZenzaiProfile().value
        defer {
            Config.Learning().value = previousLearning
            Config.ZenzaiInferenceLimit().value = previousInferenceLimit
            Config.ZenzaiProfile().value = previousProfile
        }
        Config.Learning().value = arguments.learning ? .inputAndOutput : .nothing
        Config.ZenzaiInferenceLimit().value = arguments.inferenceLimit
        Config.ZenzaiProfile().value = arguments.profile

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typing-replay-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        let server = ConverterServer(environment: ConverterServerEnvironment(
            memoryDirectoryURL: workDirectory.appendingPathComponent("memory", isDirectory: true),
            containerURL: nil,
            resourcesDirectoryURL: arguments.resourcesURL
        ))

        // モデルの読み込み (最初の1打鍵で1秒以上かかる) を計測に含めない
        if let first = cases.first {
            _ = try? await replay(first, server: server, options: arguments.options)
        }

        var results: [ReplayResult] = []
        for (index, replayCase) in cases.enumerated() {
            do {
                results.append(try await replay(replayCase, server: server, options: arguments.options))
            } catch {
                FileHandle.standardError.write(Data("skip \(replayCase.keystrokes): \(error)\n".utf8))
            }
            if (index + 1) % 20 == 0 {
                FileHandle.standardError.write(Data("\(index + 1) / \(cases.count)\n".utf8))
            }
        }

        let settings = [
            "予測入力 \(arguments.options.enablePredictiveTyping ? "ON" : "OFF")",
            "入力訂正 \(arguments.options.enableTypoCorrection ? "ON" : "OFF")",
            "推論上限 \(Config.ZenzaiInferenceLimit().value)",
            "学習 \(arguments.learning ? "ON" : "OFF")",
            "プロフィール \(arguments.profile.isEmpty ? "なし" : arguments.profile)",
            "前の文 \(arguments.options.leadingText.count) 文字",
            "データ \(arguments.casesURL.lastPathComponent)"
        ].joined(separator: " / ")

        try FileManager.default.createDirectory(at: arguments.outputURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(results).write(to: arguments.outputURL.appendingPathComponent("results.json"))
        let report = Report.markdown(results: results, baseline: baseline, settings: settings)
        try Data(report.utf8).write(to: arguments.outputURL.appendingPathComponent("report.md"))

        let errors = results.filter(\.enterVerdict.isObviousError).count
        print("\(results.count) 件中 明らかな誤り \(errors) 件 → \(arguments.outputURL.path)/report.md")
    }

    /// 1件を2通り (A: 打って Enter、B: 打って Space → Enter) で打つ
    @MainActor
    static func replay(_ replayCase: ReplayCase, server: ConverterServer, options: ReplaySession.Options) async throws -> ReplayResult {
        let events = try replayCase.keystrokes.map { character in
            guard let event = Keyboard.event(for: character) else {
                throw ReplayError.unsupportedCharacter(character)
            }
            return event
        }

        // A. 打って Enter
        let enterSession = ReplaySession(server: server, options: options)
        var keyMilliseconds: [Double] = []
        for event in events {
            if let elapsed = try await enterSession.press(event) {
                keyMilliseconds.append(milliseconds(elapsed))
            }
        }
        let enterElapsed = try await enterSession.press(Keyboard.enter)
        try await commitAll(enterSession)
        await enterSession.close()

        // B. 打って Space → 候補を記録 → Enter で確定しきる
        let spaceSession = ReplaySession(server: server, options: options)
        for event in events {
            try await spaceSession.press(event)
        }
        let spaceElapsed = try await spaceSession.press(Keyboard.space)
        let candidates: [String] = if case .selecting(let presentations, _) = spaceSession.lastSnapshot.candidateWindow {
            presentations.prefix(10).map(\.text)
        } else {
            []
        }
        try await commitAll(spaceSession)
        await spaceSession.close()

        let enterOutput = trimTrailingNewline(enterSession.document)
        let spaceOutput = trimTrailingNewline(spaceSession.document)
        return ReplayResult(
            keystrokes: replayCase.keystrokes,
            expected: replayCase.expected,
            english: replayCase.english,
            enterOutput: enterOutput,
            enterVerdict: Verdict.judge(output: enterOutput, replayCase: replayCase),
            spaceCandidates: candidates,
            spaceOutput: spaceOutput,
            spaceVerdict: Verdict.judge(output: spaceOutput, replayCase: replayCase),
            rescuableBySpace: replayCase.expected.map { expected in
                candidates.contains { Verdict.normalize($0) == Verdict.normalize(expected) }
            },
            keyMilliseconds: keyMilliseconds,
            spaceMilliseconds: spaceElapsed.map(milliseconds),
            enterMilliseconds: enterElapsed.map(milliseconds)
        )
    }

    /// 変換中の文字列がなくなるまで Enter を押す (文節ごとに確定する場合があるため)
    @MainActor
    private static func commitAll(_ session: ReplaySession) async throws {
        var count = 0
        while session.isComposing && count < 20 {
            try await session.press(Keyboard.enter)
            count += 1
        }
    }

    private static func trimTrailingNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    enum ReplayError: Error, CustomStringConvertible {
        case unsupportedCharacter(Character)
        case missingArgument(String)
        case unknownArgument(String)

        var description: String {
            switch self {
            case .unsupportedCharacter(let character): "US 配列で打てない文字: \(character)"
            case .missingArgument(let name): "\(name) が必要"
            case .unknownArgument(let name): "知らない引数: \(name)"
            }
        }
    }

    static func parseArguments(_ raw: [String]) throws -> Arguments {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var iterator = raw.makeIterator()
        let valueNames: Set<String> = [
            "--cases", "--resources", "--out", "--baseline", "--limit", "--inference-limit", "--profile", "--leading-text"
        ]
        let flagNames: Set<String> = ["--predictive-typing", "--typo-correction", "--learning"]
        while let name = iterator.next() {
            if valueNames.contains(name) {
                guard let value = iterator.next() else {
                    throw ReplayError.missingArgument(name)
                }
                values[name] = value
            } else if flagNames.contains(name) {
                flags.insert(name)
            } else {
                throw ReplayError.unknownArgument(name)
            }
        }
        guard let cases = values["--cases"] else {
            throw ReplayError.missingArgument("--cases")
        }
        guard let out = values["--out"] else {
            throw ReplayError.missingArgument("--out")
        }
        let resources = values["--resources"] ?? "/Library/Input Methods/azooKeyMac.app/Contents/Resources"
        var arguments = Arguments(
            casesURL: URL(fileURLWithPath: cases),
            resourcesURL: URL(fileURLWithPath: resources, isDirectory: true),
            outputURL: URL(fileURLWithPath: out, isDirectory: true),
            baselineURL: values["--baseline"].map { URL(fileURLWithPath: $0) },
            limit: values["--limit"].flatMap(Int.init),
            inferenceLimit: values["--inference-limit"].flatMap(Int.init) ?? 5,
            learning: flags.contains("--learning"),
            profile: values["--profile"] ?? ""
        )
        arguments.options.leadingText = values["--leading-text"] ?? ""
        arguments.options.enablePredictiveTyping = flags.contains("--predictive-typing")
        arguments.options.enableTypoCorrection = flags.contains("--typo-correction")
        return arguments
    }
}
