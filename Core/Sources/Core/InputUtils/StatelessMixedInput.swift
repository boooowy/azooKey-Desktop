import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import RomajiSegmenter

/// 日英混在入力 (モード切り替えなしで打つ) の状態。
///
/// 打った ASCII をそのまま保持し、1打鍵ごとに区間判定して
/// `ComposingText` を「区間ごとに違う inputStyle」で組み直す。
///
/// - 日本語と判定した区間 → `.roman2kana` (azooKey がかなに変換する)
/// - 英語と判定した区間   → `.direct`     (そのまま通す)
///
/// 1回の `requestCandidates` で変換できるので、Zenzai が文全体を見られる。
///
/// 組み直しは**区間のラベルが変わったときだけ**行う。毎回作り直すと
/// azooKey の追記時の速い経路 (`lastOperation = .insert`) を潰すため。
/// この「組み直した回数」がそのまま、打鍵中のちらつきの指標になる。
struct StatelessMixedInput {
    /// 打った生の ASCII (変換前)
    private(set) var raw: String = ""
    /// 直前の区間判定の結果。ラベルが変わったかの判定に使う
    private(set) var lastSpans: [InputSpan] = []
    /// 組み直した回数 (ちらつきの指標)
    private(set) var rebuildCount: Int = 0
    /// 次の打鍵で必ず組み直すか。
    ///
    /// `resync` のあとは、生入力は合っていても **composingText の各要素の
    /// inputStyle が区間判定と一致している保証がない**。追記だけで済ませると、
    /// 既に入っている要素の style を直せず、英字が1文字残ったままになる。
    private var mustRebuild = false

    private let segmenter: Segmenter?
    /// 日本語区間に使う inputStyle。
    ///
    /// `.roman2kana` を決め打ちにすると、アプリが使っているローマ字テーブルと食い違う。
    /// 実際 azooKey-Desktop の既定テーブルは `-` を `ー` にするが、ライブラリ既定の
    /// `.roman2kana` はしない。呼び出し元から渡されたものを覚えて使う。
    private var japaneseStyle: InputStyle = .roman2kana

    init() {
        // 重みの読み込みに失敗してもIME全体は動かす。この機能だけ無効になる
        self.segmenter = try? Segmenter(weights: Weights.bundled(), lexicon: EnglishLexicon.shared)
    }

    var isAvailable: Bool { segmenter != nil }
    var isEmpty: Bool { raw.isEmpty }
    /// 末尾の区間を英語と判定しているか
    var endsWithEnglish: Bool { lastSpans.last?.label == .english }

    /// `composingText` の入力要素から、打った ASCII を復元する。
    ///
    /// 復元できない要素 (文節区切り、こちらが入れた覚えのない非 ASCII) が
    /// 混じっていたら nil を返す。中途半端に復元すると、それを足がかりに
    /// 区間判定が崩れて英字が残るので、**諦めるほうが安全**。
    static func rawInput(of composingText: ComposingText) -> String? {
        rawInput(of: composingText.input)
    }

    static func rawInput(of input: some Sequence<ComposingText.InputElement>) -> String? {
        var restored = ""
        for element in input {
            guard let character = typedCharacter(of: element.piece) else {
                return nil
            }
            restored.append(character)
        }
        return restored
    }

    /// 入力要素1つぶんの、打った ASCII 文字。復元できなければ nil。
    private static func typedCharacter(of piece: InputPiece) -> Character? {
        let character: Character
        switch piece {
        case .character(let c):
            character = c
        case .key(let intention, let input, _):
            // 通常経路で入った打鍵。ー のように意図が非 ASCII なら打った文字を使う
            character = if let intention, intention.isASCII { intention } else { input }
        case .compositionSeparator:
            // 生入力に対応する文字がない
            return nil
        }
        switch character {
        // japanesePunctuation で置き換えたぶんを打った文字に戻す
        case "。": return "."
        case "、": return ","
        case "・": return "/"
        case "ー": return "-"
        default: return character.isASCII ? character : nil
        }
    }

    /// `composingText` が外から書き換えられたときに、生入力を実態に合わせ直す。
    ///
    /// 部分確定 (prefixComplete) や再アクティブ化で composingText だけが短くなると、
    /// 生入力に前の入力の残りカスが残る。そのまま打ち続けると、残りカスを含めた
    /// 文字列を区間判定してしまい、文頭に英字が1文字残るなどの崩れ方をする。
    ///
    /// 合わせ直せなかったら false。呼び出し側はこの入力を諦めること。
    mutating func resync(with composingText: ComposingText, partial: Bool) -> Bool {
        guard let restored = Self.rawInput(of: composingText) else {
            return false
        }
        guard !restored.isEmpty else {
            reset()
            return true
        }
        guard let segmenter, let spans = try? Self.segment(restored, with: segmenter, partial: partial), !spans.isEmpty else {
            return false
        }
        raw = restored
        lastSpans = spans
        // 既に入っている要素の style は信用できないので、次の打鍵で組み直す
        mustRebuild = true
        return true
    }

