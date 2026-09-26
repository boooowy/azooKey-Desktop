# 同梱しているパッケージ

## RomajiSegmenter

日英混在入力の区間判定 (打った文字列のどこが日本語でどこが英語か)。

- 元: [boooowy/jev-test](https://github.com/boooowy/jev-test) (private) の `RomajiSegmenter/`
- 同梱した時点: jev-test `89f3222`
- 開発とテスト (Python 版と同じ答えを返すことの golden テスト) は jev-test で行う。
  ここでは直接編集しない

jev-test は private で、しかもパッケージがリポジトリ直下にないため、SwiftPM の URL 指定では
依存にできない。CI でも取得できるように、コミット済みの内容をここにコピーしている。
生成用の `Scripts/` (Python) は jev-test 本体がないと動かないので除いている。

### 更新するとき

jev-test 側でコミットしてから、azooKey-Desktop の直下で次を実行する。

```sh
rm -rf Core/Vendor/RomajiSegmenter
git -C ../jev-test archive --format=tar HEAD RomajiSegmenter \
  | tar -x -C Core/Vendor --exclude 'RomajiSegmenter/Scripts'
git -C ../jev-test rev-parse --short HEAD   # 上の「同梱した時点」を書き換える
```
