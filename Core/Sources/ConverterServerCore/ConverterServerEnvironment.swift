import Core
import Foundation

/// 変換サーバーが読み書きする場所。
///
/// 実機では App Group の共有コンテナとアプリのリソースを使う。打鍵の再生ツールは、
/// 実機の学習データを汚さないよう一時ディレクトリを渡し、モデルはインストール済みのものを渡す。
public struct ConverterServerEnvironment: Sendable {
    /// 学習データ・ユーザー辞書の置き場所
    public var memoryDirectoryURL: URL
    /// App Group の共有コンテナ (個人最適化のモデルを探す)
    public var containerURL: URL?
    /// Zenzai のモデルなどのリソース
    public var resourcesDirectoryURL: URL

    public init(memoryDirectoryURL: URL, containerURL: URL?, resourcesDirectoryURL: URL) {
        self.memoryDirectoryURL = memoryDirectoryURL
        self.containerURL = containerURL
        self.resourcesDirectoryURL = resourcesDirectoryURL
    }

    /// 実機の場所
    public static var production: ConverterServerEnvironment {
        ConverterServerEnvironment(
            memoryDirectoryURL: AppGroup.memoryDirectoryURL(),
            containerURL: AppGroup.containerURL(),
            resourcesDirectoryURL: appResourcesDirectoryURL()
        )
    }

    /// 実行ファイルが入っているアプリの Contents/Resources
    static func appResourcesDirectoryURL() -> URL {
        if let executableURL = Bundle.main.executableURL {
            var directoryURL = executableURL.deletingLastPathComponent()
            while directoryURL.path != "/" {
                if directoryURL.lastPathComponent == "Contents" {
                    return directoryURL.appendingPathComponent("Resources", isDirectory: true)
                }
                directoryURL.deleteLastPathComponent()
            }
        }
        if let resourceURL = Bundle.main.resourceURL {
            return resourceURL
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    }
}
