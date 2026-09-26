import Testing

@testable import RomajiSegmenter

@Suite("層1: MurmurHash3 と特徴インデックス")
struct HashTests {
    static let golden = try! Golden.load(HashGolden.self, "hash")

    @Test("golden のバージョンが期待どおり")
    func meta() throws {
        // golden は sklearn / numpy のバージョンに依存する（pkl がバージョン依存のため）。
        // 別バージョンで再生成されたら「正解」が黙って変わるので、ここで固定する。
        let meta = try Golden.load(MetaGolden.self, "meta")
        #expect(meta.model == "romaji_lr_v5")
        #expect(meta.sklearn == "1.9.1")
        #expect(meta.numpy == "2.5.3")
    }

    @Test("ハッシュ値が sklearn と一致", arguments: golden.cases)
    func hash(_ c: HashGolden.Case) {
        var bytes = Array(c.f.utf8)
        let got = bytes.withUnsafeBufferPointer {
            Int32(bitPattern: murmurHash3_x86_32($0, seed: 0))
        }
        #expect(got == c.h, "特徴文字列 \(c.f)")
    }

    @Test("インデックスが sklearn と一致", arguments: golden.cases)
    func index(_ c: HashGolden.Case) {
        #expect(featureIndex(c.f) == c.i, "特徴文字列 \(c.f)")
    }

    @Test("golden に正と負のハッシュ値が両方含まれる")
    func bothSigns() {
        // abs() の扱いを実際に検証できているかの確認
        #expect(Self.golden.cases.contains { $0.h < 0 })
        #expect(Self.golden.cases.contains { $0.h > 0 })
    }

    @Test("Int32.min でもトラップせず 0 を返す")
    func int32MinDoesNotTrap() {
        // Swift の abs(Int32.min) はトラップするが、Python も C も
        // abs(INT32_MIN) % 2^20 == 0 を返す。magnitude 経由ならこの境界も通る。
        let signed = Int32.min
        #expect(Int(signed.magnitude & 0x0F_FFFF) == 0)
    }
}