    /// 生入力と composingText が食い違っていないか。
    ///
    /// 長さだけでなく中身まで見る。長さが合っていても中身がずれていれば、
    /// その差分がそのまま変な英字として出てくる。
    func isInSync(with composingText: ComposingText) -> Bool {
        Self.rawInput(of: composingText) == raw
    }

    /// 英語と判定した区間を日本語として読み直した ComposingText。
    /// 読み直す区間がない、または生入力が `composingText` と食い違っていれば nil。
    ///
    /// 区間判定は `windou` (うぃんどう) を `[wi] ndou` と判定し、「wiんどう」にしてしまう。
    /// こうなると変換候補にも「ウィンドウ」が出ないので、変換するときの逃げ道として使う。
    ///
    /// 大文字を含む英語区間は読み直さない。`Slack` のように大文字で打った語は
    /// 英語として意図したものとみなす (`splitsDoubleN` と同じ考え方)。
    ///
    /// 変換 (Space) のときは末尾に文節区切りが入っている。生入力と照らし合わせるときは
    /// 除き、読み直した側にも同じ区切りを付ける。
    func japaneseReadingComposingText(matching composingText: ComposingText) -> ComposingText? {
        var input = composingText.input
        let separator = input.last?.piece == .compositionSeparator ? input.removeLast() : nil
        guard Self.rawInput(of: input) == raw else {
            return nil
        }
        let spans = lastSpans.map { span in
            span.label == .english && !span.text.contains(where: \.isUppercase)
                ? InputSpan(label: .japanese, text: span.text)
                : span
        }
        guard spans != lastSpans else {
            return nil
        }
        var reading = Self.composingText(from: spans, japaneseStyle: japaneseStyle)
        if let separator {
            reading.insertAtCursorPosition([separator])
        }
        return reading
    }

    mutating func reset() {
        raw = ""
        lastSpans = []
        rebuildCount = 0
        mustRebuild = false
    }

    /// 打鍵を取り込んだ結果、ComposingText をどうすべきか。
    enum Plan {
        /// 既に打ってあった文字のラベルが変わった → 全部組み直す
        case rebuild(ComposingText)
        /// 変わっていない → 追加分だけ、**その文字自身のラベルに応じた** style で追記する
        ///
        /// ComposingText は入力要素ごとに style を持つので、区間の切れ目は関係なく
        /// 1文字ずつの style さえ合っていれば同じ結果になる。
        case append([(text: String, style: InputStyle)])

        /// ログ用のラベル
        var kindDescription: String {
            switch self {
            case .rebuild: "rebuild"
            case .append: "append"
            }
        }
    }

    /// 文字を追加して、ComposingText の更新方法を決める。
    /// 扱えない入力なら nil を返す (呼び出し側は通常の経路に倒す)。
    mutating func plan(appending string: String, partial: Bool, japaneseStyle: InputStyle = .roman2kana) -> Plan? {
        guard let segmenter, string.allSatisfy(\.isASCII), !string.isEmpty else {
            return nil
        }
        self.japaneseStyle = japaneseStyle
        let oldSpans = lastSpans
        let oldMask = Self.mask(oldSpans)
        raw += string
        guard let spans = try? Self.segment(raw, with: segmenter, partial: partial) else {
            raw.removeLast(string.count)
            return nil
        }
        lastSpans = spans
        let newMask = Self.mask(spans)

        guard !mustRebuild, newMask.count > oldMask.count, newMask.starts(with: oldMask),
              Self.resolvedNPositions(spans) == Self.resolvedNPositions(oldSpans) else {
            // 既に打ってあった文字のラベルが変わった (Slac → Slack など)、
            // 日本語の末尾の n が、英語が続いたことで ん に決まった (takusan → takusanCLI)、
            // あるいは resync 直後で既存要素の style を信用できない
            mustRebuild = false
            rebuildCount += 1
            return .rebuild(Self.composingText(from: spans, japaneseStyle: japaneseStyle))
        }

        // 追加分だけを、ラベルが連続する塊にまとめて追記する
        let rawBytes = Array(raw.utf8)
        var pieces: [(text: String, style: InputStyle)] = []
        var i = oldMask.count
        while i < newMask.count {
            let label = newMask[i]
            var j = i
            while j < newMask.count, newMask[j] == label { j += 1 }
            // raw は ASCII だけなので、1バイト = 1文字で必ず復号できる
            let text = String(bytes: rawBytes[i ..< j], encoding: .utf8) ?? ""
            switch label {
            case .japanese:
                pieces.append((Self.longVowelMarks(text), japaneseStyle))
            case .english:
                pieces.append((text, .direct))
            case .symbol:
                pieces.append((Self.japaneseSymbols(text), .direct))
            }
            i = j
        }
        return .append(pieces)
    }

    /// 削除を取り込んだ結果、ComposingText をどうすべきか。
    enum DeletePlan {
        /// ラベルが変わっていない → composingText を末尾から削るだけでよい。
        /// 組み直すと azooKey 側が変換をやり直すことがあるので、避けられるなら避ける
        case deleteInPlace
        /// 短くなったことで前方のラベルが変わった → 組み直す
        case rebuild(ComposingText)
    }

