import Foundation

public enum LogKind: String, Sendable, Codable, CaseIterable {
  case phase, tool, text, info, warn, error
}

public struct LogEntry: Sendable, Codable, Equatable, Identifiable {
  public let seq: Int
  public let at: String
  public let kind: LogKind
  public let message: String
  public var id: Int { seq }
}

// 작업이 보고하는 결과 수 (예: 엔트리 12, 목차 밖 2)
public struct JobCount: Sendable, Codable, Equatable {
  public let key: String
  public let label: String
  public let count: Int

  public init(key: String, label: String, count: Int) {
    self.key = key
    self.label = label
    self.count = count
  }
}

// 대기 중이거나 실행 중이거나 끝난 작업 하나의 상태. 앱 지원 폴더의 work/<id>/run.json 에 기록과 함께 남긴다.
public struct JobSnapshot: Sendable, Codable, Equatable, Identifiable {
  public let id: String
  public let type: String
  public let typeLabel: String
  public let title: String
  // 작업 대상 (자료 id 나 과목 id)
  public var target: String?
  public var phase: String
  public var phaseLabel: String
  public let queuedAt: String
  public var startedAt: String?
  public var endedAt: String?
  public var error: String?
  public var counts: [JobCount]?
  public var warnings: [String]?
  public var turns: Int?
  // 지금 도는 에이전트 실행에서 쓴 턴 수. 실행이 끝나면 turns 에 더하고 비운다.
  public var liveTurns: Int?
  public var costUsd: Double?
  public var model: String?
  // 단계별로 시작한 시각과 그때까지의 턴 수 (진행 화면의 단계 표시용)
  public var phaseHistory: [PhaseMark]?
  // 계정 사용량: 시작할 때 알던 값(몰랐으면 시작한 뒤 처음 받은 값)과 끝날 때 값. 계정 전체 값이라 함께 돈 작업의 사용도 들어 있다.
  public var usageStart: UsageReading?
  public var usageEnd: UsageReading?
  // 함께 돈 작업의 id
  public var companions: [String]?

  public struct PhaseMark: Sendable, Codable, Equatable {
    public let phase: String
    public let at: String
    public let turns: Int
  }

  public static let terminalPhases: Set<String> = ["done", "failed", "cancelled", "interrupted"]
  public static let commonPhaseLabels = [
    "queued": "대기", "waiting": "다른 작업 기다림", "done": "완료", "failed": "실패", "cancelled": "취소됨", "interrupted": "중단됨",
  ]

  public var isActive: Bool { phase != "queued" && !Self.terminalPhases.contains(phase) }
  // 화면에 보일 턴 수 (끝난 실행 + 지금 실행)
  public var shownTurns: Int? { turns == nil && liveTurns == nil ? nil : (turns ?? 0) + (liveTurns ?? 0) }
  public var isFinished: Bool { Self.terminalPhases.contains(phase) }
  public var kind: JobKind? { JobKind(rawValue: type) }
}

// run.json: 상태와 마지막 기록
public struct RunRecord: Codable, Sendable {
  public var snapshot: JobSnapshot
  public var logs: [LogEntry]

  public init(snapshot: JobSnapshot, logs: [LogEntry]) {
    self.snapshot = snapshot
    self.logs = logs
  }

  enum CodingKeys: String, CodingKey { case logs }

  public init(from decoder: Decoder) throws {
    snapshot = try JobSnapshot(from: decoder)
    logs = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([LogEntry].self, forKey: .logs) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    try snapshot.encode(to: encoder)
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(logs, forKey: .logs)
  }
}

// 작업이 실행 중에 쓰는 통로. 기록, 단계, 사용량, 결과 요약을 작업 관리자에 알린다.
public struct JobContext: Sendable {
  public let id: String
  public let data: DataFolder
  public let folders: AppFolders
  public let config: RunnerConfig
  let sink: JobSink

  public init(id: String, data: DataFolder, folders: AppFolders, config: RunnerConfig, sink: JobSink) {
    self.id = id
    self.data = data
    self.folders = folders
    self.config = config
    self.sink = sink
  }

