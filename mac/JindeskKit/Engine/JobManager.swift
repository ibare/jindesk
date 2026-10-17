// 작업 대기열과 실행 상태. 대기열은 종류마다 따로 있어(JobLane) 대기열마다 정한 수까지 함께 실행하고, 나머지는 기다린다.
// 자리가 찬 대기열의 작업은 건너뛰고 뒤의 작업을 먼저 시작한다. 대화 대기열에 먼저 자리를 준다.
// 마이그레이션은 다른 작업이 모두 끝난 뒤 혼자 돈다. 같은 serialKey(예: 같은 개념)의 작업은 차례로 돈다.
// 5시간 사용량이 정한 값을 넘으면 새 작업을 시작하지 않고 초기화 시각까지 미룬다 (진행 중인 작업은 그대로 둔다).
// 업데이트 설치, 백업 만들기처럼 작업을 멈춰야 할 때는 hold 로 새 작업을 시작하지 않는다.
// 앱과 명령줄이 같은 데이터 폴더에서 동시에 작업을 돌리지 않도록, 작업이 하나라도 도는 동안 meta/.lock 을 쥔다.
import Foundation
import Observation

// 대기 중인 작업이 아직 시작하지 못한 이유
public enum JobBlocker: Sendable, Equatable {
  // 다른 Jindesk 프로세스가 이 데이터 폴더에서 작업 중이다
  case otherProcess
  // 업데이트 설치나 백업을 위해 새 작업을 멈췄다
  case held(JobHold)
  // 마이그레이션이 혼자 돌아야 한다 (마이그레이션이 기다리거나 돌고 있거나, 마이그레이션이 다른 작업을 기다린다)
  case exclusive
  // 같은 대상(serialKey)의 작업이 돌고 있다
  case serial(String)
  // 5시간 사용량이 미루는 기준(%)을 넘었다
  case usage(UsageWindow, threshold: Int)
  // 그 대기열의 자리가 찼다 (함께 돌리는 수)
  case slots(JobLane, Int)
}

// 새 작업을 멈추는 까닭
public enum JobHold: String, Sendable, CaseIterable {
  case update, backup, migration

  public var label: String {
    switch self {
    case .update: "업데이트 설치를 기다림"
    case .backup: "백업 만드는 중"
    case .migration: "데이터 모양 바꾸는 중"
    }
  }
}

@MainActor
@Observable
public final class JobManager {
  // 진행 중인 작업 (시작한 순서). 다른 프로세스를 기다리는 작업(waiting)도 여기 있다.
  public private(set) var active: [JobSnapshot] = []
  public private(set) var queue: [JobSnapshot] = []
  // 최근에 끝난 작업 (최근 것부터)
  public private(set) var recent: [JobSnapshot] = []
  // 작업별 기록 (진행 중이거나 최근에 끝난 작업)
  public private(set) var logsByID: [String: [LogEntry]] = [:]
  // 계정 사용량. 함께 도는 작업 가운데 가장 늦게 받은 값이고, 앱 지원 폴더의 usage.json 에 남는다.
  public private(set) var usage: UsageReading?
  // 사람이 사용량 미루기를 건너뛰고 시작하라고 한 대기 작업
  public private(set) var forced: Set<String> = []
  // 새 작업을 멈춘 까닭들
  public private(set) var holds: Set<JobHold> = []
  // 사용량 초기화 시각이 지나 미룸이 풀릴 때 올린다 (화면이 대기 사유를 다시 계산하는 기준)
  public private(set) var tick = 0

  // 대기열마다 함께 돌릴 작업 수
  public private(set) var limits: [JobLane: Int] = Dictionary(uniqueKeysWithValues: JobLane.allCases.map { ($0, $0.defaultLimit) })
  // 5시간 사용량이 이 값(%) 이상이면 새 작업을 시작하지 않는다. nil 이면 미루지 않는다.
  public var holdAtPercent: Int? {
    didSet { if holdAtPercent != oldValue { pump() } }
  }

  public let data: DataFolder
  public let folders: AppFolders
  // 작업이 끝날 때마다 부른다 (알림, 업데이트 설치)
  @ObservationIgnored public var onFinish: ((JobSnapshot) -> Void)?
  // 기록이 한 줄 더해질 때마다 부른다 (명령줄 출력)
  @ObservationIgnored public var onLog: ((LogEntry) -> Void)?
  @ObservationIgnored public var onPhase: ((JobSnapshot) -> Void)?