    /// 末尾から削って、ComposingText の更新方法を決める。
    mutating func deleteBackward(count: Int = 1, partial: Bool) -> DeletePlan {
        let oldMask = Self.mask(lastSpans).dropLast(min(count, raw.utf8.count))
        raw.removeLast(min(count, raw.count))
        // 残る文字のうち、ん に確定していた n の位置
        let oldResolvedN = Self.resolvedNPositions(lastSpans).filter { $0 <= raw.count }
        guard let segmenter, !raw.isEmpty else {
            lastSpans = []
            mustRebuild = false
            return .rebuild(ComposingText())
        }
        let spans = (try? Self.segment(raw, with: segmenter, partial: partial)) ?? []
        lastSpans = spans
        let newMask = Self.mask(spans)
        // 英語を消して日本語の n が末尾に戻ったら (takusanC → takusan)、ん を n に戻すため組み直す
        if !mustRebuild, newMask.elementsEqual(oldMask), Self.resolvedNPositions(spans) == oldResolvedN {
            return .deleteInPlace
        }
        mustRebuild = false
        rebuildCount += 1
        return .rebuild(Self.composingText(from: spans, japaneseStyle: japaneseStyle))
    }

    /// 今の生入力から必ず組み直す (削除のとき。短くなると前方のラベルも変わりうる)。
    mutating func rebuild(partial: Bool) -> ComposingText {
        guard let segmenter, !raw.isEmpty else {
            lastSpans = []
            return ComposingText()
        }
        let spans = (try? Self.segment(raw, with: segmenter, partial: partial)) ?? []
        lastSpans = spans
        mustRebuild = false
        rebuildCount += 1
        return Self.composingText(from: spans, japaneseStyle: japaneseStyle)
    }

    /// 区間判定。モデルの判定を5つだけ補正する。
    ///
    /// - `nn` の間で英語と日本語を区切った判定 (`resegmentIfSplitsDoubleN`)
    /// - 実在しない英単語で区切った判定 (`resegmentingUnknownEnglish`)
    /// - 大文字の英単語に、隣のローマ字まで含めた判定 (`splittingMixedCaseParticles`)
    /// - 日本語にくっついた小文字の助詞を英語にした判定 (`absorbingParticlesIntoJapanese`)
    /// - 英語とスペースで並んだ英単語を日本語にした判定 (`joiningEnglishAcrossSpaces`)
    ///
    /// jev-test の RomajiSegmenter は Python 版と同じ答えを返すことを
    /// golden テストで保証しているので、補正はこちら側で行う。
    static func segment(_ raw: String, with segmenter: Segmenter, partial: Bool) throws -> [InputSpan] {
        let spans = try segmentCorrectingDoubleN(raw, with: segmenter, partial: partial)
        let resegmented = try resegmentingUnknownEnglish(spans, with: segmenter, partial: partial)
        let split = splittingMixedCaseParticles(resegmented, partial: partial)
        return joiningEnglishAcrossSpaces(absorbingParticlesIntoJapanese(split))
    }

    /// 日本語の区間にスペースを挟まずくっついた、小文字の助詞だけの英語の区間を日本語にする。
    ///
    /// `defo-ruto` (デフォルト) は `[de] fo-ruto` と判定される。`de` はシステムの辞書に
    /// あるので `resegmentingUnknownEnglish` では直らず、「deふぉーると」になってしまう。
    /// 助詞と同じ綴りの小文字がローマ字にくっついていて、英語のつもりということはまずない。
    ///
    /// 英語でもよく使う `englishParticles` (to、no など) は対象にしない。
    static func absorbingParticlesIntoJapanese(_ spans: [InputSpan]) -> [InputSpan] {
        func isJapanese(_ index: Int) -> Bool {
            spans.indices.contains(index) && spans[index].label == .japanese
        }
        var changed = false
        let absorbed = spans.enumerated().map { index, span in
            guard span.label == .english,
                  Self.particles.contains(span.text), !Self.englishParticles.contains(span.text),
                  isJapanese(index - 1) || isJapanese(index + 1) else {
                return span
            }
            changed = true
            return InputSpan(label: .japanese, text: span.text)
        }
        return changed ? mergingAdjacentSpans(absorbed) : spans
    }

