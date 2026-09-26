# RomajiSegmenter

jev-test の区間判定（打った文字列のどこが日本語でどこが英語か）を Swift に移植したもの。

`romaji_model.segment_kbest` / `segment_test.is_romaji` と**同じ答えを返す**ことを
golden テストで保証している。azooKey on macOS に組み込むために作った
（`../docs/azookey-integration.md` のステップ1）。

- 外部依存ゼロの純 Swift。`.interoperabilityMode(.Cxx)` を付けていないので、
  C++ interop を有効にしているターゲット（azookey-bridge など）からも import できる
- Python と同じ答えを返す。`swift test` は Python も `.venv` も要求しない

## 使う

```swift
import RomajiSegmenter

let segmenter = try Segmenter.bundled()
let best = try segmenter.segmentKBest("kononaiyoudeSlacknisousinsiteoite", k: 1).first!
print(best.display)   // この内容で... ではなく区間の表示: kononaiyoude [Slack] nisousinsiteoite
```

打鍵の途中を判定するときは `partial: true` を渡す（末尾の日本語区間が
打ちかけの子音で終わることを許す）。

`Bundle.module` が解決しない環境（Xcode プロジェクト経由のビルドなど）では
`Weights(url:)` にファイルパスを渡す:

```swift
let segmenter = Segmenter(weights: try Weights(url: someURL))
```

## `isRomaji` の差し替え

既定は jev-test の `_KANA` テーブルの忠実移植（`KanaTableChecker`）。
IME に組み込むときは、azooKey の roman2kana で判定する実装を注入できる:

```swift
// RomajiChecker を実装した型を渡す。azooKey の roman2kana を使う実装は
// AzooKeyKanaKanjiConverter に依存するので、ステップ2で IME 側に書く
Segmenter(weights: w, checker: MyChecker())
```

既定を `_KANA` 版にしているのは、モデル自体が `_KANA` 版 `is_romaji` を制約に使った
学習データから作られているため。azooKey 版に替えると学習時の前提とずれる
（この差の大きさは未測定。ステップ2の判断材料）。

## 生成物の作り直し

```bash
.venv/bin/python RomajiSegmenter/Scripts/export_weights.py    # models/*.pkl → Resources/romaji_lr_v5.f32
.venv/bin/python RomajiSegmenter/Scripts/gen_kana_table.py    # _KANA / _TAILS → KanaTable.swift
.venv/bin/python RomajiSegmenter/Scripts/gen_golden.py        # Python の実出力 → Tests/.../golden/
```

`KanaTable.swift` と `golden/` は生成物なので手で編集しない。
golden は `sklearn 1.9.1` / `numpy 2.5.3` に依存する（`golden/meta.json` に記録し、
テストで突き合わせている）。

## 検証

```bash
swift test                                                      # 層別 golden テスト
swift build -c release
.build/release/romaji-segment eval --cases ../data/cases_dev.json --cased
.build/release/romaji-segment regress --file ../data/regression.txt
.build/release/romaji-segment incremental --cases ../data/cases_dev.json --cased
.build/release/romaji-segment bench --cases ../data/cases_dev.json --cased
```

Python と一致することを確認済みの数字:

| 指標 | Python | Swift |
|---|---|---|
| `eval --cases cases_dev.json --cased` | 357/387 (92.2%) | 同じ（誤り内訳 ①16 ②6 ③2+2 ④2+2 も一致） |
| `eval --cases cases.json --cased` | 205/223 | 同じ |
| `eval --cases cases_dev.json` | 343/387 | 同じ |
| `eval --cases cases.json` | 188/223 | 同じ |
| `regress` | 11/19 | 同じ（失敗 8 件の出力文字列も一致） |
| `incremental --cased` | 途中 1267/1569 / ちらつき 156 / 最終 357/387 | 同じ |
| 1 打鍵あたり（中央値） | 0.31 ms | **0.032 ms** |

> `regress` は元から 11/19 しか通らない。Swift 側の合格基準は 19/19 ではなく
> 「Python と同じ 11/19、かつ失敗した 8 件の出力文字列も一致」。

差分ファジング（合成入力 2,000 本で Python と突き合わせ）も不一致 0 件:

```bash
.venv/bin/python RomajiSegmenter/Scripts/fuzz_inputs.py 2000 > /tmp/fuzz.txt
.venv/bin/python RomajiSegmenter/Scripts/dump_python.py /tmp/fuzz.txt > /tmp/py.tsv
.build/release/romaji-segment dump /tmp/fuzz.txt > /tmp/sw.tsv
diff /tmp/py.tsv /tmp/sw.tsv
```

## 移植で気をつけたところ

- **大小文字の扱いが 3 通りに分かれる** — `c:`/`gN@` 特徴は小文字化、`s:` 系の shape 特徴は
  元の大小のまま（padding も固定 2 文字で WINDOW と連動しない）、`isRomaji` は小文字化しない
  （＝大文字を含む区間は japanese になれず、実質 english を強制する）
- **`abs(Int32.min)` は Swift でトラップする** — Python も C も `abs(INT32_MIN) % 2^20 == 0`
  を返すので、`magnitude` 経由で合わせている
- **DP のタイブレークは Python の安定ソート順に依存する** — Swift の `sort(by:)` は安定性が
  保証されないため、生成順の連番を明示的な第 2 キーにしている
- **重みは float32** — 1-best と 2-best のスコア差は最小 8.3e-3 なのに対し、float32 による
  DP スコアの誤差は 2.9e-7。4.5 桁の余裕があり、741 テキストで 1-best パスは不変
