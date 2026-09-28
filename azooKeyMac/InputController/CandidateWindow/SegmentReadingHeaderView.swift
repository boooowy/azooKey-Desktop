import Cocoa
import Core

/// 候補ウィンドウの見出し。Shift+←/→ で区切りを動かしているときに、
/// 読みのどこまでを変換しているかを示す。
///
/// マークテキストは変換後の漢字になっていて、読みのどこまでが対象かが分からない。
/// またアプリによっては、変換中の文節と残りの違いが下線の太さしか出ない。
/// 候補ウィンドウは IME が自分で描いているので、どのアプリでも同じように見える。
///
///     ┌──────────────────────────────────────┐
///     │ (きょうのてんきは) はれです   ⇧↔ 区切り │
///     ├──────────────────────────────────────┤
///     │ 1. 今日の天気は                        │
final class SegmentReadingHeaderView: NSView {
    static let height: CGFloat = 34

    private static let fontSize: CGFloat = 13
    private static let hintFontSize: CGFloat = 11
    private static let horizontalInset: CGFloat = 12
    private static let capsuleHorizontalPadding: CGFloat = 8
    private static let capsuleVerticalPadding: CGFloat = 3
    private static let spacing: CGFloat = 6
    /// 読みが長いときも、ウィンドウがこれ以上広がらないようにする (残りの読みを省略する)
    private static let maxWidth: CGFloat = 520

    private let capsuleView = AccentCapsuleView()
    private let targetLabel = NSTextField(labelWithString: "")
    private let restLabel = NSTextField(labelWithString: "")
    private let hintView = SegmentReadingHeaderView.makeHint()
    private let separator = NSBox()

    init() {
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false

        // 変換している文節の読み: アクセントカラーのカプセルに太字で。省略しない
        self.targetLabel.font = .systemFont(ofSize: Self.fontSize, weight: .semibold)
        self.targetLabel.textColor = .controlAccentColor
        self.targetLabel.lineBreakMode = .byClipping
        self.targetLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // 残りの読み: 控えめな色で。長ければ末尾から省略する
        self.restLabel.font = .systemFont(ofSize: Self.fontSize)
        self.restLabel.textColor = .secondaryLabelColor
        self.restLabel.lineBreakMode = .byTruncatingTail
        self.restLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 操作のヒント: まだ慣れていない操作を、その場で思い出せるように
        self.hintView.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.hintView.setContentHuggingPriority(.required, for: .horizontal)

        self.separator.boxType = .separator

        for view in [self.capsuleView, self.targetLabel, self.restLabel, self.hintView, self.separator] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        self.capsuleView.addSubview(self.targetLabel)
        self.addSubview(self.capsuleView)
        self.addSubview(self.restLabel)
        self.addSubview(self.hintView)
        self.addSubview(self.separator)

        NSLayoutConstraint.activate([
            self.targetLabel.leadingAnchor.constraint(equalTo: self.capsuleView.leadingAnchor, constant: Self.capsuleHorizontalPadding),
            self.targetLabel.trailingAnchor.constraint(equalTo: self.capsuleView.trailingAnchor, constant: -Self.capsuleHorizontalPadding),
            self.targetLabel.topAnchor.constraint(equalTo: self.capsuleView.topAnchor, constant: Self.capsuleVerticalPadding),
            self.targetLabel.bottomAnchor.constraint(equalTo: self.capsuleView.bottomAnchor, constant: -Self.capsuleVerticalPadding),

            self.capsuleView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: Self.horizontalInset),
            self.capsuleView.centerYAnchor.constraint(equalTo: self.centerYAnchor),

            self.restLabel.leadingAnchor.constraint(equalTo: self.capsuleView.trailingAnchor, constant: Self.spacing),
            self.restLabel.firstBaselineAnchor.constraint(equalTo: self.targetLabel.firstBaselineAnchor),
            self.restLabel.trailingAnchor.constraint(lessThanOrEqualTo: self.hintView.leadingAnchor, constant: -Self.spacing * 2),

            self.hintView.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -Self.horizontalInset),
            self.hintView.centerYAnchor.constraint(equalTo: self.centerYAnchor),

            self.separator.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.separator.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.separator.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ reading: ConverterSegmentReading) {
        self.targetLabel.stringValue = reading.target
        self.restLabel.stringValue = reading.rest
    }

    /// 省略せずに出すのに必要な幅 (上限つき)
    var preferredWidth: CGFloat {
        let width = Self.horizontalInset
            + self.targetLabel.intrinsicContentSize.width + Self.capsuleHorizontalPadding * 2
            + Self.spacing
            + self.restLabel.intrinsicContentSize.width
            + Self.spacing * 2
            + self.hintView.fittingSize.width
            + Self.horizontalInset
        return min(width, Self.maxWidth)
    }

    /// 「⇧ ↔ 区切り」。記号は SF Symbols にして、文字だけより締まった見た目にする。
    /// 色は `contentTintColor` / `textColor` にセマンティックカラーを渡し、ライト / ダークに追従させる
    private static func makeHint() -> NSStackView {
        let color = NSColor.tertiaryLabelColor
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.hintFontSize, weight: .medium)
        let symbols: [NSView] = ["shift", "arrow.left.and.right"].compactMap { name in
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration) else {
                return nil
            }
            let imageView = NSImageView(image: image)
            imageView.contentTintColor = color
            return imageView
        }
        let label = NSTextField(labelWithString: "区切り")
        label.font = .systemFont(ofSize: Self.hintFontSize, weight: .medium)
        label.textColor = color

        let stack = NSStackView(views: symbols + [label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.setCustomSpacing(4, after: symbols.last ?? label)
        return stack
    }
}

/// アクセントカラーを薄く塗った角丸のカプセル。
/// ライト / ダークやアクセントカラーの変更に追従するよう、描くたびに色を解決する。
private final class AccentCapsuleView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        self.layer?.cornerRadius = 6
        self.layer?.backgroundColor = SegmentHighlight.backgroundColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.needsDisplay = true
    }
}

/// 「いま変換している文節」を示す色。候補ウィンドウの見出しとマークテキストで揃える。
enum SegmentHighlight {
    static var backgroundColor: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.18)
    }
}