    /// 英語の隣にスペース1つで並んだ英単語を、日本語と判定していたら英語にする。
    ///
    /// 区間判定はスペースで切った英字の並びを1つずつ、前後を見ずに判定する。
    /// `Thank you for help` の `you` はローマ字 (よう) としても読めるので日本語になり、
    /// 変換で「用」になってしまう。日本語の文で単語の間にスペースを打つことはまずないので、
    /// スペースで英語とつながった実在の英単語は英語とみなす。
    ///
    /// - 並び全体が日本語の区間1つで、小文字だけの実在の語 (`EnglishLexicon`) だけが対象
    /// - 助詞 (`particles`) は英語にしない (`Slack de meeting` の de は で)。ただし英語でもよく使う
    ///   `englishParticles` は、左が英語で右が英語 (か英語にできる語) のときだけ英語にする
    ///   (`want to go` の to は英語、`Slack no` は の)
    /// - 1文字の語は `a` だけ (打ちかけの `Slack d` を英語にしない)
    /// - 英語にした語がさらに隣を英語にするので、変わらなくなるまで繰り返す
    static func joiningEnglishAcrossSpaces(_ spans: [InputSpan]) -> [InputSpan] {
        guard spans.contains(where: { $0.label == .symbol && $0.text == " " }), !EnglishLexicon.words.isEmpty else {
            return spans
        }
        // 記号を挟まずに続く区間 (英字の並び) と、記号の区間に分ける
        var items: [[InputSpan]] = []
        for span in spans {
            if span.label != .symbol, let last = items.last?.last, last.label != .symbol {
                items[items.count - 1].append(span)
            } else {
                items.append([span])
            }
        }
        func isRun(_ index: Int) -> Bool {
            items.indices.contains(index) && items[index].first?.label != .symbol
        }
        /// スペース1つを挟んで隣にある英字の並び
        func linkedRun(_ index: Int, step: Int) -> [InputSpan]? {
            let separator = index + step
            let neighbor = index + 2 * step
            guard items.indices.contains(separator), items[separator] == [InputSpan(label: .symbol, text: " ")],
                  isRun(neighbor) else {
                return nil
            }
            return items[neighbor]
        }
        /// 英語にしてよい実在の英単語 (助詞は `englishParticles` だけ)。助詞かどうかも返す
        func joinableWord(_ run: [InputSpan]?) -> (text: String, isParticle: Bool)? {
            guard let run, run.count == 1, let span = run.first, span.label == .japanese,
                  !span.text.contains(where: \.isUppercase),
                  span.text.count >= 2 || span.text == "a",
                  !Self.particles.contains(span.text) || Self.englishParticles.contains(span.text),
                  EnglishLexicon.isKnownWord(span.text) else {
                return nil
            }
            return (span.text, Self.particles.contains(span.text))
        }
        var changed = true
        while changed {
            changed = false
            for index in items.indices where isRun(index) {
                guard let word = joinableWord(items[index]) else {
                    continue
                }
                let left = linkedRun(index, step: -1)
                let right = linkedRun(index, step: 1)
                let leftIsEnglish = left?.last?.label == .english
                let rightIsEnglish = right?.first?.label == .english
                let joins = if word.isParticle {
                    // 右がまだ日本語でも、英語にできる語なら英語が続くとみなす (want to go の go)
                    leftIsEnglish && (rightIsEnglish || joinableWord(right).map { !$0.isParticle } == true)
                } else {
                    leftIsEnglish || rightIsEnglish
                }
                if joins {
                    items[index] = [InputSpan(label: .english, text: word.text)]
                    changed = true
                }
            }
        }
        return mergingAdjacentSpans(items.flatMap { $0 })
    }

    /// `nn` の間で英語と日本語を区切った判定を補正する。
    ///
    /// ローマ字入力では「ん」を `nn` で打つことが多いが、区間判定のモデルは
    /// `innsuto-ru` を `[in] nsuto-ru` と判定し、「ｉｎんすとーる」になる。
    /// `nn` + 子音はローマ字の「ん」とみなせるので、`nn` を英語区間と日本語区間に
    /// またがらせた判定 (`splitsDoubleN`) は、その英字の並びを k-best で判定し直し、
    /// この形を含まない最上位の案を使う。
    /// どの案もこの形なら元の判定のままにする。
    static func segmentCorrectingDoubleN(_ raw: String, with segmenter: Segmenter, partial: Bool) throws -> [InputSpan] {
        let spans = try segmenter.segmentInput(raw, partial: partial)
        guard spans.indices.dropLast().contains(where: { splitsDoubleN(spans[$0], spans[$0 + 1]) }) else {
            return spans
        }
        var result: [InputSpan] = []
        var i = 0
        while i < spans.count {
            guard spans[i].label != .symbol else {
                result.append(spans[i])
                i += 1
                continue
            }
            // 記号を挟まずに続く英語・日本語の区間は、segmentInput では1つの英字の並び
            var j = i
            while j < spans.count, spans[j].label != .symbol { j += 1 }
            let run = Array(spans[i ..< j])
            result += try Self.resegmentIfSplitsDoubleN(
                run,
                with: segmenter,
                partial: partial && j == spans.count
            )
            i = j
        }
        return result
    }

    static let doubleNCandidateCount = 8

    static let unknownEnglishCandidateCount = 8
    /// モデルの評価がこれ以上悪い案は選ばない (対数尤度の差)
    static let unknownEnglishScoreMargin = 3.0

