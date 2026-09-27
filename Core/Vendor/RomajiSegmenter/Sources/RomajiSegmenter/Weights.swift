import Foundation

public enum RomajiSegmenterError: Error, CustomStringConvertible {
    case weightsNotFound
    case badWeightFormat(String)
    case nonASCIIInput(String)

    public var description: String {
        switch self {
        case .weightsNotFound:
            "重みファイルが見つかりません"
        case .badWeightFormat(let why):
            "重みファイルの形式が不正です: \(why)"
        case .nonASCIIInput(let s):
            "ASCII 以外の文字が含まれています: \(s)"
        }
    }
}

/// ロジスティック回帰の重み。`Scripts/export_weights.py` が書き出した RSW1 形式を読む。
public struct Weights: Sendable {
    public let coef: [Float]
    public let intercept: Double
    public let window: Int
    public let cased: Bool

    static let magic: [UInt8] = Array("RSW1".utf8)
    static let headerSize = 32

    /// パッケージに同梱された重みを読む。
    ///
    /// ホストアプリが SwiftPM 経由でビルドされていない場合 `Bundle.module` が解決しない
    /// ことがあるため、そのときは `init(url:)` にファイルパスを渡すこと。
    public static func bundled() throws -> Weights {
        guard let url = Bundle.module.url(forResource: "romaji_lr_v6", withExtension: "f32") else {
            throw RomajiSegmenterError.weightsNotFound
        }
        return try Weights(url: url)
    }

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        #if _endian(big)
        fatalError("RSW1 はリトルエンディアン専用です")
        #endif
        guard data.count >= Self.headerSize else {
            throw RomajiSegmenterError.badWeightFormat("短すぎます (\(data.count) バイト)")
        }
        guard Array(data[0 ..< 4]) == Self.magic else {
            throw RomajiSegmenterError.badWeightFormat("magic が RSW1 ではありません")
        }
        let version = Self.readU32(data, 4)
        guard version == 1 else {
            throw RomajiSegmenterError.badWeightFormat("未知の version \(version)")
        }
        let nFeatures = Int(Self.readU32(data, 8))
        self.window = Int(Self.readU32(data, 12))
        self.cased = Self.readU32(data, 16) & 1 == 1
        self.intercept = Double(bitPattern: Self.readU64(data, 24))

        let expected = Self.headerSize + nFeatures * 4
        guard data.count == expected else {
            throw RomajiSegmenterError.badWeightFormat("サイズが合いません (\(data.count) != \(expected))")
        }
        // Data のアライメントは保証されないので Float には bind せず、
        // UInt8 (アライメント 1) として memcpy する
        var coef = [Float](repeating: 0, count: nFeatures)
        coef.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst.bindMemory(to: UInt8.self),
                           from: Self.headerSize ..< expected)
        }
        self.coef = coef
    }

    /// FeatureHasher の n_features。インデックスのマスクにも使う。
    public var featureCount: Int { coef.count }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        let b = data[data.startIndex + offset ..< data.startIndex + offset + 4]
        return b.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
    }

    private static func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        let b = data[data.startIndex + offset ..< data.startIndex + offset + 8]
        return b.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << (8 * $1.offset)) }
    }
}
