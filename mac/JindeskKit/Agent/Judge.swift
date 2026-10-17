// 도구도 작업 공간도 세션도 없는 한 번의 판정 (Assayer 의 격리 시험을 옮긴 것).
// 학생 독자 시험과 부분 다시 만들기의 격리 검증이 쓴다. 판정자는 받은 글만 보고 JSON 하나로 답한다.
import Foundation

public struct JudgeResult: Sendable {
  public let value: JSONValue?
  public let error: String?
  public let costUsd: Double?

  public static func failed(_ reason: String) -> JudgeResult { JudgeResult(value: nil, error: reason, costUsd: nil) }
}

public enum Judge {
  static let timeout: Duration = .seconds(240)

  // scratch: 이 판정 전용의 빈 폴더. 판정자의 작업 디렉터리와 설정 폴더를 그 안에 만든다.
  public static func run(prompt: String, schema: String, config: RunnerConfig, scratch: URL, effort: Effort = .low) async -> JudgeResult {
    let cwd = scratch.appending(path: "cwd")
    let configDir = scratch.appending(path: "claude-config")
    do {
      try FileOps.makeDirectory(cwd)
      try FileOps.makeDirectory(configDir)
    } catch {
      return .failed("판정을 띄우지 못했습니다: \(error.localizedDescription)")
    }
    if Task.isCancelled { return .failed("취소됨") }
    let args = [
      "-p", prompt,
      "--restricted",
      "--tools", "",
      "--model", config.model,
      "--effort", effort.rawValue,
      "--json-schema", schema,
      "--output-format", "json",
      "--max-turns", "4",
      "--no-session-persistence",
    ]
    let child: ChildProcess
    do {
      let claude = try config.tools.requireClaude()
      let env = ChildEnvironment.agent(base: config.baseEnvironment, token: config.claudeToken, configDirectory: configDir.path)
      child = try ChildProcess.spawn(ChildSpec(executable: claude, arguments: args, environment: env, directory: cwd.path, stdout: .collect, stderrLimit: 2000))
    } catch {
      return .failed("판정을 띄우지 못했습니다: \(error.localizedDescription)")
    }
    let timer = Task {
      do {
        try await AwakeTimer.wait(timeout, tick: .seconds(5))
        child.signalGroup(SIGKILL)
      } catch {}
    }
    let result = await withTaskCancellationHandler {
      await child.wait()
    } onCancel: {
      child.signalGroup(SIGKILL)
    }
    timer.cancel()
    try? await Task.sleep(for: .milliseconds(10))
    if Task.isCancelled { return .failed("취소됨") }
    guard let outer = try? JSONValue.parse(Data(result.stdoutText.utf8)) else {
      let tail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      return .failed("판정 결과를 읽을 수 없습니다\(tail.isEmpty ? "" : ": " + String(tail.suffix(300)))")
    }
    let cost = outer["total_cost_usd"]?.numberValue
    var value = outer["structured_output"]
    if value?.objectValue == nil, let text = outer["result"]?.stringValue { value = try? JSONValue.parse(Data(text.utf8)) }
    guard let value, value.objectValue != nil else { return JudgeResult(value: nil, error: "판정이 JSON 이 아닙니다", costUsd: cost) }
    return JudgeResult(value: value, error: nil, costUsd: cost)
  }
}

// 학생 독자 시험 (JOBS.md): 원래 자료 없이, 그 학년·수준의 학생이 글만 읽고 이해하는지 단위마다 판정한다.
public enum ReaderTest {
  public struct Item: Sendable, Equatable {
    public let key: String
    public let text: String

    public init(key: String, text: String) {
      self.key = key
      self.text = text
    }
  }

  public struct Verdict: Sendable, Equatable {
    public let key: String
    public let pass: Bool
    // 학생이 알 수 없었던 것
    public let unclear: [String]
    public let reason: String
  }

  static let schema = """
    {"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"key":{"type":"string"},"verdict":{"type":"string","enum":["pass","fail"]},"unclear":{"type":"array","items":{"type":"string"}},"reason":{"type":"string"}},"required":["key","verdict","unclear","reason"]}}},"required":["items"]}
    """

  // 꼬리표에서 독자 수준을 정한다 (예: MYP 5 Extended, DP1 HL)
  public static func level(_ labels: SourceLabels?) -> String {
    let parts = [labels?.grade, labels?.level].compactMap { $0 }
    return parts.isEmpty ? "an IB student" : "an IB student in " + parts.joined(separator: " ")
  }

  public static func prompt(_ items: [Item], level: String, subject: String) -> String {
    let body = items.map { "<unit key=\"\($0.key)\">\n\($0.text)\n</unit>" }.joined(separator: "\n\n")
    return """
      너는 \(level) 이다. 과목은 \(subject) 다. 영어로 수업을 듣는다. 아래 글을 처음 읽는다. 수업 자료나 다른 글은 볼 수 없다.
      그 학년에서 이미 배운 것(앞 단원의 기초 용어와 계산)은 안다고 가정한다. 수식은 TeX 로 적혀 있다.

      단위(unit)마다 판정한다.
      - verdict: 이 글만 읽고 무엇을 말하는지 이해할 수 있으면 pass, 아니면 fail. 다음이 있으면 fail 이다:
        - 수업 자료를 봐야만 통하는 말 ("slide 3", "the diagram above", "as in the worksheet", "the teacher's example")
        - 정의하지 않은 기호나 그 학년에서 모를 용어를 설명 없이 쓴다
        - 앞뒤가 이어지지 않거나, 무엇을 가리키는지 알 수 없는 "this", "it"
      - unclear: 이해하지 못한 표현이나 기호를 모두. 없으면 빈 목록.
      - reason: 판정 이유 한 문장 (한국어).
      엄격하되, 그 학년 학생이 보통 아는 것까지 문제 삼지는 않는다.

      \(body)
      """
  }

  public static func check(_ items: [Item], level: String, subject: String, config: RunnerConfig, scratch: URL) async -> (verdicts: [Verdict], error: String?) {
    guard !items.isEmpty else { return ([], nil) }
    let r = await Judge.run(prompt: prompt(items, level: level, subject: subject), schema: schema, config: config, scratch: scratch)
    guard let v = r.value else { return ([], r.error) }
    let verdicts = (v["items"]?.arrayValue ?? []).compactMap { i -> Verdict? in
      guard let key = i["key"]?.stringValue, let verdict = i["verdict"]?.stringValue else { return nil }
      return Verdict(
        key: key, pass: verdict == "pass", unclear: (i["unclear"]?.arrayValue ?? []).compactMap(\.stringValue), reason: i["reason"]?.stringValue ?? "")
    }
    // 판정을 받지 못한 단위는 통과로 둔다 (판정자가 빠뜨린 것으로 글을 버리지 않는다)
    return (verdicts, nil)
  }

  // 고쳐 쓰기 요청에 넣을 문제 줄
  public static func problems(_ verdicts: [Verdict]) -> [String: [String]] {
    var out: [String: [String]] = [:]
    for v in verdicts where !v.pass {
      var lines = ["학생 독자 시험 실패: \(v.reason)"]
      if !v.unclear.isEmpty { lines.append("학생이 알 수 없었던 것: \(v.unclear.joined(separator: " / "))") }
      out[v.key] = lines
    }
    return out
  }
}