  private struct Pending {
    let snapshot: JobSnapshot
    let job: PreparedJob
    let config: RunnerConfig
  }

  @ObservationIgnored private var pending: [Pending] = []
  // 진행 중인 작업의 serialKey
  @ObservationIgnored private var serialKeys: [String: String] = [:]
  // 작업마다 실행을 이끄는 일(대기열에서 꺼낸 뒤 끝날 때까지)과 그 안의 작업 본체. 취소는 본체만 취소한다.
  @ObservationIgnored private var runners: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var works: [String: Task<Void, Error>] = [:]
  @ObservationIgnored private var cancelRequested: Set<String> = []
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var seq = 0
  @ObservationIgnored private var waiters: [String: [CheckedContinuation<JobSnapshot, Never>]] = [:]
  @ObservationIgnored private var finished: [String: JobSnapshot] = [:]
  @ObservationIgnored private let lock: DataLock
  @ObservationIgnored private var usageWake: Task<Void, Never>?

  static let logBuffer = 1000
  static let recentLimit = 8
  public static let concurrencyRange = 1...3

  public init(data: DataFolder, folders: AppFolders) {
    self.data = data
    self.folders = folders
    lock = DataLock(data)
    usage = UsageReading.load(folders)
  }

  public var isBusy: Bool { !active.isEmpty || !queue.isEmpty }

  public func limit(_ lane: JobLane) -> Int { limits[lane] ?? lane.defaultLimit }

  // 자료와 대화 대기열만 바꿀 수 있다
  public func setLimit(_ lane: JobLane, _ count: Int) {
    guard lane.adjustable else { return }
    let n = min(max(count, Self.concurrencyRange.lowerBound), Self.concurrencyRange.upperBound)
    guard limits[lane] != n else { return }
    limits[lane] = n
    pump()
  }

  // 새 작업을 멈춘다. 진행 중인 작업은 그대로 둔다.
  public func hold(_ reason: JobHold) {
    holds.insert(reason)
  }

  public func release(_ reason: JobHold) {
    guard holds.remove(reason) != nil else { return }
    pump()
  }

  // 그 대기열에서 진행 중인 작업
  public func active(in lane: JobLane) -> [JobSnapshot] { active.filter { $0.kind?.lane == lane } }

  // 진행 중이거나 최근에 끝난 작업
  public func snapshot(_ id: String) -> JobSnapshot? {
    active.first { $0.id == id } ?? recent.first { $0.id == id }
  }

  public func isActive(_ id: String) -> Bool { active.contains { $0.id == id } }

  public func logs(_ id: String) -> [LogEntry] { logsByID[id] ?? [] }

  // 입력을 검증하고 고정한 뒤 대기열에 넣는다. 실행 완료를 기다리지 않는다.
  @discardableResult
  public func submit(config: RunnerConfig, _ prepare: @escaping (PrepareContext) async throws -> PreparedJob) async throws -> String {
    try await submitAll(config: config, [prepare])[0]
  }

  // 여러 작업을 한꺼번에 대기열에 넣는다. 모두 준비한 뒤에 넣으므로, 하나라도 준비에 실패하면 아무것도 넣지 않는다.
  @discardableResult
  public func submitAll(config: RunnerConfig, _ prepares: [(PrepareContext) async throws -> PreparedJob]) async throws -> [String] {
    let data = data
    let folders = folders
    var jobs: [PreparedJob] = []
    for prepare in prepares {
      // 앞서 준비한 작업의 id 도 쓰인 것으로 본다
      let used = Set(queue.map(\.id) + active.map(\.id) + jobs.map(\.id))
      let context = PrepareContext(now: Date(), data: data, folders: folders, config: config) { id in
        used.contains(id) || FileOps.exists(folders.workDir(id)) || JobKind.allCases.contains { FileOps.exists(data.record($0.rawValue, id)) }
      }
      jobs.append(try await prepare(context))
    }
    // 준비하는 동안 같은 id 가 대기열에 들어왔으면 거절한다
    var ids: Set<String> = []
    for job in jobs where pending.contains(where: { $0.snapshot.id == job.id }) || isActive(job.id) || !ids.insert(job.id).inserted {
      throw RequestError("이미 대기 중인 작업 id 입니다: \(job.id)")
    }
    var out: [String] = []
    for job in jobs {
      // 같은 일을 할 작업이 아직 시작하지 않고 기다리면 그 작업으로 갈음한다
      if let key = job.coalesceKey, let waiting = pending.first(where: { $0.job.coalesceKey == key }) {
        out.append(waiting.snapshot.id)
        continue
      }
      let snapshot = JobSnapshot(
        id: job.id, type: job.kind.rawValue, typeLabel: job.kind.label, title: job.title, target: job.target, phase: "queued", phaseLabel: "대기",
        queuedAt: Clock.isoLocal())
      pending.append(Pending(snapshot: snapshot, job: job, config: config))
      out.append(job.id)
    }
    queue = pending.map(\.snapshot)
    pump()
    return out
  }