    /// 実在しない英単語で区切った判定を、k-best から選び直す。
    ///
    /// 区間判定のモデルは、英単語と日本語の境目を1〜2文字ずらすことが多い。
    ///
    /// - `writetokiroku` → `[writ] etokiroku` (writ絵と記録)
    /// - `Dockerirete` → `[Docke] rirete`、`Macippai` → `[Maci] ppai`
    ///
    /// 正しい境目はたいてい k-best の2〜3番目にある。英語の区間のすぐあとに日本語の区間が続き、
    /// その英語の区間が辞書 (`EnglishLexicon`) にないときだけ、英語の区間がすべて辞書にあり、
    /// 日本語の区間がかなに変換しきれる案に選び直す。
    ///
    /// 英語の区間が辞書にある判定 (`[Zoo] mikou`、`[writ] e` の writ も辞書にある) は、
    /// 正しい判定を崩さないよう手を出さない。辞書がない環境では何もしない。
    static func resegmentingUnknownEnglish(_ spans: [InputSpan], with segmenter: Segmenter, partial: Bool) throws -> [InputSpan] {
        guard spans.indices.dropLast().contains(where: { isUnknownEnglishBeforeJapanese(spans[$0], spans[$0 + 1]) }),
              !EnglishLexicon.words.isEmpty else {
            return spans
        }
        var result: [InputSpan] = []
        var i = 0
        while i < spans.count {
            guard spans[i].label != .symbol else {
                result.append(spans[i])
                i += 1
                continue
            }
            // 記号を挟まずに続く英語・日本語の区間は、segmentInput では1つの英字の並び
            var j = i
            while j < spans.count, spans[j].label != .symbol { j += 1 }
            let run = Array(spans[i ..< j])
            result += try Self.resegmentRunIfUnknownEnglish(run, with: segmenter, partial: partial && j == spans.count)
            i = j
        }
        return result
    }

    private static func resegmentRunIfUnknownEnglish(_ run: [InputSpan], with segmenter: Segmenter, partial: Bool) throws -> [InputSpan] {
        // 辞書にない英語の区間の [始まり, 終わり) (文字の位置)
        var unknownEnglish: [(start: Int, end: Int)] = []
        var offset = 0
        for (index, span) in run.enumerated() {
            let end = offset + span.text.count
            if index + 1 < run.count, isUnknownEnglishBeforeJapanese(span, run[index + 1]) {
                unknownEnglish.append((offset, end))
            }
            offset = end
        }
        guard !unknownEnglish.isEmpty else {
            return run
        }
        let text = run.map(\.text).joined()
        let characters = Array(text)
        let candidates = try segmenter.segmentKBest(text, k: unknownEnglishCandidateCount, partial: partial)
        guard let best = candidates.first else {
            return run
        }
        for candidate in candidates.dropFirst() where candidate.score >= best.score - unknownEnglishScoreMargin {
            let spans = candidate.segments.map {
                InputSpan(label: $0.label == .english ? .english : .japanese, text: $0.text)
            }
            // 辞書にない英語の区間を、伸ばすか、末尾の母音を1文字だけ削る案に限る。
            // それ以上削ると、辞書にない正しい語 (runtime → runt) を崩す
            var candidateEnglish: [Int: Int] = [:]
            var position = 0
            for span in spans {
                if span.label == .english {
                    candidateEnglish[position] = position + span.text.count
                }
                position += span.text.count
            }
            let movesBoundaryReasonably = unknownEnglish.allSatisfy { range in
                candidateEnglish[range.start].map { Self.movesBoundaryReasonably(from: range.end, to: $0, in: characters) } ?? false
            }
            let englishIsKnown = spans.allSatisfy { $0.label != .english || EnglishLexicon.isKnownWord($0.text) }
            // 打ちかけの末尾の日本語は、続きでかなになるかもしれないので問わない
            let japaneseIsComplete = spans.enumerated().allSatisfy { index, span in
                span.label != .japanese || (partial && index == spans.count - 1) || isCompleteRomaji(span.text)
            }
            let splitsDoubleN = spans.indices.dropLast().contains { Self.splitsDoubleN(spans[$0], spans[$0 + 1]) }
            if movesBoundaryReasonably && englishIsKnown && japaneseIsComplete && !splitsDoubleN {
                return spans
            }
        }
        return run
    }

    /// 辞書にない英語の区間の終わりを `from` から `to` に動かしてよいか。
    ///
    /// 伸ばすのはよい。削ってよいのは1文字だけで、末尾の母音 (Maci → Mac) か、
    /// 略語のあとの小文字 (AWSb → AWS + benkyou) に限る。それ以上削ると、辞書にない正しい語を
    /// 辞書にある短い語まで削る (runtime → runt)。
    private static func movesBoundaryReasonably(from end: Int, to newEnd: Int, in characters: [Character]) -> Bool {
        guard newEnd < end else {
            return newEnd > end
        }
        guard newEnd == end - 1 else {
            return false
        }
        let removed = characters[newEnd]
        // 直前と同じ母音 (freee の ee) は英語の綴りの一部なので削らない
        let isTrailingVowel = "aiueo".contains(removed) && characters[newEnd - 1] != removed
        let isLetterAfterAcronym = removed.isLowercase && newEnd >= 2
            && characters[newEnd - 1].isUppercase && characters[newEnd - 2].isUppercase
        return isTrailingVowel || isLetterAfterAcronym
    }

