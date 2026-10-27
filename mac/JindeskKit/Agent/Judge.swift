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
    let language = LanguageAcquisition.target(of: subject).map { target in
      """

      언어 습득 과목이다. \(target) 를 배우는 중이고, 설명은 영어이며 \(target) 의 낱말과 예문이 섞인다.
      영어 뜻이나 설명이 붙은 \(target) 낱말과 문장은 이해한 것으로 본다. 뜻이 붙지 않았고 그 학년에서 모를 \(target) 낱말이나 문장은 unclear 에 넣는다.
      """
    } ?? ""
    return """
      너는 \(level) 이다. 과목은 \(subject) 다. 영어로 수업을 듣는다. 아래 글을 처음 읽는다. 수업 자료나 다른 글은 볼 수 없다.
      그 학년에서 이미 배운 것(앞 단원의 기초 용어와 계산)은 안다고 가정한다. 수식은 TeX 로 적혀 있다.\(language)

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

// 학습 목표 시험 (DECISIONS.md 25): 자료가 밝힌 학습 목표를, 이 글만 읽은 그 학년 학생이 해낼 수 있는가.
// 목표마다 이 글의 개념에 해당하는지, 해낼 수 있는지(met), 그것을 연습하는 확인 문제가 있는지(practiced)를 본다.
public enum OutcomeTest {
  public struct Goal: Sendable, Equatable {
    public let key: String
    public let text: String

    public init(key: String, text: String) {
      self.key = key
      self.text = text
    }
  }

  public struct Verdict: Sendable, Equatable {
    public let key: String
    public let applies: Bool
    public let met: Bool
    public let practiced: Bool
    // 해낼 수 없거나 연습할 문제가 없을 때 빠진 것 (한국어)
    public let missing: String
  }

  static let schema = """
    {"type":"object","properties":{"outcomes":{"type":"array","items":{"type":"object","properties":{"key":{"type":"string"},"applies":{"type":"boolean"},"met":{"type":"boolean"},"practiced":{"type":"boolean"},"missing":{"type":"string"}},"required":["key","applies","met","practiced","missing"]}}},"required":["outcomes"]}
    """

  // others: 같은 과목의 다른 개념 제목. 그 개념이 맡는 내용은 이 글에 없어도 된다.
  public static func prompt(text: String, goals: [Goal], level: String, subject: String, others: [String] = []) -> String {
    let list = goals.map { "- \($0.key): \($0.text)" }.joined(separator: "\n")
    let siblings = others.isEmpty ? "없다." : others.map { "- \($0)" }.joined(separator: "\n")
    let target = LanguageAcquisition.target(of: subject)
    let metRule =
      target.map { t in
        """
        - met: 이 글만 읽고 그 목표를 \(t) 로 해낼 수 있으면 true. 언어 습득 과목이라 explain, describe, talk about, give opinions 같은 목표는
          주제를 \(t) 로 말하고 쓰는 일이다. 그 일에 필요한 문법(형태와 쓰임), 낱말, 표현, 문장 틀과 예문이 글에 있는가로 판정한다.
          주제 내용의 까닭이나 사회적 배경을 설명하지 않았다고 false 로 두지 않는다.
        - practiced: 그 목표를 \(t) 로 연습하는 확인 문제(Check)가 글에 있으면 true. 활용, 문장 만들기, 고쳐 쓰기, 짧은 읽기처럼
          \(t) 를 쓰거나 읽는 문제다. 주제 내용을 영어로 설명하게 하는 문제는 연습으로 치지 않는다.
          글에 확인 문제가 하나도 없으면(개념 원문만 받은 경우) true 로 둔다.
        """
      } ?? """
        - met: 이 글만 읽고 그 목표를 해낼 수 있으면 true. 목표의 동사를 따른다. calculate 나 classify 는 글의 절차대로 따라 할 수 있는가.
          interpret, compare, make inferences, explain 은 결과가 무엇을 뜻하는지, 왜 그런지, 자료가 바뀌면 어떻게 되는지를 글에 근거해 말할 수 있는가.
          글이 계산만 보이고 그 뜻이나 까닭을 말하지 않으면 false 다.
        - practiced: 그 목표를 연습하는 확인 문제(Check)가 글에 있으면 true. 목표가 해석·비교·설명을 요구하는데 계산 문제만 있으면 false 다.
          글에 확인 문제가 하나도 없으면(개념 원문만 받은 경우) true 로 둔다.
        """
    return """
      너는 \(level) 이다. 과목은 \(subject) 다. 영어로 수업을 듣는다. 아래 학습 글만 읽었다. 수업 자료나 다른 글은 볼 수 없다.
      그 학년에서 이미 배운 것(앞 단원의 기초 용어와 계산)은 안다고 가정한다. 수식은 TeX 로 적혀 있다.
      선생님이 이 수업의 학습 목표를 밝혀 두었다. 목표마다 판정한다.

      - applies: 이 글의 개념이 이 목표에 속하면 true. 다른 개념에 대한 목표면 false 이고, 그때 met 과 practiced 는 true 로 둔다.
        목표가 여러 개념을 묶어 말하면(여러 통계값을 나열하거나, 분류·계산·적용을 함께 말하는 목표), 이 글의 개념이 맡는 부분이 있을 때만 true 이고
        met 과 practiced 는 그 부분으로만 판정한다. 아래 "같은 과목의 다른 개념"이 맡는 부분은 이 글에 없어도 된다. 그것을 빠졌다고 하지 않는다.
      \(metRule)
      - missing: met 이나 practiced 가 false 면 무엇이 빠졌는지 한국어 한두 문장. 목표의 범위 안에서, 이 개념이 맡는 부분만 말한다.
        그 학년 수업을 넘는 내용이나, 다른 개념이 맡는 내용을 요구하지 않는다.

      학습 목표:
      \(list)

      같은 과목의 다른 개념 (각자 자기 페이지가 있다):
      \(siblings)

      <text>
      \(text)
      </text>
      """
  }

  public static func check(
    text: String, goals: [Goal], level: String, subject: String, others: [String] = [], config: RunnerConfig, scratch: URL
  ) async -> (verdicts: [Verdict], error: String?) {
    guard !goals.isEmpty else { return ([], nil) }
    let r = await Judge.run(
      prompt: prompt(text: text, goals: goals, level: level, subject: subject, others: others), schema: schema, config: config, scratch: scratch)
    guard let v = r.value else { return ([], r.error) }
    // 판정을 받지 못한 목표는 통과로 둔다
    let verdicts = (v["outcomes"]?.arrayValue ?? []).compactMap { o -> Verdict? in
      guard let key = o["key"]?.stringValue else { return nil }
      return Verdict(
        key: key, applies: o["applies"]?.boolValue ?? false, met: o["met"]?.boolValue ?? true, practiced: o["practiced"]?.boolValue ?? true,
        missing: o["missing"]?.stringValue ?? "")
    }
    return (verdicts, nil)
  }

  // 해당하는데 해낼 수 없는 목표 → 문제 줄. subject 가 언어 습득 과목이면 목표 언어로 해낼 것을 요구한다.
  public static func unmet(_ verdicts: [Verdict], goals: [Goal], subject: String = "") -> [String] {
    let text = Dictionary(goals.map { ($0.key, $0.text) }, uniquingKeysWith: { a, _ in a })
    let fix =
      LanguageAcquisition.target(of: subject).map {
        "그 부분을 \($0) 로 해낼 수 있게 필요한 문법, 낱말, 표현과 예문을 쓴다(자료에 없는 것은 보충으로). 주제 내용의 까닭이나 사회적 배경은 쓰지 않고, 다른 개념이 맡는 내용은 다시 쓰지 않는다."
      } ?? "자료의 수준 안에서 그 부분을 해낼 수 있게 설명한다(자료에 없는 설명은 보충으로). 새 개념이나 공식을 더하지 않고, 다른 개념이 맡는 내용은 다시 쓰지 않는다."
    return verdicts.filter { $0.applies && !$0.met }.map {
      "학습 목표 \"\(text[$0.key] ?? $0.key)\"에서 이 개념이 맡는 부분을 이 글만 읽고 해낼 수 없다: \($0.missing) \(fix)"
    }
  }

  // 해당하는데 연습할 확인 문제가 없는 목표 → 문제 줄
  public static func unpracticed(_ verdicts: [Verdict], goals: [Goal], subject: String = "") -> [String] {
    let text = Dictionary(goals.map { ($0.key, $0.text) }, uniquingKeysWith: { a, _ in a })
    let fix =
      LanguageAcquisition.target(of: subject).map {
        "그 부분을 \($0) 로 쓰거나 읽는 확인 문제(활용, 문장 만들기, 고쳐 쓰기, 짧은 읽기)를 더한다. 주제 내용의 까닭은 묻지 않고, 다른 개념이 맡는 내용은 묻지 않는다."
      } ?? "그 부분을 묻는 확인 문제를 더한다(해석·비교·설명을 요구하면 계산만 시키지 않는다). 다른 개념이 맡는 내용은 묻지 않는다."
    return verdicts.filter { $0.applies && !$0.practiced }.map {
      "학습 목표 \"\(text[$0.key] ?? $0.key)\"에서 이 개념이 맡는 부분을 연습하는 확인 문제가 없다: \($0.missing) \(fix)"
    }
  }
}