  // id 를 주면 그 작업을 취소한다(대기 중이면 대기열에서 뺀다). 주지 않으면 진행 중인 작업을 모두 취소한다.
  @discardableResult
  public func cancel(_ id: String? = nil) -> Bool {
    guard let id else {
      let ids = active.map(\.id)
      for id in ids { cancelActive(id) }
      return !ids.isEmpty
    }
    if isActive(id) {
      cancelActive(id)
      return true
    }
    guard let i = pending.firstIndex(where: { $0.snapshot.id == id }) else { return false }
    pending.remove(at: i)
    queue = pending.map(\.snapshot)
    forced.remove(id)
    pump()
    return true
  }

  private func cancelActive(_ id: String) {
    guard !cancelRequested.contains(id) else { return }
    log(id, .warn, "취소 요청을 받았습니다")
    cancelRequested.insert(id)
    works[id]?.cancel()
  }

  // 사용량 미루기를 건너뛰고 시작한다. 대기열의 자리는 그대로 따른다.
  public func startDespiteUsage(_ id: String) {
    guard pending.contains(where: { $0.snapshot.id == id }) else { return }
    forced.insert(id)
    pump()
  }

  // 대기 중인 작업이 왜 아직 시작하지 않았는지. 대기열에 없으면 nil.
  public func blocker(_ id: String) -> JobBlocker? {
    _ = tick
    guard let index = pending.firstIndex(where: { $0.snapshot.id == id }) else { return nil }
    return blocker(index, now: Date())
  }

  private func blocker(_ index: Int, now: Date) -> JobBlocker? {
    let item = pending[index]
    let lane = item.job.kind.lane
    if active.contains(where: { $0.phase == "waiting" }) { return .otherProcess }
    if let hold = JobHold.allCases.first(where: holds.contains) { return .held(hold) }
    if lane == .migration {
      if active.contains(where: { $0.kind?.lane != .migration }) { return .exclusive }
    } else if active.contains(where: { $0.kind?.lane == .migration }) || pending.contains(where: { $0.job.kind.lane == .migration }) {
      return .exclusive
    }
    if let key = item.job.serialKey, serialKeys.values.contains(key) { return .serial(key) }
    if !forced.contains(item.snapshot.id), let hold = usageHold(at: now) { return .usage(hold.window, threshold: hold.threshold) }
    if active(in: lane).count >= limit(lane) { return .slots(lane, limit(lane)) }
    return nil
  }

  // 5시간 사용량이 미루는 기준을 넘었으면 그 창과 기준
  public func usageHold(at now: Date = Date()) -> (window: UsageWindow, threshold: Int)? {
    _ = tick
    guard let threshold = holdAtPercent, let w = usage?.fiveHour, w.isCurrent(at: now), w.percent >= threshold else { return nil }
    return (w, threshold)
  }

  // 대기열과 진행 중인 작업이 모두 끝날 때까지 기다린다 (명령줄에서 뒤따르는 작업까지 볼 때)
  public func waitUntilIdle() async {
    while isBusy {
      if let id = active.first?.id ?? queue.first?.id { _ = await waitForEnd(id) } else { try? await Task.sleep(for: .milliseconds(200)) }
    }
  }

  // 그 작업이 끝날 때까지 기다린다 (명령줄에서 쓴다)
  public func waitForEnd(_ id: String) async -> JobSnapshot {
    if let done = finished[id] { return done }
    return await withCheckedContinuation { waiters[id, default: []].append($0) }
  }

  // 앱이 끝날 때: 대기열을 비우고 진행 중인 작업을 모두 취소한다
  public func shutdown() {
    stopped = true
    pending.removeAll()
    queue = []
    for s in active {
      cancelRequested.insert(s.id)
      works[s.id]?.cancel()
    }
    usageWake?.cancel()
  }

  // 다른 프로세스(명령줄)가 남긴 사용량이 더 새것이면 받는다
  public func reloadUsage() {
    guard let saved = UsageReading.load(folders), UsageReading.newer(usage, saved) == saved, saved != usage else { return }
    usage = saved
    pump()
  }

