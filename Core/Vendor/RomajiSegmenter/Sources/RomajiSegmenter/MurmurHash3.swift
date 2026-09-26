// sklearn の FeatureHasher と同じハッシュ。
// sklearn は murmurhash3_bytes_s32(bytes, seed=0) の結果 (符号付き int32) の絶対値を
// n_features で割った余りを列インデックスにする (_hashing_fast.pyx)。

/// MurmurHash3 x86 32bit (Austin Appleby)。戻り値は符号なしだが、
/// sklearn と揃えるため利用側で Int32 のビットパターンとして解釈する。
@inlinable
public func murmurHash3_x86_32(_ bytes: UnsafeBufferPointer<UInt8>, seed: UInt32 = 0) -> UInt32 {
    let c1: UInt32 = 0xcc9e_2d51
    let c2: UInt32 = 0x1b87_3593
    let length = bytes.count
    var h1 = seed

    // 4 バイトブロック。アライメントに依存しないよう、バイトから明示的に
    // リトルエンディアンで組む
    let blockCount = length / 4
    for i in 0 ..< blockCount {
        let o = i * 4
        var k1 = UInt32(bytes[o])
            | (UInt32(bytes[o + 1]) << 8)
            | (UInt32(bytes[o + 2]) << 16)
            | (UInt32(bytes[o + 3]) << 24)
        k1 = k1 &* c1
        k1 = (k1 << 15) | (k1 >> 17)
        k1 = k1 &* c2
        h1 ^= k1
        h1 = (h1 << 13) | (h1 >> 19)
        h1 = h1 &* 5 &+ 0xe654_6b64
    }

    // 端数 (3/2/1 バイト)
    var k1: UInt32 = 0
    let tail = blockCount * 4
    switch length & 3 {
    case 3:
        k1 ^= UInt32(bytes[tail + 2]) << 16
        fallthrough
    case 2:
        k1 ^= UInt32(bytes[tail + 1]) << 8
        fallthrough
    case 1:
        k1 ^= UInt32(bytes[tail])
        k1 = k1 &* c1
        k1 = (k1 << 15) | (k1 >> 17)
        k1 = k1 &* c2
        h1 ^= k1
    default:
        break
    }

    h1 ^= UInt32(truncatingIfNeeded: length)
    // fmix32
    h1 ^= h1 >> 16
    h1 = h1 &* 0x85eb_ca6b
    h1 ^= h1 >> 13
    h1 = h1 &* 0xc2b2_ae35
    h1 ^= h1 >> 16
    return h1
}

/// FeatureHasher(n_features: 2^20, alternate_sign: false) の列インデックス。
///
/// `abs()` は使わない: Swift の `abs(Int32.min)` はトラップするが、
/// Python も C も `abs(INT32_MIN) % 2^20 == 0` を返す。`magnitude` は UInt32 を返すので
/// この境界でもトラップしない。
@inlinable
public func featureIndex(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
    let signed = Int32(bitPattern: murmurHash3_x86_32(bytes, seed: 0))
    return Int(signed.magnitude & 0x0F_FFFF)
}

@inlinable
public func featureIndex(_ string: String) -> Int {
    let bytes = Array(string.utf8)
    return bytes.withUnsafeBufferPointer { featureIndex($0) }
}
