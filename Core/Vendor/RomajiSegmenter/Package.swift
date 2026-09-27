// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "RomajiSegmenter",
    // azookey-bridge と揃える。上げると bridge 側が壊れる
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RomajiSegmenter", targets: ["RomajiSegmenter"]),
        .executable(name: "romaji-segment", targets: ["romaji-segment"]),
    ],
    targets: [
        // 外部依存ゼロの純 Swift。C++ interop は付けない
        // (Cxx 有効なモジュールは利用側にも強制するが、その逆は問題ない)
        .target(
            name: "RomajiSegmenter",
            resources: [.copy("Resources/romaji_lr_v6.f32")]
        ),
        .executableTarget(name: "romaji-segment", dependencies: ["RomajiSegmenter"]),
        .testTarget(
            name: "RomajiSegmenterTests",
            dependencies: ["RomajiSegmenter"],
            resources: [.copy("Resources/golden")]
        ),
    ]
)