  // 막힌 이유가 없는 작업을 시작한다. 대기열 차례(대화 먼저)대로, 같은 차례면 넣은 순서대로 본다. 막힌 작업은 건너뛴다.
  private func pump() {
    guard !stopped else { return }
    let now = Date()
    while true {
      let order = pending.indices.sorted { a, b in
        let pa = pending[a].job.kind.lane.priority
        let pb = pending[b].job.kind.lane.priority
        return pa != pb ? pa < pb : a < b
      }
      guard let i = order.first(where: { blocker($0, now: now) == nil }) else { break }
      let item = pending.remove(at: i)
      queue = pending.map(\.snapshot)
      // 이미 쥐고 있으면 바로 잡힌다. 다른 프로세스가 쥐고 있으면 이 작업 하나만 띄워 기다리게 한다.
      let locked = lock.tryAcquire()
      start(item, locked: locked)
      if !locked { break }
    }
    scheduleUsageWake(now)
  }

  private func start(_ item: Pending, locked: Bool) {
    var s = item.snapshot
    s.startedAt = Clock.isoLocal()
    s.usageStart = currentUsage()
    s.model = item.config.model
    // 함께 도는 작업을 서로 적어 둔다
    if !active.isEmpty {
      s.companions = active.map(\.id)
      for i in active.indices { active[i].companions = (active[i].companions ?? []) + [s.id] }
    }
    active.append(s)
    logsByID[s.id] = []
    forced.remove(s.id)
    if let key = item.job.serialKey { serialKeys[s.id] = key }
    let id = s.id
    runners[id] = Task { [weak self] in await self?.run(id, item, locked: locked) }
  }

  private func run(_ id: String, _ item: Pending, locked: Bool) async {
    // 다른 프로세스(명령줄 또는 다른 앱)가 같은 데이터 폴더에서 작업 중이면 끝나기를 기다린다.
    // 기다리는 동안은 "다른 작업 기다림" 단계로 두어 화면에 보이고 취소할 수 있다.
    if !locked {
      setPhase(id, "waiting")
      log(id, .warn, "다른 Jindesk 프로세스가 이 데이터 폴더에서 작업 중입니다. 끝나기를 기다립니다")
      while !lock.tryAcquire() {
        if stopped || cancelRequested.contains(id) { break }
        try? await Task.sleep(for: .seconds(1))
      }
    }
    if stopped || cancelRequested.contains(id) || !lock.isHeld {
      end(id, "cancelled")
      finish(id)
      return
    }

    setPhase(id, item.job.kind.phases.first?.id ?? "running")
    writeRunRecord(id)
    // 잠금을 기다리느라 비워 둔 자리를 채운다
    if !locked { pump() }

    var config = item.config
    let manager = self
    config.onUsage = { reading in Task { @MainActor in manager.record(reading) } }
    let context = JobContext(id: id, data: data, folders: folders, config: config, sink: ManagerSink(manager: self, id: id, config: item.config))
    let job = item.job
    // 작업 본체는 메인 스레드 밖에서 돈다. 취소는 이 작업(Task)을 취소해 전한다.
    let work = Task.detached { try await job.run(context) }
    works[id] = work
    let outcome = await work.result
    works[id] = nil

    switch outcome {
    case .success:
      end(id, work.isCancelled ? "cancelled" : "done")
    case .failure(let error):
      if work.isCancelled || error is CancellationError {
        end(id, "cancelled")
      } else {
        end(id, "failed", error: error.localizedDescription)
      }
    }
    finish(id)
  }

