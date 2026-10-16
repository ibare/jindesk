// headless claude -p 실행기. 작업 종류와 무관하게, 격리된 작업 공간에서 에이전트 한 번을 돌린다.
import Foundation

public struct AgentOptions: Sendable {
  public var config: RunnerConfig
  public var workspace: URL
  public var configDir: URL
  public var systemPromptFile: URL
  public var eventsFile: URL
  // 이번 실행의 지시 (1차, 2차, 고쳐 쓰기 요청 등)
  public var prompt: String
  // 끝난 세션을 이어 간다. fork 면 원본 세션은 그대로 두고 복사본으로 이어 간다.
  public var resume: (sessionID: String, fork: Bool)?
  // 외부 호출 검사. 있을 때만 웹 검색과 웹 조회를 쓸 수 있다 (관점 붙이기의 레퍼런스 찾기).
  public var externalGuard: ExternalGuard?
  public var onEvent: @Sendable (LogKind, String) async -> Void
  // 이번 실행에서 지금까지 쓴 턴 수 (화면의 실시간 표시용). 끝난 뒤의 정확한 값은 결과의 turns 다.
  public var onTurns: (@Sendable (Int) async -> Void)?

  public init(
    config: RunnerConfig, workspace: URL, configDir: URL, systemPromptFile: URL, eventsFile: URL, prompt: String,
    resume: (sessionID: String, fork: Bool)? = nil, externalGuard: ExternalGuard? = nil, onEvent: @escaping @Sendable (LogKind, String) async -> Void,
    onTurns: (@Sendable (Int) async -> Void)? = nil
  ) {
    self.config = config
    self.workspace = workspace
    self.configDir = configDir
    self.systemPromptFile = systemPromptFile
    self.eventsFile = eventsFile
    self.prompt = prompt
    self.resume = resume
    self.externalGuard = externalGuard
    self.onEvent = onEvent
    self.onTurns = onTurns
  }

  public func with(prompt: String, resume: (sessionID: String, fork: Bool)? = nil, eventsFile: URL? = nil) -> AgentOptions {
    var copy = self
    copy.prompt = prompt
    copy.resume = resume
    if let eventsFile { copy.eventsFile = eventsFile }
    return copy
  }
}

public struct AgentResult: Sendable, Equatable {
  public enum Status: String, Sendable { case ok, error, timeout, cancelled }
  public let status: Status
  public let message: String?
  public let turns: Int?
  public let costUsd: Double?
  public let sessionID: String?

  public init(status: Status, message: String? = nil, turns: Int? = nil, costUsd: Double? = nil, sessionID: String? = nil) {
    self.status = status
    self.message = message
    self.turns = turns
    self.costUsd = costUsd
    self.sessionID = sessionID
  }
}

public enum AgentRunner {
  static let fileTools = ["Read", "Grep", "Glob", "Write", "Edit"]
  static let webTools = ["WebSearch", "WebFetch"]

  // 상대 경로는 작업 디렉터리 기준이다. --restricted 가 파일 도구를 작업 디렉터리 안으로 묶고,
  // dontAsk 모드가 여기 없는 호출을 모두 거부한다. 쓰기는 out/, work/ 만 허용한다. 웹 도구는 검사 훅이 있을 때만 연다.
  public static func settings(_ externalGuard: ExternalGuard?, helper: String) -> YAMLValue {
    var allow: [YAMLValue] = ["Read", "Grep", "Glob", "Write(./out/**)", "Edit(./out/**)", "Write(./work/**)", "Edit(./work/**)"]
    if externalGuard != nil { allow += webTools.map(YAMLValue.string) }
    var map: YAMLMap = ["permissions": ["allow": .array(allow)]]
    if let externalGuard { map["hooks"] = YAMLValue(json: externalGuard.hooks(helperPath: helper)) }
    return .map(map)
  }

  public static func arguments(_ o: AgentOptions) -> [String] {
    var args = ["-p", o.prompt]
    if let resume = o.resume { args += ["--resume", resume.sessionID] + (resume.fork ? ["--fork-session"] : []) }
    args += [
      "--restricted",
      "--tools", (fileTools + (o.externalGuard != nil ? webTools : [])).joined(separator: ","),
      "--permission-mode", "dontAsk",
      "--settings", JSONText.stringify(settings(o.externalGuard, helper: o.config.guardHelper)),
      "--append-system-prompt-file", o.systemPromptFile.path,
      "--model", o.config.model,
      "--effort", o.config.effort.rawValue,
      "--max-turns", String(o.config.maxTurns),
      "--max-budget-usd", YAML.formatNumber(o.config.maxBudgetUSD),
      "--output-format", "stream-json",
      "--verbose",
    ]
    return args
  }