  // 이 작업의 작업 폴더 (앱 지원 폴더의 work/<id>/)
  public var workDir: URL { folders.workDir(id) }

  public func log(_ kind: LogKind, _ message: String) async {
    await sink.log(kind, message)
  }

  public func setPhase(_ phase: String) async {
    await sink.setPhase(phase)
  }

  public func addUsage(_ result: AgentResult) async {
    await sink.addUsage(turns: result.turns, cost: result.costUsd)
  }

  // 지금 도는 에이전트 실행의 턴 수 (AgentOptions.onTurns 에 넘긴다)
  public func setLiveTurns(_ turns: Int) async {
    await sink.setLiveTurns(turns)
  }

  public func report(counts: [JobCount]? = nil, warnings: [String]? = nil) async {
    await sink.report(counts: counts, warnings: warnings)
  }

  // 뒤따르는 작업을 제 대기열에 따로 넣는다. 이 작업을 넣을 때의 설정을 그대로 쓴다.
  // 다음 작업은 입력을 요청할 때가 아니라 시작할 때 다시 고른다. 넣은 작업 id, 넣지 못했으면 nil (what: 기록에 남길 작업 이름).
  public func queueFollowUp(_ what: String, _ prepare: @escaping @Sendable (PrepareContext) async throws -> PreparedJob) async -> String? {
    await sink.queueFollowUp(what, prepare)
  }

  // 취소되었으면 멈춘다
  public func checkCancellation() throws {
    try Task.checkCancellation()
  }
}

// 작업 관리자 쪽 받는 곳. 시험에서는 가짜를 쓴다.
public protocol JobSink: Sendable {
  func log(_ kind: LogKind, _ message: String) async
  func setPhase(_ phase: String) async
  func addUsage(turns: Int?, cost: Double?) async
  func setLiveTurns(_ turns: Int) async
  func report(counts: [JobCount]?, warnings: [String]?) async
  func queueFollowUp(_ what: String, _ prepare: @escaping @Sendable (PrepareContext) async throws -> PreparedJob) async -> String?
}

extension JobSink {
  public func setLiveTurns(_ turns: Int) async {}
  public func queueFollowUp(_ what: String, _ prepare: @escaping @Sendable (PrepareContext) async throws -> PreparedJob) async -> String? { nil }
}

public struct PrepareContext: Sendable {
  public let now: Date
  public let data: DataFolder
  public let folders: AppFolders
  public let config: RunnerConfig
  // 이미 쓰였거나 대기 중인 작업 id 인지
  public let taken: @Sendable (String) -> Bool

  public init(now: Date, data: DataFolder, folders: AppFolders, config: RunnerConfig, taken: @escaping @Sendable (String) -> Bool) {
    self.now = now
    self.data = data
    self.folders = folders
    self.config = config
    self.taken = taken
  }
}

// 입력 검증과 고정까지 마친, 실행만 남은 작업
public struct PreparedJob: Sendable {
  public let id: String
  public let kind: JobKind
  public let title: String
  // 같은 값을 가진 작업은 함께 돌지 않고 차례로 돈다 (예: 같은 개념의 부분 다시 만들기)
  public let serialKey: String?
  // 작업 대상 (자료 id 나 과목 id). 화면이 자료마다, 과목마다 진행 상태를 보일 때 쓴다.
  public let target: String?
  // 같은 값의 작업이 아직 시작하지 않고 대기열에 있으면 새로 넣지 않는다 (뒤따르는 작업이 겹칠 때). 시작할 때 할 일을 다시 고르므로 하나면 된다.
  public let coalesceKey: String?
  // 끝까지 가면 완료, 오류를 던지면 실패. 취소되면 취소로 본다.
  public let run: @Sendable (JobContext) async throws -> Void

  public init(
    id: String, kind: JobKind, title: String, serialKey: String? = nil, target: String? = nil, coalesceKey: String? = nil,
    run: @escaping @Sendable (JobContext) async throws -> Void
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.serialKey = serialKey
    self.target = target
    self.coalesceKey = coalesceKey
    self.run = run
  }
}