  private func finish(_ id: String) {
    writeRunRecord(id)
    guard let i = active.firstIndex(where: { $0.id == id }) else { return }
    let done = active.remove(at: i)
    appendRunSummary(done)
    recent = Array(([done] + recent.filter { $0.id != id }).prefix(Self.recentLimit))
    for key in logsByID.keys where !isActive(key) && !recent.contains(where: { $0.id == key }) { logsByID[key] = nil }
    runners[id] = nil
    serialKeys[id] = nil
    cancelRequested.remove(id)
    if active.isEmpty { lock.release() }
    finished[id] = done
    for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume(returning: done) }
    onFinish?(done)
    pump()
  }

  // 사용량을 받았다. 늦게 받은 값만 쓴다.
  func record(_ reading: UsageReading) {
    guard UsageReading.newer(usage, reading) == reading else { return }
    usage = reading
    // 시작할 때 사용량을 몰랐던 작업은 처음 받은 값을 시작 값으로 삼는다
    for i in active.indices where active[i].usageStart == nil { active[i].usageStart = reading }
    reading.save(folders)
    pump()
  }

  // 초기화 시각이 지나지 않은 사용량 (모르면 nil)
  private func currentUsage(_ now: Date = Date()) -> UsageReading? {
    guard let usage, usage.fiveHour?.isCurrent(at: now) == true || usage.sevenDay?.isCurrent(at: now) == true else { return nil }
    return usage
  }

  // 사용량 때문에 미룬 작업이 있으면 5시간 창이 초기화될 때 다시 본다
  private func scheduleUsageWake(_ now: Date) {
    guard usageWake == nil, !queue.isEmpty, let hold = usageHold(at: now) else { return }
    let delay = max(1, hold.window.resetDate.timeIntervalSince(now) + 2)
    usageWake = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard let self, !Task.isCancelled else { return }
      self.usageWake = nil
      self.tick += 1
      self.pump()
    }
  }

  // 사본을 고쳐 한 번에 바꾼다 (고치는 동안 다시 읽으면 접근 충돌이 난다)
  private func update(_ id: String, _ change: (inout JobSnapshot) -> Void) {
    guard let i = active.firstIndex(where: { $0.id == id }) else { return }
    var s = active[i]
    change(&s)
    active[i] = s
  }

  func setPhase(_ id: String, _ phase: String) {
    update(id) { s in
      s.phase = phase
      s.phaseLabel = s.kind?.phaseLabel(phase) ?? JobSnapshot.commonPhaseLabels[phase] ?? phase
      if !JobSnapshot.terminalPhases.contains(phase) {
        s.phaseHistory = (s.phaseHistory ?? []) + [.init(phase: phase, at: Clock.isoLocal(), turns: s.turns ?? 0)]
      }
    }
    if let s = snapshot(id) { onPhase?(s) }
  }

  private func end(_ id: String, _ phase: String, error: String? = nil) {
    if let error { log(id, .error, error) }
    let usage = currentUsage()
    update(id) { s in
      if let error { s.error = error }
      // 끝을 알리지 못한 실행(취소 등)의 턴도 남긴다
      if let live = s.liveTurns { s.turns = (s.turns ?? 0) + live }
      s.liveTurns = nil
      s.endedAt = Clock.isoLocal()
      if s.usageStart != nil { s.usageEnd = usage }
    }
    setPhase(id, phase)
  }

  func log(_ id: String, _ kind: LogKind, _ message: String) {
    seq += 1
    let entry = LogEntry(seq: seq, at: Clock.isoLocal(), kind: kind, message: message)
    var lines = logsByID[id] ?? []
    lines.append(entry)
    if lines.count > Self.logBuffer { lines.removeFirst(lines.count - Self.logBuffer) }
    logsByID[id] = lines
    onLog?(entry)
  }

  func addUsage(_ id: String, turns: Int?, cost: Double?) {
    update(id) { s in
      // 실행이 끝났다. 알린 턴 수가 있으면 그것을, 없으면(취소 등) 실행 중에 센 값을 남긴다.
      if let t = turns ?? s.liveTurns { s.turns = (s.turns ?? 0) + t }
      s.liveTurns = nil
      if let cost { s.costUsd = (s.costUsd ?? 0) + cost }
    }
  }

  func setLiveTurns(_ id: String, _ turns: Int) {
    guard snapshot(id)?.liveTurns != turns else { return }
    update(id) { $0.liveTurns = turns }
  }

  func report(_ id: String, counts: [JobCount]?, warnings: [String]?) {
    update(id) { s in
      if let counts { s.counts = counts }
      if let warnings { s.warnings = warnings }
    }
  }

  // 작업이 끝낸 일에 뒤따르는 작업을 제 대기열에 넣는다. 넣은 작업 id, 넣지 못했으면 nil.
  func queueFollowUp(_ what: String, _ prepare: @escaping @Sendable (PrepareContext) async throws -> PreparedJob, config: RunnerConfig, from: String) async
    -> String?
  {
    do {
      return try await submit(config: config, prepare)
    } catch {
      log(from, .warn, "\(what) 작업을 대기열에 넣지 못했습니다: \(error.localizedDescription). 따로 다시 실행할 수 있습니다")
      return nil
    }
  }

  private func writeRunRecord(_ id: String) {
    guard let s = active.first(where: { $0.id == id }) else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    guard let data = try? encoder.encode(RunRecord(snapshot: s, logs: logs(id))) else { return }
    try? FileOps.write(data, to: folders.workDir(id).appending(path: "run.json"))
  }

  // 데이터 폴더의 records/runs/<YYYY-MM>.jsonl 에 실행 요약 한 줄을 덧붙인다 (작업 id, 종류, 시작·끝, 결과, 사용량, 모델)
  private func appendRunSummary(_ s: JobSnapshot) {
    try? FileOps.appendLine(JSONText.line(RunSummary.line(s)), to: data.runsLog())
  }

  // 앱이 비정상 종료해 run.json 이 진행 중으로 남은 작업을 중단됨으로 고친다. 앱을 켤 때 부른다.
  public static func markInterrupted(data: DataFolder, folders: AppFolders) -> [String] {
    var fixed: [String] = []
    let lock = DataLock(data)
    // 다른 프로세스가 작업 중이면 그 작업을 건드리지 않는다
    guard lock.tryAcquire() else { return [] }
    defer { lock.release() }
    for id in FileOps.list(folders.work) where JobID.isValid(id) {
      let file = folders.workDir(id).appending(path: "run.json")
      guard let content = try? Data(contentsOf: file), var record = try? JSONDecoder().decode(RunRecord.self, from: content),
        record.snapshot.isActive
      else { continue }
      record.snapshot.phase = "interrupted"
      record.snapshot.phaseLabel = "중단됨"
      record.snapshot.error = record.snapshot.error ?? "앱이 끝나 작업이 중단되었습니다"
      record.snapshot.endedAt = record.snapshot.endedAt ?? Clock.isoLocal()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
      if let out = try? encoder.encode(record) { try? FileOps.write(out, to: file) }
      try? FileOps.appendLine(JSONText.line(RunSummary.line(record.snapshot)), to: data.runsLog())
      fixed.append(id)
    }
    return fixed
  }
}

