import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
#if canImport(os)
import os
#endif

public final class SegmentsManager {
    public init(
        kanaKanjiConverter: KanaKanjiConverter,
        applicationDirectoryURL: URL,
        containerURL: URL?,
        context: Context = Context()
    ) {
        self.kanaKanjiConverter = kanaKanjiConverter
        self.applicationDirectoryURL = applicationDirectoryURL
        self.containerURL = containerURL
        self.context = context
    }

    /// テストなどの設定注入のための型。外部には設定を露出させない。
    public struct Context {
        public init() {}
        public init(useZenzai: Bool, resourcesDirectoryURL: URL? = nil) {
            self.useZenzai = useZenzai
            self.resourcesDirectoryURL = resourcesDirectoryURL
        }

        var useZenzai: Bool = true
        var resourcesDirectoryURL: URL?
    }

    public weak var delegate: (any SegmentManagerDelegate)?
    private var kanaKanjiConverter: KanaKanjiConverter
    private let applicationDirectoryURL: URL
    private let containerURL: URL?
    private let context: Context

    private var composingText: ComposingText = ComposingText()
    private var lastInputStyle: InputStyle = .direct

    /// 日英混在入力 (モード切り替えなしで打つ) の状態。
    ///
    /// 常に有効。ただし区間判定の重みを読み込めなかったときだけは無効になり、
    /// upstream と同じ経路に倒れる。
    private var mixedInput = StatelessMixedInput()
    private var mixedInputEnabled: Bool {
        mixedInput.isAvailable
    }

    private var liveConversionEnabled: Bool {
        Config.LiveConversion().value
    }
    private var zenzaiPersonalizationLevel: Config.ZenzaiPersonalizationLevel.Value {
        Config.ZenzaiPersonalizationLevel().value
    }
    private var rawCandidates: ConversionResult?
    /// 英語と判定した区間を日本語として読み直して変換した候補 (入力全体を覆うものだけ)。
    /// 区間判定が `windou` を「wiんどう」にしたときでも「ウィンドウ」を選べるようにする
    private var japaneseReadingCandidates: [Candidate] = []

    private var selectionIndex: Int?
    private var didExperienceSegmentEdition = false
    private var lastOperation: Operation = .other
    private var shouldShowCandidateWindow = false

    private var isShowingAdditionalCandidates = false
    private var additionalCandidates: [CandidatePresentation] = []
    private var showingAdditionalCandidateCount = 0
    private var isFixingAdditionalCandidateTop = false

    private var shouldShowDebugCandidateWindow: Bool = false
    private var debugCandidates: [Candidate] = []

    private var replaceSuggestions: [Candidate] = []
    private var suggestSelectionIndex: Int?
    private var backspaceAdjustedPredictionCandidate: PredictionCandidate?
    private var backspaceTypoCorrectionLock: BackspaceTypoCorrectionLock?

    public struct PredictionCandidate: Sendable, Equatable {
        public var displayText: String
        public var appendText: String
        public var deleteCount: Int = 0
    }

    struct BackspaceTypoCorrectionLock: Sendable {
        var displayText: String
        var targetReading: String
    }

    public func makeCandidatePresentations(_ candidates: [Candidate]) -> [CandidatePresentation] {
        let additionalPresentations = self.additionalCandidatePresentationsForSelectionIndex
        return candidates.indices.map { index in
            if index < additionalPresentations.count {
                return .init(candidate: candidates[index], displayContext: additionalPresentations[index].displayContext)
            }
            return .init(candidate: candidates[index])
        }
    }

    private lazy var zenzaiPersonalizationMode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode? = self.getZenzaiPersonalizationMode()

    private func getZenzaiPersonalizationMode() -> ConvertRequestOptions.ZenzaiMode.PersonalizationMode? {
        let alpha = self.zenzaiPersonalizationLevel.alpha
        // オフなので。
        if alpha == 0 {
            return nil
        }
        guard let containerURL else {
            self.appendDebugMessage("❌ Failed to get container URL.")
            return nil
        }

        let base = self.resourcesDirectoryURL.appendingPathComponent("lm", isDirectory: false).path
        let personal = containerURL.appendingPathComponent("Library/Application Support/p13n_v1").path + "/lm"
        // check personal lm existence
        guard [
            FileManager.default.fileExists(atPath: personal + "_c_abc.marisa"),
            FileManager.default.fileExists(atPath: personal + "_r_xbx.marisa"),
            FileManager.default.fileExists(atPath: personal + "_u_abx.marisa"),
            FileManager.default.fileExists(atPath: personal + "_u_xbc.marisa")
        ].allSatisfy(\.self) else {
            self.appendDebugMessage("❌ Seems like there is missing marisa file for prefix \(personal)")
            return nil
        }

        return .init(baseNgramLanguageModel: base, personalNgramLanguageModel: personal, alpha: alpha)
    }

    private enum Operation: Sendable {
        case insert
        case delete
        case editSegment
        case other
    }

    private enum ContextLength {
        static let conversion = 30
    }

    public func appendDebugMessage(_ string: String) {
        self.debugCandidates.insert(
            Candidate(
                text: string.replacingOccurrences(of: "\n", with: "\\n"),
                value: 0,
                composingCount: .surfaceCount(0),
                lastMid: 0,
                data: []
            ),
            at: 0
        )
        while self.debugCandidates.count > 100 {
            self.debugCandidates.removeLast()
        }
    }

    private func zenzaiMode(
        leftSideContext: String?,
        rightSideContext: String?,
        requestRichCandidates: Bool
    ) -> ConvertRequestOptions.ZenzaiMode {
        if !self.context.useZenzai {
            return .off
        }
        return .on(
            weight: self.resourcesDirectoryURL.appendingPathComponent("ggml-model-Q5_K_M.gguf", isDirectory: false),
            inferenceLimit: Config.ZenzaiInferenceLimit().value,
            requestRichCandidates: requestRichCandidates,
            personalizationMode: self.zenzaiPersonalizationMode,
            versionDependentMode: .v3(
                .init(
                    profile: Config.ZenzaiProfile().value,
                    leftSideContext: leftSideContext,
                    rightSideContext: rightSideContext,
                    enableAlignmentSeparator: true,
                    )
            )
        )
    }

