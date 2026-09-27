import Foundation
import Testing

@testable import RomajiSegmenter

/// Tests/.../Resources/golden/ の JSON を読む。
/// golden は自己完結（リポジトリ相対パスを一切読まない）ので、
/// パッケージを別リポジトリへ移してもテストは動く。
enum Golden {
    static func load<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "golden"
        ) else {
            Issue.record("golden/\(name).json が見つかりません")
            throw RomajiSegmenterError.weightsNotFound
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    /// 全テストで共有する重み（4MB の読み込みを毎回やらない）。
    static let weights: Weights = {
        do { return try Weights.bundled() } catch { fatalError("重みを読めません: \(error)") }
    }()
}

/// Python の repr(float) で書かれた値。Double(String) で bit 完全に読み戻せる。
struct F: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = Double(s) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(), debugDescription: "浮動小数として読めません: \(s)")
        }
        value = v
    }
}

struct MetaGolden: Decodable {
    let model: String
    /// 重みのヘッダの切片 (repr の文字列)
    let intercept: String
    let numpy: String
    let sklearn: String
    let seed: Int
}

struct HashGolden: Decodable {
    struct Case: Decodable, Sendable {
        let f: String   // 特徴文字列
        let h: Int32    // murmurhash3_32 (符号付き)
        let i: Int      // abs(h) % 2^20
    }
    let cases: [Case]
    let nFeatures: Int
    let totalFeatureStrings: Int
}

struct FeatureGolden: Decodable {
    struct Case: Decodable, Sendable {
        let text: String
        let i: Int
        let feats: [String]
    }
    let cases: [Case]
    let window: Int
    let cased: Bool
}

struct LogitGolden: Decodable {
    struct Case: Decodable, Sendable {
        let text: String
        let logits: [F]
    }
    let cases: [Case]
    let intercept: F
}

struct SegmentGolden: Decodable {
    struct Entry: Decodable, Sendable {
        let display: String
        let score: F
    }
    struct Case: Decodable, Sendable {
        let text: String
        let kbest: [Entry]
    }
    let cases: [Case]
    let k: Int
}

struct PartialGolden: Decodable {
    struct Case: Decodable, Sendable {
        let text: String
        let displays: [String]
    }
    let cases: [Case]
    let prefixCount: Int
}

struct RomajiGolden: Decodable {
    struct Case: Decodable, Sendable {
        let s: String
        let romaji: Bool
        let partial: Bool
    }
    let cases: [Case]
    let tails: [String]
    let kanaKeyCount: Int
}

struct InputSegmentGolden: Decodable {
    struct Case: Decodable, Sendable {
        let text: String
        let final: String
        let partial: String
    }
    let cases: [Case]
}