// records/runs/<YYYY-MM>.jsonl 의 한 줄
enum RunSummary {
  static func line(_ s: JobSnapshot) -> JSONValue {
    var o: [String: JSONValue] = [
      "v": .number(1), "id": .string(s.id), "kind": .string(s.type), "title": .string(s.title), "queued": .string(s.queuedAt),
      "result": .string(s.phase),
    ]
    if let v = s.startedAt { o["started"] = .string(v) }
    if let v = s.endedAt { o["ended"] = .string(v) }
    if let v = s.error { o["error"] = .string(v) }
    if let v = s.turns { o["turns"] = .number(Double(v)) }
    if let v = s.costUsd { o["cost_usd"] = .number(v) }
    if let v = s.model { o["model"] = .string(v) }
    if let v = s.usageStart { o["usage_start"] = v.json }
    if let v = s.usageEnd { o["usage_end"] = v.json }
    return .object(o)
  }
}

// 작업 쪽에서 관리자에 알리는 통로 (작업 하나에 하나)
struct ManagerSink: JobSink {
  let manager: JobManager
  let id: String
  // 그 작업을 넣을 때의 설정 (뒤따르는 작업에 그대로 쓴다)
  let config: RunnerConfig

  func log(_ kind: LogKind, _ message: String) async {
    await manager.log(id, kind, message)
  }

  func setPhase(_ phase: String) async {
    await manager.setPhase(id, phase)
  }

  func addUsage(turns: Int?, cost: Double?) async {
    await manager.addUsage(id, turns: turns, cost: cost)
  }

  func setLiveTurns(_ turns: Int) async {
    await manager.setLiveTurns(id, turns)
  }

  func report(counts: [JobCount]?, warnings: [String]?) async {
    await manager.report(id, counts: counts, warnings: warnings)
  }

  func queueFollowUp(_ what: String, _ prepare: @escaping @Sendable (PrepareContext) async throws -> PreparedJob) async -> String? {
    await manager.queueFollowUp(what, prepare, config: config, from: id)
  }
}

// 지난 실행 (앱 지원 폴더의 work/<id>/run.json). 작업 화면의 "최근 작업" 목록에 쓴다.
public enum RunHistory {
  public static func load(_ folders: AppFolders, limit: Int = 50) -> [RunRecord] {
    FileOps.list(folders.work).filter(JobID.isValid).sorted(by: >).prefix(limit).compactMap { id in
      load(folders, id: id)
    }
  }

  public static func load(_ folders: AppFolders, id: String) -> RunRecord? {
    guard let data = try? Data(contentsOf: folders.workDir(id).appending(path: "run.json")) else { return nil }
    return try? JSONDecoder().decode(RunRecord.self, from: data)
  }
}