    /// 英語の区間のすぐあとに日本語の区間が続き、その英語の区間が辞書にない
    private static func isUnknownEnglishBeforeJapanese(_ left: InputSpan, _ right: InputSpan) -> Bool {
        left.label == .english && right.label == .japanese && !EnglishLexicon.isKnownWord(left.text)
    }

    /// ローマ字としてかなに変換しきれるか (`-` は ー とみなす)
    private static func isCompleteRomaji(_ text: String) -> Bool {
        guard text.allSatisfy({ ($0.isASCII && $0.isLowercase) || $0 == "-" }) else {
            return false
        }
        var composing = ComposingText()
        composing.insertAtCursorPosition(longVowelMarks(text), inputStyle: .roman2kana)
        return !composing.convertTarget.contains(where: { $0.isASCII && $0.isLetter })
    }

    /// 大文字の英単語に、隣のローマ字まで含めた英語区間を分け直す。
    ///
    /// 区間判定のモデルは、大文字の英単語の前後のローマ字を英語に含めることがある。
    ///
    /// - `OKnanode` → `[OKna] node` (OKnaので)。大文字が2文字以上続いたあとの小文字 `na`
    /// - `nodeCommit` → `no [deCommit]` (のdeCommit)。大文字で始まる単語の直前の小文字 `de`
    ///
    /// 大文字は英語として打った印なので、大文字と小文字の境目で区切り、
    /// 小文字の側がローマ字としてかなに変換しきれるなら日本語にする。
    /// 次のものは英語のまま残す。
    ///
    /// - かなに変換しきれないもの: `URLs` の `s`、`macOS` の `mac`
    /// - 1文字だけのもの: `iPhone` の `i`、`eBay` の `e`
    /// - 直後が大文字だけの語のもの: `reCAPTCHA` の `re`
    ///
    /// 打ちかけ (`partial`) の末尾は、続きでかなに変換しきれるか分からないので対象外。
    static func splittingMixedCaseParticles(_ spans: [InputSpan], partial: Bool) -> [InputSpan] {
        var result: [InputSpan] = []
        for (index, span) in spans.enumerated() {
            guard span.label == .english, span.text.contains(where: \.isUppercase) else {
                result.append(span)
                continue
            }
            let isLast = index == spans.count - 1
            let followsJapanese = index > 0 && spans[index - 1].label == .japanese
            let pieces = Self.splittingInnerParticles(span.text)
            for (pieceIndex, piece) in pieces.enumerated() {
                guard piece.label == .english else {
                    result.append(piece)
                    continue
                }
                // 打ちかけの末尾は、続きでかなに変換しきれるか分からないので対象外
                let allowsSuffix = !(partial && isLast && pieceIndex == pieces.count - 1)
                result += Self.splittingEdgeParticles(
                    piece.text,
                    followsJapanese: followsJapanese && pieceIndex == 0,
                    allowsSuffix: allowsSuffix
                )
            }
        }
        return Self.mergingAdjacentSpans(result)
    }

    /// 英単語どうしに挟まれた助詞を日本語にする: GitHub|de|PR、OK|nanode|Commit、ChatGPT|ya|Codex
    ///
    /// 小文字 → 大文字の境目の直前にある小文字の並びから、助詞 (`particles`) で、その左が実在の語に
    /// なる最も短い並びを選ぶ。短い順に試すのは、`VSCodedeTypeScript` で `VSC|odede` でなく
    /// `VSCode|de` を選ぶため。
    ///
    /// 助詞に限るのは、辞書 (/usr/share/dict/words) が ne や hob のような短い語まで含み、
    /// 「左が実在の語か」だけでは `Ne|ro|AG`、`Hob|ie|Cat` のように英単語を割ってしまうため。
    /// 英単語どうしを日本語でつなぐのは、ほぼ助詞に限られる。
    static func splittingInnerParticles(_ text: String) -> [InputSpan] {
        let characters = Array(text)
        var pieces: [InputSpan] = []
        var pieceStart = 0
        for index in characters.indices.dropFirst() where characters[index].isUppercase && characters[index - 1].isLowercase {
            var runStart = index
            while runStart > pieceStart, characters[runStart - 1].isLowercase {
                runStart -= 1
            }
            guard index - runStart >= 2 else {
                continue
            }
            for length in 2 ... (index - runStart) {
                let particleStart = index - length
                let left = String(characters[pieceStart ..< particleStart])
                let particle = characters[particleStart ..< index]
                if !left.isEmpty, Self.particles.contains(String(particle)), EnglishLexicon.isKnownWord(left) {
                    pieces.append(InputSpan(label: .english, text: left))
                    pieces.append(InputSpan(label: .japanese, text: String(particle)))
                    pieceStart = index
                    break
                }
            }
        }
        pieces.append(InputSpan(label: .english, text: String(characters[pieceStart...])))
        return pieces
    }