  public static func run(_ o: AgentOptions) async -> AgentResult {
    if Task.isCancelled { return AgentResult(status: .cancelled) }
    let claude: String
    do {
      claude = try o.config.tools.requireClaude()
    } catch {
      return AgentResult(status: .error, message: error.localizedDescription)
    }
    let env = ChildEnvironment.agent(base: o.config.baseEnvironment, token: o.config.claudeToken, configDirectory: o.configDir.path)
    let child: ChildProcess
    do {
      try FileOps.makeDirectory(o.configDir)
      child = try ChildProcess.spawn(
        ChildSpec(executable: claude, arguments: arguments(o), environment: env, directory: o.workspace.path, stdout: .lines, stderrLimit: 4000))
    } catch {
      return AgentResult(status: .error, message: "claude 실행 실패: \(error.localizedDescription)")
    }

    let stop = StopReason()
    let timeoutMinutes = o.config.timeoutMinutes
    let timer = Task {
      do {
        // 맥이 잠든 시간은 상한에서 뺀다. 덮개를 닫았다 열어도 깨어난 뒤 이어서 진행한다.
        try await AwakeTimer.wait(o.config.timeout) { slept in
          await o.onEvent(.warn, "맥이 \(Int((Double(slept.components.seconds) / 60).rounded()))분 잠들어 있었습니다. 그 시간은 시간 상한에서 뺍니다")
        }
        if stop.set(.timeout) { child.stop(grace: 10) }
      } catch {}
    }

    let events = EventLog(o.eventsFile)
    var resultEvent: JSONValue?
    var sessionID: String?
    var counter = TurnCounter()
    await withTaskCancellationHandler {
      for await line in child.lines {
        events.append(line)
        guard let event = try? JSONValue.parse(Data(line.utf8)) else { continue }
        if event["type"]?.stringValue == "result" { resultEvent = event }
        if let onUsage = o.config.onUsage, let usage = UsageReading.parse(event) { onUsage(usage) }
        if let id = event["session_id"]?.stringValue { sessionID = id }
        if let onTurns = o.onTurns, counter.add(event) { await onTurns(counter.count) }
        for (kind, message) in StreamEvents.describe(event, cwd: o.workspace.path) { await o.onEvent(kind, message) }
      }
    } onCancel: {
      if stop.set(.cancelled) { child.stop(grace: 10) }
    }
    let exit = await child.wait()
    timer.cancel()
    events.close()

    switch stop.value {
    case .timeout?:
      return AgentResult(status: .timeout, message: "시간 상한(깨어 있던 시간 \(YAML.formatNumber(timeoutMinutes))분)을 넘어 중단했습니다", sessionID: sessionID)
    case .cancelled?:
      return AgentResult(status: .cancelled, sessionID: sessionID)
    case nil:
      break
    }
    let turns = resultEvent?["num_turns"]?.numberValue.map { Int($0) }
    let cost = resultEvent?["total_cost_usd"]?.numberValue
    if let r = resultEvent, r["subtype"]?.stringValue == "success", r["is_error"]?.boolValue != true {
      return AgentResult(status: .ok, turns: turns, costUsd: cost, sessionID: sessionID)
    }
    let reason: String
    if let r = resultEvent {
      let detail = r["result"]?.stringValue.flatMap { $0.isEmpty ? nil : " — " + FileOps.prefix($0, 300) } ?? ""
      reason = "에이전트가 정상 종료하지 않았습니다: \(r["subtype"]?.looseString ?? "undefined")\(detail)"
    } else {
      let code: String =
        switch exit.termination {
        case .exited(let c): String(c)
        case .signaled: "null"
        }
      let tail = exit.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      reason = "에이전트가 결과 없이 종료했습니다 (종료 코드 \(code))\(tail.isEmpty ? "" : ": " + String(tail.suffix(500)))"
    }
    return AgentResult(status: .error, message: reason, turns: turns, costUsd: cost, sessionID: sessionID)
  }
}

// 먼저 정해진 중단 이유 하나만 남긴다
final class StopReason: @unchecked Sendable {
  enum Reason { case timeout, cancelled }
  private let lock = NSLock()
  private var reason: Reason?

  // 처음 정할 때만 true
  func set(_ r: Reason) -> Bool {
    lock.withLock {
      if reason != nil { return false }
      reason = r
      return true
    }
  }

  var value: Reason? { lock.withLock { reason } }
}

// 이벤트 기록 파일 (덧붙여 쓴다)
final class EventLog: @unchecked Sendable {
  private let handle: FileHandle?

  init(_ url: URL) {
    try? FileOps.makeDirectory(url.deletingLastPathComponent())
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
  }

  func append(_ line: String) {
    try? handle?.write(contentsOf: Data((line + "\n").utf8))
  }

  func close() {
    try? handle?.close()
  }
}

// 실행 중의 턴 수. claude 가 끝에 알리는 num_turns 는 첫 응답 하나에, 그 뒤 사용자 쪽 이벤트(도구 결과,
// 응답이 멈춘 뒤 이어 가라는 글 등)마다 하나를 더한 값과 같다 (Assayer 의 지난 실행 기록으로 확인했다).
struct TurnCounter {
  private(set) var count = 0

  // 턴 수가 바뀌었으면 true
  mutating func add(_ event: JSONValue) -> Bool {
    switch event["type"]?.stringValue {
    case "assistant" where count == 0:
      count = 1
      return true
    case "user" where count > 0:
      count += 1
      return true
    default:
      return false
    }
  }
}