    private var resourcesDirectoryURL: URL {
        if let resourcesDirectoryURL = self.context.resourcesDirectoryURL {
            return resourcesDirectoryURL
        }
        if let resourceURL = Bundle.main.resourceURL {
            return resourceURL
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    }

    private var metadata: ConvertRequestOptions.Metadata {
        if let tag = PackageMetadata.gitTag {
            .init(versionString: "azooKey on macOS (\(tag))")
        } else if let commit = PackageMetadata.gitCommit {
            .init(versionString: "azooKey on macOS (\(commit.prefix(7)))")
        } else {
            .init(versionString: "azooKey on macOS (unknown version)")
        }
    }

    /// `/` を `・` にしている代わりに、`/` `／` `?` `？` を候補から選べるようにする
    static let specialCandidateProviders: [any SpecialCandidateProvider] =
        KanaKanjiConverter.defaultSpecialCandidateProviders + [TypedSymbolCandidateProvider()]

    /// 絵文字辞書。`withDefaultEmojiDictionary()` は呼ぶたびに 234KB のテキストを読んで
    /// 辞書を組み立てるので、打鍵ごとに作らない (内容は起動中変わらない)
    static let emojiTextReplacer: TextReplacer = .withDefaultEmojiDictionary()

    private func options(
        leftSideContext: String?,
        rightSideContext: String?,
        requestRichCandidates: Bool,
        requireJapanesePrediction: ConvertRequestOptions.PredictionMode,
        requireEnglishPrediction: ConvertRequestOptions.PredictionMode
    ) -> ConvertRequestOptions {
        .init(
            requireJapanesePrediction: requireJapanesePrediction,
            requireEnglishPrediction: requireEnglishPrediction,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: true,
            learningType: Config.Learning().value.learningType,
            memoryDirectoryURL: self.azooKeyMemoryDir,
            sharedContainerURL: CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: self.azooKeyMemoryDir),
            textReplacer: Self.emojiTextReplacer,
            specialCandidateProviders: Self.specialCandidateProviders,
            zenzaiMode: self.zenzaiMode(
                leftSideContext: leftSideContext,
                rightSideContext: rightSideContext,
                requestRichCandidates: requestRichCandidates
            ),
            experimentalZenzaiPredictiveInput: true,
            typoCorrectionMode: .automatic,
            metadata: self.metadata
        )
    }

    private func hasDebugTypoCorrectionWeights() -> Bool {
        DebugTypoCorrectionWeights.hasRequiredWeightFiles(modelDirectoryURL: self.downloadedInputN5LMDir)
    }

    public var azooKeyMemoryDir: URL {
        self.applicationDirectoryURL
    }

    public var downloadedInputN5LMDir: URL {
        DebugTypoCorrectionWeights.modelDirectoryURL(
            azooKeyApplicationSupportDirectoryURL: self.applicationDirectoryURL.deletingLastPathComponent()
        )
    }

    @MainActor
    public func activate() {
        self.shouldShowCandidateWindow = false
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
        self.zenzaiPersonalizationMode = self.getZenzaiPersonalizationMode()
    }