    /// 英単語どうしをつなぐ日本語の助詞 (ローマ字。ヘボン式と訓令式)。
    /// 文法で決まった少数の語で、入力の例に合わせて増やすものではない
    /// 助詞のうち、英語でもよく使う語。英語に挟まれていれば英語とみなす (`joiningEnglishAcrossSpaces`)
    static let englishParticles: Set<String> = ["to", "no", "he", "made"]

    static let particles: Set<String> = [
        "no", "to", "ya", "de", "ni", "wo", "ga", "ha", "wa", "mo", "he",
        "kara", "made", "yori", "node", "nanode", "toka", "dake", "tte",
        "deha", "dewa", "niha", "niwa", "demo", "nimo", "tomo", "toha", "towa"
    ]

    /// 英単語の先頭・末尾の小文字を日本語にする: de|Commit、OK|na、(takusa)n|CLI
    private static func splittingEdgeParticles(_ word: String, followsJapanese: Bool, allowsSuffix: Bool) -> [InputSpan] {
        var text = Substring(word)
        var pieces: [InputSpan] = []
        // 大文字で始まる単語の直前の小文字: de|Commit
        if let upper = text.firstIndex(where: \.isUppercase), upper != text.startIndex {
            let prefix = text[..<upper]
            let rest = text[upper...]
            let isCapitalizedWord = rest.dropFirst().first?.isLowercase ?? false
            // 日本語のすぐあとの n / nn は、前の日本語の ん (takusann|CLI を takusa|nnCLI と判定したもの)。
            // 大文字の略語の前でも分ける。n で始まり大文字が続く英単語はまずない
            let isSyllabicN = followsJapanese && prefix.count <= 2 && prefix.allSatisfy { $0 == "n" }
            if isSyllabicN || (isCapitalizedWord && Self.isParticleRomaji(prefix)) {
                pieces.append(InputSpan(label: .japanese, text: String(prefix)))
                text = rest
            }
        }
        // 大文字が2文字以上続いたあとの小文字: OK|na
        var suffix: InputSpan?
        if allowsSuffix, let lastUpper = text.lastIndex(where: \.isUppercase) {
            let head = text[...lastUpper]
            let tail = text[text.index(after: lastUpper)...]
            let upperRun = head.reversed().prefix(while: \.isUppercase).count
            // 最後の大文字から始まる部分が4文字以上の実在の語 (VSCode の Code) なら、略語 + 単語なので分けない
            let capitalizedWord = String(text[lastUpper...])
            let isWordAfterAcronym = capitalizedWord.count >= 4 && EnglishLexicon.isKnownWord(capitalizedWord)
            if upperRun >= 2, !isWordAfterAcronym, Self.isParticleRomaji(tail) {
                suffix = InputSpan(label: .japanese, text: String(tail))
                text = head
            }
        }
        pieces.append(InputSpan(label: .english, text: String(text)))
        if let suffix {
            pieces.append(suffix)
        }
        return pieces
    }

    /// 2文字以上で、ローマ字としてかなに変換しきれる小文字の並びか
    private static func isParticleRomaji(_ text: Substring) -> Bool {
        guard text.count >= 2, text.allSatisfy({ $0.isASCII && $0.isLowercase }) else {
            return false
        }
        var composing = ComposingText()
        composing.insertAtCursorPosition(String(text), inputStyle: .roman2kana)
        return !composing.convertTarget.contains(where: { $0.isASCII && $0.isLetter })
    }

