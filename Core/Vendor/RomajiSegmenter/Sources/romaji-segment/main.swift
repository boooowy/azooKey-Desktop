import Foundation
import RomajiSegmenter

// Python の eval_a.py / regression_test.py / eval_incremental.py と同じ指標を出す。
// 移植が正しければ数字が一字一句一致する。

struct Case: Decodable {
    let input: String
    let input_cased: String
    let english: [String]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func loadCases(_ path: String) -> [Case] {
    guard let data = FileManager.default.contents(atPath: path) else { fail("読めません: \(path)") }
    do { return try JSONDecoder().decode([Case].self, from: data) }
    catch { fail("JSON を解釈できません: \(error)") }
}

func percent(_ a: Int, _ b: Int) -> String {
    b == 0 ? "0.0%" : String(format: "%.1f%%", Double(a) / Double(b) * 100)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("使い方: romaji-segment <eval|regress|incremental|dump|bench> [オプション]")
}
let cased = args.contains("--cased")
let segmenter: Segmenter
do { segmenter = try Segmenter.bundled() } catch { fail("重みを読めません: \(error)") }

switch command {

case "eval":
    // eval_a.py 相当
    guard let path = option("--cases", in: args) else { fail("--cases が必要です") }
    let cases = loadCases(path)
    var ok: [String: Int] = [:], total: [String: Int] = [:], errors: [String: Int] = [:]
    let t0 = Date()
    for c in cases {
        let text = cased ? c.input_cased : c.input
        let truth = Evaluation.englishMask(text: c.input, english: c.english)
        guard let best = try? segmenter.segmentKBest(text, k: 1).first else { fail("変換できません: \(text)") }
        let group = c.english.isEmpty ? "英単語なし" : "英単語あり"
        total[group, default: 0] += 1
        let mask = Evaluation.segMask(best.segments)
        if mask == truth {
            ok[group, default: 0] += 1
        } else {
            errors[Evaluation.errorType(truth: truth, pred: mask), default: 0] += 1
        }
    }
    let ms = Date().timeIntervalSince(t0) * 1000 / Double(cases.count)
    let nOk = ok.values.reduce(0, +), n = total.values.reduce(0, +)
    let groups = ["英単語あり", "英単語なし"].map {
        "\($0) \(ok[$0] ?? 0)/\(total[$0] ?? 0) (\(percent(ok[$0] ?? 0, total[$0] ?? 0)))"
    }.joined(separator: "  ")
    print("[\(URL(fileURLWithPath: path).lastPathComponent)] 全体 \(nOk)/\(n) (\(percent(nOk, n)))  "
          + groups + String(format: "  (%.1f ms/件)", ms))
    for (et, count) in errors.sorted(by: { $0.key < $1.key }) {
        print("  \(et): \(count)件")
    }

case "regress":
    // regression_test.py 相当
    guard let path = option("--file", in: args) else { fail("--file が必要です") }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("読めません: \(path)") }
    var passed = 0, cases = 0
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        cases += 1
        let input = line.filter { $0 != "[" && $0 != "]" && $0 != " " }
        let got = (try? segmenter.segmentKBest(input, k: 1).first?.display) ?? nil
        let ok = got == line
        passed += ok ? 1 : 0
        print("  \(ok ? "○" : "✕") \(line)" + (ok ? "" : "\n      → \(got ?? "-")"))
    }
    print("回帰テスト (romaji_lr_v5): \(passed)/\(cases) 件 合格")

case "incremental":
    // eval_incremental.py 相当
    guard let path = option("--cases", in: args) else { fail("--cases が必要です") }
    let cases = loadCases(path)
    var steps = 0, settledOk = 0, flickerTotal = 0, finalOk = 0
    var times: [Double] = []
    for c in cases {
        let text = cased ? c.input_cased : c.input
        let ascii = Array(text.utf8)
        let truth = Evaluation.englishMask(text: c.input, english: c.english)
        var prevMask = ""
        var mask = ""
        for n in 1 ... ascii.count {
            let prefix = String(decoding: ascii[0 ..< n], as: UTF8.self)
            let t0 = Date()
            // 最後まで打った状態 = 確定時なので partial を切る
            guard let best = try? segmenter.segmentKBest(prefix, k: 1, partial: n < ascii.count).first
            else { fail("変換できません: \(prefix)") }
            times.append(Date().timeIntervalSince(t0) * 1000)
            mask = Evaluation.segMask(best.segments)
            let settled = Evaluation.settledLength(truth: truth, typed: n)
            if settled > 0 {
                steps += 1
                settledOk += String(mask.prefix(settled)) == String(truth.prefix(settled)) ? 1 : 0
            }
            if !prevMask.isEmpty,
               String(mask.prefix(prevMask.count - 1)) != String(prevMask.dropLast()) {
                flickerTotal += 1
            }
            prevMask = mask
        }
        finalOk += mask == truth ? 1 : 0
    }
    times.sort()
    let median = times[times.count / 2], max = times.last ?? 0
    print("[\(URL(fileURLWithPath: path).lastPathComponent)] \(cases.count)文, \(times.count)打鍵")
    print("  途中の正しさ \(settledOk)/\(steps) (\(percent(settledOk, steps)))")
    print("  ちらつき \(flickerTotal)回")
    print("  最終の正しさ \(finalOk)/\(cases.count) (\(percent(finalOk, cases.count)))")
    print(String(format: "  1打鍵あたり 中央値 %.2f ms / 最大 %.2f ms", median, max))

case "dump":
    // 差分ファジング用: 1 行 1 入力を読み、確定時と打ちかけの display を出す
    guard let path = args.dropFirst().first else { fail("入力ファイルが必要です") }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("読めません: \(path)") }
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let input = String(line)
        guard let final = try? segmenter.segmentKBest(input, k: 1).first,
              let partial = try? segmenter.segmentKBest(input, k: 1, partial: true).first
        else { fail("変換できません: \(input)") }
        print("\(input)\t\(final.display)\t\(partial.display)")
    }

case "bench":
    // 打鍵あたりの所要時間。IME は 1 打鍵ごとに呼ぶのでこれが効く
    guard let path = option("--cases", in: args) else { fail("--cases が必要です") }
    let cases = loadCases(path)
    var times: [Double] = []
    for c in cases {
        let ascii = Array(cased ? c.input_cased.utf8 : c.input.utf8)
        for n in 1 ... ascii.count {
            let prefix = String(decoding: ascii[0 ..< n], as: UTF8.self)
            let t0 = Date()
            _ = try? segmenter.segmentKBest(prefix, k: 1, partial: n < ascii.count)
            times.append(Date().timeIntervalSince(t0) * 1000)
        }
    }
    times.sort()
    print(String(format: "打鍵 %d 回: 中央値 %.3f ms / p95 %.3f ms / 最大 %.3f ms",
                 times.count, times[times.count / 2],
                 times[Int(Double(times.count) * 0.95)], times.last ?? 0))

default:
    fail("未知のコマンド: \(command)")
}