    @MainActor
    public func reloadUserDictionary() {
        self.kanaKanjiConverter.updateUserDictionaryURL(
            CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: self.azooKeyMemoryDir),
            forceReload: true
        )
    }

    @MainActor
    public func resetLearningData() {
        self.kanaKanjiConverter.resetMemory()
    }

    @MainActor
    public func deactivate(flushLearningData: Bool = true) {
        self.kanaKanjiConverter.stopComposition()
        if flushLearningData {
            self.kanaKanjiConverter.commitUpdateLearningData()
        }
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.mixedInput.reset()
        self.composingText.stopComposition()
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    @MainActor
    /// この入力を打ち切る
    public func stopComposition() {
        self.mixedInput.reset()
        self.composingText.stopComposition()
        self.kanaKanjiConverter.stopComposition()
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    @MainActor
    /// 日本語入力自体をやめる
    public func stopJapaneseInput() {
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.kanaKanjiConverter.commitUpdateLearningData()
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    /// 変換キーを押したタイミングで入力の区切りを示す
    @MainActor
    public func insertCompositionSeparator(inputStyle: InputStyle, skipUpdate: Bool = false) {
        guard self.composingText.input.last?.piece != .compositionSeparator else {
            // すでに末尾がcompositionSeparatorの場合は何もしない
            return
        }
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: inputStyle)])
        self.lastOperation = .insert
        if !skipUpdate {
            self.updateRawCandidate()
        }
    }

    /// 日英混在入力として文字を取り込めたら true。
    ///
    /// 扱える条件を満たさない入力 (ローマ字入力でない / カーソルが末尾にない /
    /// ASCII でない) では false を返し、呼び出し側は upstream と同じ経路に倒す。
    /// このとき生入力は捨てるので、そのあとの打鍵も通常どおりになる。
    @MainActor
    private func tryMixedInsert(_ string: String, inputStyle: InputStyle) -> Bool {
        guard self.mixedInputEnabled else {
            return false
        }
        guard Self.isRomanInputStyle(inputStyle), self.composingText.isAtEndIndex, !string.isEmpty else {
            self.mixedInput.reset()
            return false
        }
        if !self.mixedInput.isInSync(with: self.composingText) {
            // 想定外の経路で composingText が書き換えられていた場合の保険。
            // 合わせ直せないなら諦める。中途半端な状態で続けると英字が残る
            guard self.mixedInput.resync(with: self.composingText, partial: true) else {
                self.mixedInput.reset()
                return false
            }
        }
        guard let plan = self.mixedInput.plan(appending: string, partial: true, japaneseStyle: inputStyle) else {
            self.mixedInput.reset()
            return false
        }
        switch plan {
        case .rebuild(let composingText):
            self.composingText = composingText
        case .append(let pieces):
            // ラベルが変わっていないので追記で済ませる (azooKey の速い経路を潰さない)。
            // style は打った文字自身のラベルから決める。呼び出し元の inputStyle を
            // そのまま使うと、英語区間の 2 文字目以降がローマ字変換されてしまう。
            for piece in pieces {
                self.composingText.insertAtCursorPosition(piece.text, inputStyle: piece.style)
            }
        }
        // 崩れたときに「どの打鍵で」「生入力が何だったか」を後から追えるようにする。
        // log show --predicate 'subsystem == "azooKeyMac.mixedInput"' --info
        Self.logMixedInput("""
            key=\(string) \
            raw=\(self.mixedInput.raw) \
            plan=\(plan.kindDescription) \
            target=\(self.composingText.convertTarget)
            """)
        return true
    }

    /// 日英混在入力の対象になる入力方式か。
    /// かな入力や独自テーブルのときは対象外 (区間判定のモデルはローマ字前提)
    private static func isRomanInputStyle(_ inputStyle: InputStyle) -> Bool {
        switch inputStyle {
        case .roman2kana: true
        case .mapped(id: .defaultRomanToKana): true
        default: false
        }
    }

    static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> String {
        let components = (end - start).components
        // attoseconds は 1 秒未満の端数しか持たないので、秒のぶんを足す
        return String(format: "%.1f", Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
    }

    #if canImport(os)
    private static let mixedInputLogger = os.Logger(
        subsystem: "azooKeyMac.mixedInput", category: "mixedInput"
    )
    #endif

    /// 日英混在入力と変換時間のログ。os.Logger は Apple のプラットフォーム専用なので、
    /// それ以外 (CI の Linux ビルド) では何もしない
    static func logMixedInput(_ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        mixedInputLogger.info("\(text, privacy: .public)")
        #endif
    }

    @MainActor
    public func insertAtCursorPosition(_ string: String, inputStyle: InputStyle) {
        self.lastInputStyle = inputStyle
        if self.tryMixedInsert(string, inputStyle: inputStyle) {
            self.lastOperation = .insert
            self.shouldShowCandidateWindow = !self.liveConversionEnabled
            self.updateRawCandidate()
            return
        }
        self.composingText.insertAtCursorPosition(string, inputStyle: inputStyle)
        self.lastOperation = .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    /// 混在入力に渡す文字列。
    ///
    /// 大文字は shift の意図を尊重したい (大文字はこのモデルで英語を決定づける
    /// 唯一の手がかり) が、`-` のように **意図が非 ASCII になるキー** (日本語入力では `ー`)
    /// をそのまま渡すと区間判定できず、混在入力がそこで止まってしまう。
    /// 意図が ASCII のときだけ意図を使い、そうでなければ打ったキーの文字を使う。
    static func mixedInputString(_ pieces: [InputPiece]) -> String {
        String(pieces.compactMap { piece -> Character? in
            switch piece {
            case .character(let character):
                character
            case .key(let intention, let input, _):
                if let intention, intention.isASCII { intention } else { input }
            case .compositionSeparator:
                nil
            }
        })
    }

    @MainActor
    public func insertAtCursorPosition(pieces: [InputPiece], inputStyle: InputStyle) {
        self.lastInputStyle = inputStyle
        // 打鍵はこちらを通る。intention を優先すると shift 込みの大文字が取れる
        // (大文字はこのモデルで英語を決定づける唯一の手がかりなので落とせない)
        if self.tryMixedInsert(Self.mixedInputString(pieces), inputStyle: inputStyle) {
            self.lastOperation = .insert
            self.shouldShowCandidateWindow = !self.liveConversionEnabled
            self.updateRawCandidate()
            return
        }
        self.composingText.insertAtCursorPosition(pieces.map { .init(piece: $0, inputStyle: inputStyle) })
        self.lastOperation = .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    public func editSegment(count: Int) {
        // 現在選ばれているprefix candidateが存在する場合、まずそれに合わせてカーソルを移動する
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            var afterComposingText = self.composingText
            afterComposingText.prefixComplete(composingCount: candidates[selectionIndex].composingCount)
            let prefixCount = self.composingText.convertTarget.count - afterComposingText.convertTarget.count
            _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + prefixCount)
        }
        if count > 0 {
            if self.composingText.isAtEndIndex && !self.didExperienceSegmentEdition {
                // 現在のカーソルが右端にある場合、左端の次に移動する
                _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + count)
            } else {
                // それ以外の場合、右に広げる
                _ = self.composingText.moveCursorFromCursorPosition(count: count)
            }
        } else {
            _ = self.composingText.moveCursorFromCursorPosition(count: count)
        }
        if self.composingText.isAtStartIndex {
            // 最初にある場合は一つ右に進める
            _ = self.composingText.moveCursorFromCursorPosition(count: 1)
        }
        self.lastOperation = .editSegment
        self.didExperienceSegmentEdition = true
        self.shouldShowCandidateWindow = true
        self.selectionIndex = nil
        self.updateRawCandidate()
    }

    @MainActor
    public func deleteBackwardFromCursorPosition(count: Int = 1) {
        var previousComposingText = self.composingText.prefixToCursorPosition()
        if !self.composingText.isAtEndIndex {
            // 右端に持っていく
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            // 一度segmentの編集状態もリセットにする
            self.didExperienceSegmentEdition = false
            previousComposingText = self.composingText.prefixToCursorPosition()
        }
        if self.mixedInputEnabled, !self.mixedInput.isEmpty, self.composingText.isAtEndIndex,
           self.mixedInput.isInSync(with: self.composingText) {
            // 短くなると前方の区間のラベルも変わりうるので、変わったときだけ組み直す。
            // 毎回組み直すと azooKey 側が変換をやり直して、削除が重くなる
            let deleteStart = ContinuousClock.now
            let planKind: String
            switch self.mixedInput.deleteBackward(count: count, partial: true) {
            case .deleteInPlace:
                self.composingText.deleteBackwardFromCursorPosition(count: count)
                planKind = "inPlace"
            case .rebuild(let rebuilt):
                self.composingText = rebuilt
                planKind = "rebuild"
            }
            if self.mixedInput.isEmpty {
                self.mixedInput.reset()
            }
            self.lastOperation = .delete
            self.shouldShowCandidateWindow = !self.liveConversionEnabled
            let convertStart = ContinuousClock.now
            self.updateRawCandidate()
            // 削除が重いときに、区間判定と変換のどちらが効いているかを切り分ける
            Self.logMixedInput("""
                delete raw=\(self.mixedInput.raw) \
                plan=\(planKind) \
                segment=\(Self.milliseconds(from: deleteStart, to: convertStart))ms \
                convert=\(Self.milliseconds(from: convertStart, to: .now))ms
                """)
            return
        }
        self.composingText.deleteBackwardFromCursorPosition(count: count)
        self.lastOperation = .delete
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
        guard Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights() else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
            return
        }
        let currentConvertTarget = self.composingText.convertTarget
        guard count == 1 else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
            return
        }
        if let lock = self.backspaceTypoCorrectionLock {
            self.backspaceAdjustedPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
                currentConvertTarget: currentConvertTarget,
                targetReading: lock.targetReading,
                displayText: lock.displayText
            )
            if self.backspaceAdjustedPredictionCandidate == nil {
                self.backspaceTypoCorrectionLock = nil
            }
            return
        }
        self.backspaceTypoCorrectionLock = self.lmBasedBackspaceTypoCorrectionLock(previousComposingText: previousComposingText)
        if let lock = self.backspaceTypoCorrectionLock {
            self.backspaceAdjustedPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
                currentConvertTarget: currentConvertTarget,
                targetReading: lock.targetReading,
                displayText: lock.displayText
            )
        } else {
            self.backspaceAdjustedPredictionCandidate = nil
        }
    }

    @MainActor
    public func forgetMemory() {
        if let selectedCandidate {
            self.kanaKanjiConverter.forgetMemory(selectedCandidate)
            self.appendDebugMessage("\(#function): forget \(selectedCandidate.data.map {$0.word})")
        }
    }

    private var candidates: [Candidate]? {
        guard let rawCandidates = self.rawCandidatesList else {
            return self.isShowingAdditionalCandidates
                ? self.additionalCandidatesForSelectionIndex
                : nil
        }
        return self.isShowingAdditionalCandidates
            ? self.additionalCandidatesForSelectionIndex + rawCandidates
            : rawCandidates
    }

    private var rawCandidatesList: [Candidate]? {
        guard let list = self.conversionCandidatesList else {
            return nil
        }
        return Self.insertingJapaneseReadingCandidates(self.japaneseReadingCandidates, into: list)
    }

    /// 日本語として読み直した候補を、先頭の候補のすぐ後ろに差し込む。
    /// Space を1回押すと先頭が選ばれ、もう1回で読み直した候補に移れるようにするため。
    static func insertingJapaneseReadingCandidates(_ readingCandidates: [Candidate], into list: [Candidate]) -> [Candidate] {
        guard let first = list.first, !readingCandidates.isEmpty else {
            return list
        }
        let inserted = readingCandidates.filter { $0.text != first.text }
        let insertedTexts = Set(inserted.map(\.text))
        return [first] + inserted + list.dropFirst().filter { !insertedTexts.contains($0.text) }
    }

    private var conversionCandidatesList: [Candidate]? {
        guard let rawCandidates else {
            return nil
        }
        if !self.didExperienceSegmentEdition {
            if rawCandidates.firstClauseResults.contains(where: { self.composingText.isWholeComposingText(composingCount: $0.composingCount) }) {
                // firstClauseCandidateがmainResultsと同じサイズの場合は、何もしない方が良い
                return rawCandidates.mainResults
            } else {
                // 変換範囲がエディットされていない場合
                let seenAsFirstClauseResults = rawCandidates.firstClauseResults.mapSet(transform: \.text)
                return rawCandidates.firstClauseResults + rawCandidates.mainResults.filter {
                    !seenAsFirstClauseResults.contains($0.text)
                }
            }
        } else {
            return rawCandidates.mainResults
        }
    }

    private var candidateOffsetByAdditionalCandidates: Int {
        self.isShowingAdditionalCandidates ? self.showingAdditionalCandidateCount : 0
    }

    private var additionalCandidatesForSelectionIndex: [Candidate] {
        self.additionalCandidatePresentationsForSelectionIndex.map(\.candidate)
    }

    private var additionalCandidatePresentationsForSelectionIndex: [CandidatePresentation] {
        guard self.isShowingAdditionalCandidates else {
            return []
        }
        guard self.candidateOffsetByAdditionalCandidates > 0 else {
            return []
        }
        return Array(self.additionalCandidates.suffix(self.candidateOffsetByAdditionalCandidates))
    }

    public var convertTarget: String {
        self.composingText.convertTarget
    }

    public var isEmpty: Bool {
        self.composingText.isEmpty
    }

    public func getCleanLeftSideContext(maxCount: Int) -> String? {
        self.delegate?.getLeftSideContext(maxCount: maxCount).map {
            var last = $0.split(separator: "\n", omittingEmptySubsequences: false).last ?? $0[...]
            // 前方の空白を削除する
            while last.first?.isWhitespace ?? false {
                last = last.dropFirst()
            }
            return String(last)
        }
    }

    public func getCleanRightSideContext(maxCount: Int) -> String? {
        self.delegate?.getRightSideContext(maxCount: maxCount).map {
            var first = $0.split(separator: "\n", omittingEmptySubsequences: false).first ?? $0[...]
            // 後方の空白を削除する
            while first.last?.isWhitespace ?? false {
                first = first.dropLast()
            }
            return String(first)
        }
    }

    /// Updates the `self.rawCandidates` based on the current input context.
    ///
    /// This function is responsible for handling candidate conversion,
    /// taking into account partial confirmations and optionally fetching rich candidates.
    /// It also allows an override for the left-side context when necessary.
    ///
    /// - Parameters:
    ///   - requestRichCandidates: A Boolean flag indicating whether to fetch rich candidates (default is `false`). Generating rich candidates takes longer time.
    ///   - forcedLeftSideContext: An optional string that overrides the left-side context (default is `nil`).
    ///
    /// - Note:
    ///   This function is executed on the `@MainActor` to ensure UI consistency.
    /// 日付・時刻変換のショートカット。
    ///
    /// `DateTemplateLiteral.export()` は「いつ評価するか」を書いたテンプレート文字列を
    /// 返すだけで、現在時刻を含まない。つまりこの配列は定数なので、打鍵ごとに
    /// 作り直す必要はない (元は `updateRawCandidate` の中で毎回組み立てていた)。
    nonisolated(unsafe) static let dynamicDateShortcuts: [DicdataElement] =
            [
                ("M/d", -18, DateTemplateLiteral.CalendarType.western),
                ("yyyy/MM/dd", -18.1, .western),
                ("yyyy-MM-dd", -18.2, .western),
                ("M月d日（E）", -18.3, .western),
                ("yyyy年M月d日", -18.4, .western),
                ("Gyyyy年M月d日", -18.5, .japanese),
                ("E曜日", -18.6, .western)
            ].flatMap { (format, value: PValue, type) in
                [
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-2", deltaUnit: 60 * 60 * 24).export(), ruby: "オトトイ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-1", deltaUnit: 60 * 60 * 24).export(), ruby: "キノウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "キョウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "1", deltaUnit: 60 * 60 * 24).export(), ruby: "アシタ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "2", deltaUnit: 60 * 60 * 24).export(), ruby: "アサッテ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value)
                ]
            } + [
                // 月
                .init(word: DateTemplateLiteral(format: "MM月", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コンゲツ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                // 年
                .init(word: DateTemplateLiteral(format: "yyyy年", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                .init(word: DateTemplateLiteral(format: "Gyyyy年", type: .japanese, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
                // 時刻
                .init(word: DateTemplateLiteral(format: "HH:mm", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                .init(word: DateTemplateLiteral(format: "HH時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
                .init(word: DateTemplateLiteral(format: "aK時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.2)
            ]

    @MainActor private func updateRawCandidate(
        requestRichCandidates: Bool = false,
        forcedLeftSideContext: String? = nil,
        forcedRightSideContext: String? = nil
    ) {
        if self.lastOperation != .delete {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
        }
        self.resetAdditionalCandidates()
        self.japaneseReadingCandidates = []
        // 不要
        if composingText.isEmpty {
            self.rawCandidates = nil
            self.kanaKanjiConverter.stopComposition()
            return
        }
        let dynamicShortcuts = Self.dynamicDateShortcuts

        // 打鍵ごとに走る3つの処理を別々に測る。遅いときにどれが効いているか分かるように
        let dictStart = ContinuousClock.now
        self.kanaKanjiConverter.importDynamicUserDictionary([], shortcuts: dynamicShortcuts)

        // アプリから前後の文脈を取りに行く (アプリ側への問い合わせなので、相手次第で遅い)
        let contextStart = ContinuousClock.now
        let leftSideContext = forcedLeftSideContext ?? self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        let rightSideContext = forcedRightSideContext ?? self.getCleanRightSideContext(maxCount: ContextLength.conversion)

        // 変換 (Space) のときだけ。打鍵ごとに走らせると変換が倍かかる。
        // 本来の変換より先に行う。converter は直前に変換した入力をキャッシュして
        // 次の打鍵で使うので、最後に変換するのは本来の入力にしておく
        if requestRichCandidates {
            self.japaneseReadingCandidates = self.makeJapaneseReadingCandidates(leftSideContext: leftSideContext)
        }

        let convertStart = ContinuousClock.now
        let result = self.kanaKanjiConverter.requestCandidates(
            self.composingText,
            options: options(
                leftSideContext: leftSideContext,
                rightSideContext: rightSideContext,
                requestRichCandidates: requestRichCandidates,
                requireJapanesePrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled,
                requireEnglishPrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled
            )
        )
        let end = ContinuousClock.now
        self.rawCandidates = result
        Self.logMixedInput("""
            convert n=\(self.composingText.input.count) \
            rich=\(requestRichCandidates) \
            dict=\(Self.milliseconds(from: dictStart, to: contextStart))ms \
            context=\(Self.milliseconds(from: contextStart, to: convertStart))ms \
            zenzai=\(Self.milliseconds(from: convertStart, to: end))ms
            """)
    }

    @MainActor public func update(requestRichCandidates: Bool) {
        self.updateRawCandidate(requestRichCandidates: requestRichCandidates)
        self.shouldShowCandidateWindow = true
    }

    static let japaneseReadingCandidateCount = 3

    /// 英語と判定した区間を日本語として読み直して変換し、入力全体を覆う候補を返す。
    ///
    /// 読み直した ComposingText と今の composingText は、同じ生入力を1文字ずつ
    /// 入れたもの。全体を覆う候補なら、今の composingText を全部確定する候補として扱える。
    @MainActor private func makeJapaneseReadingCandidates(leftSideContext: String?) -> [Candidate] {
        guard self.mixedInputEnabled, !self.didExperienceSegmentEdition,
              self.composingText.isAtEndIndex,
              let reading = self.mixedInput.japaneseReadingComposingText(matching: self.composingText),
              // 読み直しても英字が残るなら英語として打った語 (window → うぃんどw)。半端な候補は出さない
              !reading.convertTarget.contains(where: { $0.isASCII && $0.isLetter }) else {
            return []
        }
        let result = self.kanaKanjiConverter.requestCandidates(
            reading,
            options: options(
                leftSideContext: leftSideContext,
                rightSideContext: nil,
                requestRichCandidates: false,
                requireJapanesePrediction: .disabled,
                requireEnglishPrediction: .disabled
            )
        )
        let wholeCount: ComposingCount = .inputCount(self.composingText.input.count)
        var candidates = result.mainResults
            .filter { reading.isWholeComposingText(composingCount: $0.composingCount) }
            .prefix(Self.japaneseReadingCandidateCount)
            .map { candidate in
                var candidate = candidate
                candidate.composingCount = wholeCount
                return candidate
            }
        // カタカナ語は辞書に無くても選べるようにする (F7 と同じ形の候補)
        let kana = reading.convertTarget
        if !candidates.contains(where: { $0.text == kana.toKatakana() }) {
            candidates.append(Candidate(
                text: kana.toKatakana(),
                value: 0,
                composingCount: wholeCount,
                lastMid: 0,
                data: [DicdataElement(
                    word: kana.toKatakana(),
                    ruby: kana.toKatakana(),
                    cid: CIDData.固有名詞.cid,
                    mid: MIDData.一般.mid,
                    value: 0
                )]
            ))
        }
        return candidates
    }

    /// - note: 画面更新との整合性を保つため、この関数の実行前に左文脈を取得し、これを引数として与える
    @MainActor public func prefixCandidateCommited(_ candidate: Candidate, leftSideContext: String) {
        let commitStart = ContinuousClock.now
        defer {
            Self.logMixedInput(
                "commit total=\(Self.milliseconds(from: commitStart, to: .now))ms"
            )
        }
        let learnStart = ContinuousClock.now
        self.kanaKanjiConverter.setCompletedData(candidate)
        self.kanaKanjiConverter.updateLearningData(candidate)
        Self.logMixedInput(
            "learn=\(Self.milliseconds(from: learnStart, to: .now))ms"
        )
        self.composingText.prefixComplete(composingCount: candidate.composingCount)
        // 確定した分だけ composingText が短くなるので、生入力を合わせ直す
        if !self.mixedInput.resync(with: self.composingText, partial: true) {
            self.mixedInput.reset()
        }

        if !self.composingText.isEmpty {
            // カーソルを右端に移動する
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            self.didExperienceSegmentEdition = false
            self.shouldShowCandidateWindow = true
            self.selectionIndex = nil
            self.updateRawCandidate(requestRichCandidates: true, forcedLeftSideContext: leftSideContext + candidate.text)
        }
    }

    public enum CandidateWindow: Sendable {
        case hidden
        case composing([Candidate], selectionIndex: Int?)
        case selecting([Candidate], selectionIndex: Int?)
    }

    public func requestSetCandidateWindowState(visible: Bool) {
        self.shouldShowCandidateWindow = visible
    }

    public func requestDebugWindowMode(enabled: Bool) {
        self.shouldShowDebugCandidateWindow = enabled
    }

    @MainActor
    public func requestSelectingNextCandidate() {
        self.isFixingAdditionalCandidateTop = false
        self.selectionIndex = (self.selectionIndex ?? -1) + 1
    }

    @MainActor
    public func requestSelectingPrevCandidate() {
        let selectionIndex = self.selectionIndex ?? 0

        if self.isFixingAdditionalCandidateTop && self.isShowingAdditionalCandidates {
            if self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
                self.showingAdditionalCandidateCount += 1
            }
            self.selectionIndex = 0
            return
        }

        if selectionIndex == 0, !self.isShowingAdditionalCandidates {
            self.showAdditionalCandidatesIfNeeded()
            let additionalCount = self.candidateOffsetByAdditionalCandidates
            if additionalCount > 0 {
                self.isFixingAdditionalCandidateTop = true
                self.selectionIndex = 0
                return
            }
        }
        if selectionIndex == 0, self.isShowingAdditionalCandidates, self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
            self.isFixingAdditionalCandidateTop = true
            self.showingAdditionalCandidateCount += 1
            self.selectionIndex = 0
            return
        }
        self.selectionIndex = max(0, selectionIndex - 1)
    }

    public func requestSelectingRow(_ index: Int) {
        if self.isFixingAdditionalCandidateTop, index != 0 {
            self.isFixingAdditionalCandidateTop = false
        }
        self.selectionIndex = max(0, index)
    }

    public func requestSelectingSuggestionRow(_ row: Int) {
        suggestSelectionIndex = row
    }

    public func stopSuggestionSelection() {
        self.selectionIndex = nil
    }

    public func requestResettingSelection() {
        self.selectionIndex = nil
        self.isFixingAdditionalCandidateTop = false
        self.resetAdditionalCandidates()
    }

    public var selectedCandidate: Candidate? {
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            return candidates[selectionIndex]
        }
        return nil
    }

    public func getCurrentCandidateWindow(inputState: InputState) -> CandidateWindow {
        switch inputState {
        case .none, .previewing, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            return .hidden
        case .composing:
            if !self.liveConversionEnabled, let firstCandidate = self.rawCandidates?.mainResults.first {
                return .composing([firstCandidate], selectionIndex: 0)
            } else {
                return .hidden
            }
        case .selecting:
            if self.shouldShowDebugCandidateWindow {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, debugCandidates.count - 1))
                return .selecting(debugCandidates, selectionIndex: self.selectionIndex)
            } else if self.shouldShowCandidateWindow, let candidates, !candidates.isEmpty {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, candidates.count - 1))
                return .selecting(candidates, selectionIndex: self.selectionIndex)
            } else {
                return .hidden
            }
        }
    }

    public struct MarkedText: Sendable, Equatable, Hashable, Sequence {
        public enum FocusState: Sendable, Equatable, Hashable {
            case focused
            case unfocused
            case none
        }

        public struct Element: Sendable, Equatable, Hashable {
            public var content: String
            public var focus: FocusState
        }
        var text: [Element]

        public var selectionRange: NSRange

        public init(text: [Element], selectionRange: NSRange) {
            self.text = text
            self.selectionRange = selectionRange
        }

        public func makeIterator() -> Array<Element>.Iterator {
            text.makeIterator()
        }

        var isEmpty: Bool {
            self.text.isEmpty
        }
    }

    @MainActor
    public func getModifiedRubyCandidate(inputState: InputState, _ transform: (String) -> String) -> Candidate {
        let (ruby, composingCount): (String, ComposingCount) = switch inputState {
        case .selecting:
            if let selectedRuby = selectedCandidate?.data.map({ $0.ruby }).joined() {
                // `selectedCandidate.data` の全ての `ruby` を連結して返す
                (selectedRuby, .surfaceCount(selectedRuby.count))
            } else {
                // 選択範囲なしの場合はconvertTargetを返す
                (self.convertTarget, .inputCount(self.composingText.input.count))
            }
        case .composing, .previewing, .none, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            (self.convertTarget, .inputCount(self.composingText.input.count))
        }
        let candidateText = transform(ruby)
        return Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: ruby,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
    }

    @MainActor
    public func getModifiedRomanCandidate(inputState: InputState = .composing, _ transform: (String) -> String) -> Candidate {
        let targetComposingText: ComposingText
        switch inputState {
        case .selecting:
            targetComposingText = self.composingText.prefixToCursorPosition()
        case .composing, .previewing, .none, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            targetComposingText = self.composingText
        }
        let inputString = targetComposingText.input.map(\.piece).inputString(preferIntention: false)
        let composingCount: ComposingCount = .inputCount(targetComposingText.input.count)
        let candidateText = transform(inputString)
        let candidate = Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: inputString,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
        return candidate
    }

    @MainActor
    private func createAdditionalCandidates() -> [CandidatePresentation] {
        let candidates: [(candidate: Candidate, annotationText: String?)] = [
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0 }, "英数"),
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? $0 }, "全角英数"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? $0 }, "半角カナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana() }, "カタカナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toHiragana() }, "ひらがな")
        ]
        return candidates.map {
            .init(
                candidate: $0.candidate,
                displayContext: .init(annotationText: $0.annotationText)
            )
        }
    }

    @MainActor
    private func showAdditionalCandidatesIfNeeded() {
        if self.isShowingAdditionalCandidates {
            return
        }
        guard !self.convertTarget.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        let candidates = self.createAdditionalCandidates()
        guard !candidates.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        self.additionalCandidates = candidates
        self.isShowingAdditionalCandidates = true
        self.showingAdditionalCandidateCount = 1
    }

    private func resetAdditionalCandidates() {
        self.isShowingAdditionalCandidates = false
        self.additionalCandidates = []
        self.showingAdditionalCandidateCount = 0
        self.isFixingAdditionalCandidateTop = false
    }

    @MainActor
    public func commitMarkedText(inputState: InputState) -> String {
        let markedText = self.getCurrentMarkedText(inputState: inputState)
        let text = markedText.reduce(into: "") {$0.append(contentsOf: $1.content)}
        if let candidate = self.candidates?.first(where: {$0.text == text}) {
            self.prefixCandidateCommited(candidate, leftSideContext: "")
        }
        self.stopComposition()
        return text
    }

    // サジェスト候補を設定するメソッド
    public func setReplaceSuggestions(_ candidates: [Candidate]) {
        self.replaceSuggestions = candidates
        self.suggestSelectionIndex = nil
    }

    // サジェスト候補の選択状態をリセット
    public func resetSuggestionSelection() {
        suggestSelectionIndex = nil
    }

    public func requestTypoCorrectionPredictionCandidates() -> [PredictionCandidate] {
        guard Config.DebugTypoCorrection().value else {
            return []
        }
        guard let backspaceAdjustedPredictionCandidate else {
            return []
        }
        return [backspaceAdjustedPredictionCandidate]
    }

    public static func preferredPredictionCandidates(
        typoCorrectionCandidates: [PredictionCandidate],
        predictionCandidates: [PredictionCandidate]
    ) -> [PredictionCandidate] {
        if !typoCorrectionCandidates.isEmpty {
            return typoCorrectionCandidates
        }
        return predictionCandidates
    }

    public static func shouldPresentTypoCorrectionPredictionCandidate(
        candidateDisplayText: String,
        previousComposingDisplayText: String
    ) -> Bool {
        // 削除前の previousComposingText と同じ表示候補は、訂正候補としては提示しない。
        candidateDisplayText != previousComposingDisplayText
    }

    public func requestPredictionCandidates() -> [PredictionCandidate] {
        guard let candidate = self.firstPredictionCandidate(),
              let prediction = Self.makePredictionCandidate(currentTarget: self.composingText.convertTarget, candidate: candidate) else {
            return []
        }
        return [prediction]
    }

    private func firstPredictionCandidate() -> Candidate? {
        guard Config.DebugPredictiveTyping().value else {
            return nil
        }

        let target = self.composingText.convertTarget
        guard !target.isEmpty else {
            return nil
        }

        guard let rawCandidates else {
            return nil
        }

        return rawCandidates.predictionResults.first {
            Self.makePredictionCandidate(currentTarget: target, candidate: $0) != nil
        }
    }

    static func makePredictionCandidate(
        currentTarget: String,
        candidate: Candidate
    ) -> PredictionCandidate? {
        var matchTarget = currentTarget
        var deleteCount = 0
        if let last = matchTarget.last,
           last.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) {
            matchTarget.removeLast()
            deleteCount = 1
        }
        guard matchTarget.count >= 2 else {
            return nil
        }

        let readingHiragana = candidate.data.map(\.ruby).joined().toHiragana()
        let matchTargetHiragana = matchTarget.toHiragana()
        guard readingHiragana.hasPrefix(matchTargetHiragana) else {
            return nil
        }
        guard matchTargetHiragana.count < readingHiragana.count else {
            return nil
        }

        let appendText = String(readingHiragana.dropFirst(matchTargetHiragana.count))
        guard !appendText.isEmpty else {
            return nil
        }

        return .init(displayText: candidate.text, appendText: appendText, deleteCount: deleteCount)
    }

    @MainActor
    public func acceptPredictionCandidate() {
        if let prediction = self.requestTypoCorrectionPredictionCandidates().first {
            self.acceptTypoCorrectionPredictionCandidate(prediction)
        } else if let candidate = self.firstPredictionCandidate() {
            self.acceptPredictionCandidate(candidate)
        }
    }

    @MainActor
    func acceptPredictionCandidate(_ candidate: Candidate) {
        guard self.kanaKanjiConverter.acceptPredictionCandidate(candidate, composingText: &self.composingText) else {
            return
        }
        self.lastInputStyle = .direct
        self.lastOperation = .insert
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    func acceptTypoCorrectionPredictionCandidate(_ prediction: PredictionCandidate) {
        if prediction.deleteCount > 0 {
            self.deleteBackwardFromCursorPosition(count: prediction.deleteCount)
        }
        if !prediction.appendText.isEmpty {
            self.insertAtCursorPosition(prediction.appendText, inputStyle: .direct)
        }
    }

    private func requestTypoCorrectionCandidates(composingText targetComposingText: ComposingText, inputStyle: InputStyle) -> [String] {
        guard Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights() else {
            return []
        }
        guard !targetComposingText.isEmpty else {
            return []
        }

        let leftSideContext = self.getCleanLeftSideContext(maxCount: ContextLength.conversion) ?? ""
        let typoCandidates = self.kanaKanjiConverter.experimentalRequestTypoCorrection(
            leftSideContext: leftSideContext,
            composingText: targetComposingText,
            options: options(
                leftSideContext: leftSideContext,
                rightSideContext: nil,
                requestRichCandidates: false,
                requireJapanesePrediction: .disabled,
                requireEnglishPrediction: .disabled
            ),
            inputStyle: inputStyle,
            config: .init(
                languageModel: .ngram(.init(prefix: self.downloadedInputN5LMDir.path + "/lm_", n: 5, d: 0.75)),
                beamSize: 16,
                topK: 32,
                nBest: 3
            )
        )

        var seen: Set<String> = []
        return typoCandidates.compactMap { candidate in
            let text = candidate.convertedText.toHiragana()
            guard !text.isEmpty else {
                return nil
            }
            guard seen.insert(text).inserted else {
                return nil
            }
            return text
        }
    }

    private func convertedText(reading: String, leftSideContext: String?) -> String? {
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(reading, inputStyle: .direct)

        let result = self.kanaKanjiConverter.requestCandidates(
            composingText,
            options: options(
                leftSideContext: leftSideContext,
                rightSideContext: nil,
                requestRichCandidates: false,
                requireJapanesePrediction: .disabled,
                requireEnglishPrediction: .disabled
            )
        )
        return result.mainResults.first?.text
    }

    @MainActor
    private func lmBasedBackspaceTypoCorrectionLock(previousComposingText: ComposingText) -> BackspaceTypoCorrectionLock? {
        let typoCorrectionCandidates = self.requestTypoCorrectionCandidates(
            composingText: previousComposingText,
            inputStyle: self.lastInputStyle
        )
        guard let correctedReading = typoCorrectionCandidates.first else {
            return nil
        }

        let correctedDisplayText = self.convertedText(
            reading: correctedReading,
            leftSideContext: self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        ) ?? correctedReading
        let previousComposingDisplayText = self.convertedText(
            reading: previousComposingText.convertTarget,
            leftSideContext: self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        ) ?? previousComposingText.convertTarget
        guard Self.shouldPresentTypoCorrectionPredictionCandidate(
            candidateDisplayText: correctedDisplayText,
            previousComposingDisplayText: previousComposingDisplayText
        ) else {
            return nil
        }

        return .init(displayText: correctedDisplayText, targetReading: correctedReading)
    }

    static func makeBackspaceTypoCorrectionPredictionCandidate(
        currentConvertTarget: String,
        targetReading: String,
        displayText: String
    ) -> PredictionCandidate? {
        let operation = Self.makeSuffixEditOperation(from: currentConvertTarget, to: targetReading)
            ?? Self.makeSuffixEditOperation(from: currentConvertTarget.toHiragana(), to: targetReading)
        guard let operation else {
            return nil
        }
        return .init(displayText: displayText, appendText: operation.appendText, deleteCount: operation.deleteCount)
    }

    private static func makeSuffixEditOperation(from currentText: String, to targetText: String) -> (appendText: String, deleteCount: Int)? {
        let sharedPrefixLength = zip(currentText, targetText).prefix(while: ==).count
        let deleteCount = currentText.count - sharedPrefixLength
        let appendText = String(targetText.dropFirst(sharedPrefixLength))
        guard deleteCount > 0 || !appendText.isEmpty else {
            return nil
        }
        return (appendText, deleteCount)
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func getCurrentMarkedText(inputState: InputState) -> MarkedText {
        switch inputState {
        case .none, .attachDiacritic:
            return MarkedText(text: [], selectionRange: .notFound)
        case .composing:
            let text = if self.lastOperation == .delete {
                // 削除のあとは常にひらがなを示す
                self.composingText.convertTarget
            } else if self.liveConversionEnabled,
                      self.composingText.convertTarget.count > 1,
                      let firstCandidate = self.rawCandidates?.mainResults.first {
                // それ以外の場合、ライブ変換が有効なら
                firstCandidate.text
            } else {
                // それ以外
                self.composingText.convertTarget
            }
            return MarkedText(text: [.init(content: text, focus: .none)], selectionRange: .notFound)
        case .previewing:
            if let fullCandidate = self.rawCandidates?.mainResults.first,
               self.composingText.isWholeComposingText(composingCount: fullCandidate.composingCount) {
                return MarkedText(text: [.init(content: fullCandidate.text, focus: .none)], selectionRange: .notFound)
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .selecting:
            if let candidates, !candidates.isEmpty {
                self.selectionIndex = min(self.selectionIndex ?? 0, candidates.count - 1)
                var afterComposingText = self.composingText
                afterComposingText.prefixComplete(composingCount: candidates[self.selectionIndex!].composingCount)
                return MarkedText(
                    text: [
                        .init(content: candidates[self.selectionIndex!].text, focus: .focused),
                        .init(content: afterComposingText.convertTarget, focus: .unfocused)
                    ],
                    selectionRange: NSRange(location: candidates[self.selectionIndex!].text.count, length: 0)
                )
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .replaceSuggestion:
            // サジェスト候補の選択状態を独立して管理
            if let index = suggestSelectionIndex,
               replaceSuggestions.indices.contains(index) {
                return MarkedText(
                    text: [.init(content: replaceSuggestions[index].text, focus: .focused)],
                    selectionRange: NSRange(location: replaceSuggestions[index].text.count, length: 0)
                )
            } else {
                return MarkedText(
                    text: [.init(content: composingText.convertTarget, focus: .none)],
                    selectionRange: .notFound
                )
            }
        case .unicodeInput(let codePoint):
            // Unicode入力モード: "U+" + コードポイントを表示
            let displayText = "U+" + codePoint
            return MarkedText(
                text: [.init(content: displayText, focus: .none)],
                selectionRange: NSRange(location: displayText.count, length: 0)
            )
        }
    }
}

public protocol SegmentManagerDelegate: AnyObject {
    func getLeftSideContext(maxCount: Int) -> String?
    func getRightSideContext(maxCount: Int) -> String?
}

private extension ComposingText {
    func isWholeComposingText(composingCount: ComposingCount) -> Bool {
        var c = self
        c.prefixComplete(composingCount: composingCount)
        return c.isEmpty
    }
}