    /// 同じラベルが続く区間をまとめる
    private static func mergingAdjacentSpans(_ spans: [InputSpan]) -> [InputSpan] {
        var merged: [InputSpan] = []
        for span in spans {
            if let last = merged.last, last.label == span.label {
                merged[merged.count - 1] = InputSpan(label: last.label, text: last.text + span.text)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private static func resegmentIfSplitsDoubleN(_ run: [InputSpan], with segmenter: Segmenter, partial: Bool) throws -> [InputSpan] {
        guard run.indices.dropLast().contains(where: { splitsDoubleN(run[$0], run[$0 + 1]) }) else {
            return run
        }
        let text = run.map(\.text).joined()
        let candidates = try segmenter.segmentKBest(text, k: doubleNCandidateCount, partial: partial)
        for candidate in candidates {
            let spans = candidate.segments.map {
                InputSpan(label: $0.label == .english ? .english : .japanese, text: $0.text)
            }
            if !spans.indices.dropLast().contains(where: { splitsDoubleN(spans[$0], spans[$0 + 1]) }) {
                return spans
            }
        }
        return run
    }

    /// `nn` (「ん」) を英語区間と日本語区間にまたがらせる判定か。
    ///
    /// - `[in] nsuto`: `nn` の間で区切り、日本語区間が `n` + 子音 (「ん」) で始まる
    /// - `[inn] suto`: 英語区間が `nn` で終わり、日本語区間が子音で始まる
    ///
    /// `n` の直後が母音・`y` (な行・にゃ行) や、打ちかけで `n` だけのときは対象外。
    /// `Amazonno` (Amazonの) や、`Amazon` のあとに `na` を打ちかけた `Amazonn` を崩さないため。
    ///
    /// 大文字を含む英語区間も対象外。`Glennsan` (Glennさん) や `Annsan` のように、
    /// 大文字で打った名前は英語として意図したものとみなす。
    static func splitsDoubleN(_ left: InputSpan, _ right: InputSpan) -> Bool {
        guard left.label == .english, right.label == .japanese,
              !left.text.contains(where: \.isUppercase) else {
            return false
        }
        let tail = Array(left.text.lowercased().suffix(2))
        let head = Array(right.text.lowercased().prefix(2))
        guard tail.last == "n", let first = head.first else {
            return false
        }
        if first == "n" {
            return head.count == 2 && isConsonant(head[1])
        }
        return tail == ["n", "n"] && isConsonant(first)
    }

    private static func isConsonant(_ character: Character) -> Bool {
        character.isLetter && !"aiueoy".contains(character)
    }

    static func mask(_ spans: [InputSpan]) -> [InputLabel] {
        spans.flatMap { span in [InputLabel](repeating: span.label, count: span.text.utf8.count) }
    }

    /// 区間の並びから ComposingText を作る。
    ///
    /// 日本語の区間のあとに別の区間が続き、日本語の区間が `n` 1つで終わるときは、その `n` を ん にする
    /// (`resolvedNPositions`)。ローマ字の `n` は次の文字を見るまで ん か な行か決まらないが、英字や記号が
    /// 続いた時点で ん に決まる。そのままだと `takusanCLI` が「たくさnCLI」になる。
    /// 打った文字 (`n`) を `rawInput(of:)` で復元できるよう、意図を ん、入力を n としたキーで入れる。
    static func composingText(from spans: [InputSpan], japaneseStyle: InputStyle = .roman2kana) -> ComposingText {
        var composing = ComposingText()
        var position = 0
        let resolvedN = Self.resolvedNPositions(spans)
        for span in spans {
            position += span.text.count
            switch span.label {
            case .japanese where resolvedN.contains(position):
                composing.insertAtCursorPosition(Self.longVowelMarks(String(span.text.dropLast())), inputStyle: japaneseStyle)
                composing.insertAtCursorPosition([
                    ComposingText.InputElement(piece: .key(intention: "ん", input: "n", modifiers: []), inputStyle: japaneseStyle)
                ])
            case .japanese:
                composing.insertAtCursorPosition(Self.longVowelMarks(span.text), inputStyle: japaneseStyle)
            case .english:
                composing.insertAtCursorPosition(span.text, inputStyle: .direct)
            case .symbol:
                composing.insertAtCursorPosition(japaneseSymbols(span.text), inputStyle: .direct)
            }
        }
        return composing
    }

    /// 日本語の区間の末尾の `n` を ん に決める位置 (その区間の終わりの、文字の位置)。
    ///
    /// 日本語の区間のあとに別の区間が続き、区間の末尾の `n` の並びが奇数個 (`n`、`nnn`) のとき。
    /// 偶数個 (`nn`) ならローマ字の変換だけで ん になっている。
    static func resolvedNPositions(_ spans: [InputSpan]) -> Set<Int> {
        var positions: Set<Int> = []
        var position = 0
        for (index, span) in spans.enumerated() {
            position += span.text.count
            let trailingN = span.text.reversed().prefix(while: { $0 == "n" }).count
            if span.label == .japanese, index + 1 < spans.count, trailingN % 2 == 1 {
                positions.insert(position)
            }
        }
        return positions
    }

    /// 日本語区間の `-` を長音記号 `ー` にする。
    ///
    /// azooKey のローマ字テーブルは `-` をそのまま通す (`.roman2kana` も
    /// `.mapped(id: .defaultRomanToKana)` も実測で変換しない) ので、
    /// jev_classify の `_KANA["-"] == "ー"` と同じことを自前でやる。
    /// 英語区間の `-` はハイフンのままにしたいので、日本語区間にだけ効かせる。
    static func longVowelMarks(_ text: String) -> String {
        text.contains("-") ? String(text.map { $0 == "-" ? "ー" : $0 }) : text
    }

    /// 記号区間の `.` `,` `/` を `。` `、` `・` にする。
    ///
    /// azooKey の既定ローマ字テーブルは記号を一切扱わない
    /// (`defaultRoman2Kana` に `。` `、` `・` `ー` のいずれも無い、実測) ので、
    /// ここで自前で置き換える。
    ///
    /// **文脈は見ない。** 行頭の `・` で箇条書きを書いたり、`。` を単体で打ったり
    /// したいのに直前の文脈を要求されると使えないため (Google 日本語入力も見ない)。
    /// チャンク内のすべての文字が対象。
    ///
    /// 代償として `.` `,` `/` そのものが打てなくなる (`example.com` → `example。com`)。
    /// 半角で打ちたいときは変換候補から選ぶか、英数入力に切り替える。
    static func japaneseSymbols(_ text: String) -> String {
        guard text.contains(where: { $0 == "." || $0 == "," || $0 == "/" }) else {
            return text
        }
        return String(text.map { character in
            switch character {
            case ".": "。"
            case ",": "、"
            case "/": "・"
            default: character
            }
        })
    }
}
