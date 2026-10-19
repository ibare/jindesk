import Foundation
import Testing
@testable import JindeskKit

// 테스트가 풀어 줄 때까지 기다리는 가짜 작업
final class Gates: @unchecked Sendable {
  private let lock = NSLock()
  private var gates: [String: CheckedContinuation<Void, Error>] = [:]
  private var early: [String: Bool] = [:]
  private(set) var order: [String] = []

  func wait(_ id: String) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        lock.withLock {
          order.append(id)
          if let fail = early.removeValue(forKey: id) {
            fail ? c.resume(throwing: ToolError("실패함")) : c.resume()
          } else {
            gates[id] = c
          }
        }
      }
    } onCancel: {
      lock.withLock { gates.removeValue(forKey: id) }?.resume(throwing: CancellationError())
    }
  }

  func release(_ id: String, fail: Bool = false) {
    let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in
      if let c = gates.removeValue(forKey: id) { return c }
      early[id] = fail
      return nil
    }
    if fail { c?.resume(throwing: ToolError("실패함")) } else { c?.resume() }
  }

  var started: [String] { lock.withLock { order } }
}

@MainActor
@Suite struct JobManagerTests {
  func fake(_ id: String, _ gates: Gates, kind: JobKind = .conceptCuration, serial: String? = nil, usage: UsageReading? = nil)
    -> (PrepareContext) async throws -> PreparedJob
  {
    { ctx in
      if ctx.taken(id) { throw RequestError("이미 있는 id: \(id)") }
      return PreparedJob(id: id, kind: kind, title: id, serialKey: serial) { context in
        if let usage { context.config.onUsage?(usage) }
        await context.setPhase("running")
        await context.log(.info, "시작")
        await context.addUsage(AgentResult(status: .ok, turns: 3, costUsd: 0.5))
        await context.addUsage(AgentResult(status: .ok, turns: 2, costUsd: 0.25))
        await context.report(counts: [JobCount(key: "entries", label: "엔트리", count: 4)], warnings: ["경고"])
        try await gates.wait(id)
      }
    }
  }

  func tick() async { try? await Task.sleep(for: .milliseconds(40)) }

  func manager(_ t: TempPlace) throws -> JobManager {
    try t.data.initialize(app: testApp)
    return JobManager(data: t.data, folders: t.folders)
  }

  @Test func 한_대기열_안에서는_들어온_순서대로_하나씩_실행하고_실행_요약을_남긴다() async throws {
    let gates = Gates()
    let t = TempPlace()
    let m = try manager(t)
    try await m.submit(config: testConfig, fake("20261016-1000-a", gates))
    try await m.submit(config: testConfig, fake("20261016-1000-b", gates))
    await tick()
    #expect(gates.started == ["20261016-1000-a"])
    #expect(m.active.map(\.phase) == ["running"])
    #expect(m.blocker("20261016-1000-b") == .slots(.curation, 1))
    #expect(m.active.first?.turns == 5 && m.active.first?.costUsd == 0.75 && m.active.first?.model == RunnerConfig.defaultModel)
    // 작업 중에는 데이터 폴더 잠금을 쥔다
    #expect(!DataLock(t.data).tryAcquire())
    gates.release("20261016-1000-a")
    let a = await m.waitForEnd("20261016-1000-a")
    #expect(a.phase == "done" && a.endedAt != nil && a.warnings == ["경고"] && a.counts?.first?.count == 4)
    await tick()
    #expect(gates.started == ["20261016-1000-a", "20261016-1000-b"])
    gates.release("20261016-1000-b")
    #expect(await m.waitForEnd("20261016-1000-b").phase == "done")
    // 작업이 모두 끝나면 잠금을 푼다
    let lock = DataLock(t.data)
    #expect(lock.tryAcquire())
    lock.release()
    // records/runs/<YYYY-MM>.jsonl 에 실행 요약이 한 줄씩 남는다
    let runs = try JSONLines.read(t.data.runsLog()).values
    #expect(runs.map { $0["id"]?.stringValue } == ["20261016-1000-a", "20261016-1000-b"])
    #expect(runs[0]["kind"] == .string("concept-curation") && runs[0]["result"] == .string("done") && runs[0]["turns"] == .number(5))
    #expect(FileOps.exists(t.folders.workDir("20261016-1000-a").appending(path: "run.json")))
  }

  @Test func 실패해도_다음_작업을_실행하고_대기_중인_id_는_다시_쓰지_않는다() async throws {
    let gates = Gates()
    let m = try manager(TempPlace())
    try await m.submit(config: testConfig, fake("20261016-1000-c", gates))
    try await m.submit(config: testConfig, fake("20261016-1000-d", gates))
    await #expect(throws: RequestError.self) { try await m.submit(config: testConfig, fake("20261016-1000-d", gates)) }
    await tick()
    gates.release("20261016-1000-c", fail: true)
    let c = await m.waitForEnd("20261016-1000-c")
    #expect(c.phase == "failed" && c.error == "실패함")
    await tick()
    gates.release("20261016-1000-d")
    #expect(await m.waitForEnd("20261016-1000-d").phase == "done")
  }

  @Test func 여러_작업을_넣을_때_하나라도_준비에_실패하면_아무것도_넣지_않는다() async throws {
    let gates = Gates()
    let m = try manager(TempPlace())
    let failing: (PrepareContext) async throws -> PreparedJob = { _ in throw RequestError("너무 큼") }
    await #expect(throws: RequestError.self) {
      try await m.submitAll(config: testConfig, [fake("20261016-1000-e", gates), failing, fake("20261016-1000-f", gates)])
    }
    #expect(m.queue.isEmpty && m.active.isEmpty)
    await tick()
    #expect(gates.started.isEmpty)
  }

  @Test func 같은_슬러그로_만든_id_는_겹치지_않는다() async throws {
    let gates = Gates()
    let m = try manager(TempPlace())
    let same: (PrepareContext) async throws -> PreparedJob = { ctx in
      let id = try JobID.make(date: ctx.now, slugSource: "Kinematics slides.pptx", exists: ctx.taken)
      return PreparedJob(id: id, kind: .sourceIntake, title: id) { _ in try await gates.wait(id) }
    }
    let ids = try await m.submitAll(config: testConfig, [same, same, same])
    #expect(Set(ids).count == 3)
    #expect(ids[0].hasSuffix("-kinematics-slides-pptx") && ids[1].hasSuffix("-pptx-2"))
    for id in ids { gates.release(id) }
    for id in ids { #expect(await m.waitForEnd(id).phase == "done") }
  }

  @Test func 대기_중인_작업은_대기열에서_빼고_실행_중인_작업은_취소한다() async throws {
    let gates = Gates()
    let m = try manager(TempPlace())
    try await m.submit(config: testConfig, fake("20261016-1000-g", gates))
    try await m.submit(config: testConfig, fake("20261016-1000-h", gates))
    await tick()
    #expect(m.cancel("20261016-1000-h"))
    #expect(m.queue.isEmpty)
    #expect(m.cancel("20261016-1000-g"))
    #expect(await m.waitForEnd("20261016-1000-g").phase == "cancelled")
    #expect(gates.started == ["20261016-1000-g"])
  }

  @Test func 다른_프로세스가_같은_데이터_폴더에서_작업_중이면_기다리고_취소할_수_있다() async throws {
    let gates = Gates()
    let t = TempPlace()
    let m = try manager(t)
    let other = DataLock(t.data)
    #expect(other.tryAcquire())
    try await m.submit(config: testConfig, fake("20261016-1000-i", gates))
    try await m.submit(config: testConfig, fake("20261016-1000-j", gates, kind: .ask))
    await tick()
    #expect(gates.started.isEmpty)
    #expect(m.snapshot("20261016-1000-i")?.phase == "waiting" || m.snapshot("20261016-1000-j")?.phase == "waiting")
    #expect(m.logs(m.active[0].id).contains { $0.message.contains("다른 Jindesk 프로세스") })
    other.release()
    try await Task.sleep(for: .milliseconds(2500))
    #expect(Set(gates.started) == ["20261016-1000-i", "20261016-1000-j"])
    gates.release("20261016-1000-i")
    gates.release("20261016-1000-j")
    #expect(await m.waitForEnd("20261016-1000-i").phase == "done")
  }

  @Test func 대기열마다_따로_돌고_자리가_찬_대기열의_작업은_건너뛰며_대화에_먼저_자리를_준다() async throws {
    let gates = Gates()
    let m = try manager(TempPlace())
    m.setLimit(.sources, 2)
    // 정리와 페이지 대기열은 바꾸지 않는다
    m.setLimit(.curation, 3)
    #expect(m.limit(.curation) == 1 && m.limit(.pages) == 1)
    let jobs: [(String, JobKind)] = [
      ("a", .conceptCuration), ("b", .syllabusBuild), ("c", .pageBuild), ("d", .sourceReading), ("e", .sourceIntake), ("f", .sourceReading), ("g", .ask),
    ]
    _ = try await m.submitAll(config: testConfig, jobs.map { fake("20261016-1200-\($0.0)", gates, kind: $0.1) })
    await tick()
    // 대화(g)가 먼저 시작하고, 정리 둘째 건(b)과 셋째 자료(f)는 제 대기열의 자리를 기다린다
    #expect(m.active.first?.id == "20261016-1200-g")
    #expect(Set(m.active.map(\.id)) == Set(["a", "c", "d", "e", "g"].map { "20261016-1200-\($0)" }))
    #expect(m.blocker("20261016-1200-b") == .slots(.curation, 1))
    #expect(m.blocker("20261016-1200-f") == .slots(.sources, 2))
    gates.release("20261016-1200-a")
    #expect(await m.waitForEnd("20261016-1200-a").phase == "done")
    await tick()
    #expect(m.isActive("20261016-1200-b") && !m.isActive("20261016-1200-f"))
    for id in ["b", "c", "d", "e", "f", "g"] { gates.release("20261016-1200-\(id)") }
    for id in ["b", "c", "d", "e", "f", "g"] { #expect(await m.waitForEnd("20261016-1200-\(id)").phase == "done") }
    #expect(!m.isBusy)
  }

  @Test func 같은_대상의_작업은_차례로_돈다() async throws {
    let gates = Gates()
    let m = try manager(TempPlace())
    let concept = "physics-hl/a.1/projectile-motion"
    try await m.submit(config: testConfig, fake("20261016-1300-a", gates, kind: .regen, serial: concept))
    try await m.submit(config: testConfig, fake("20261016-1300-b", gates, kind: .regen, serial: concept))
    try await m.submit(config: testConfig, fake("20261016-1300-c", gates, kind: .ask, serial: "physics-hl/b.5/series-circuits"))
    await tick()
    #expect(Set(gates.started) == ["20261016-1300-a", "20261016-1300-c"])
    #expect(m.blocker("20261016-1300-b") == .serial(concept))
    gates.release("20261016-1300-a")
    #expect(await m.waitForEnd("20261016-1300-a").phase == "done")
    await tick()
    #expect(m.isActive("20261016-1300-b"))
    gates.release("20261016-1300-b")
    gates.release("20261016-1300-c")
    #expect(await m.waitForEnd("20261016-1300-b").phase == "done")
  }

  @Test func 마이그레이션은_다른_작업이_끝난_뒤_혼자_돈다() async throws {
    let gates = Gates()
    let m = try manager(TempPlace())
    try await m.submit(config: testConfig, fake("20261016-1400-a", gates, kind: .sourceReading))
    await tick()
    try await m.submit(config: testConfig, fake("20261016-1400-m", gates, kind: .migration))
    try await m.submit(config: testConfig, fake("20261016-1400-b", gates, kind: .ask))
    await tick()
    #expect(gates.started == ["20261016-1400-a"])
    #expect(m.blocker("20261016-1400-m") == .exclusive)
    #expect(m.blocker("20261016-1400-b") == .exclusive)
    gates.release("20261016-1400-a")
    #expect(await m.waitForEnd("20261016-1400-a").phase == "done")
    await tick()
    #expect(gates.started == ["20261016-1400-a", "20261016-1400-m"])
    gates.release("20261016-1400-m")
    #expect(await m.waitForEnd("20261016-1400-m").phase == "done")
    await tick()
    #expect(gates.started.last == "20261016-1400-b")
    gates.release("20261016-1400-b")
    #expect(await m.waitForEnd("20261016-1400-b").phase == "done")
  }

  @Test func 업데이트를_기다리는_동안은_새_작업을_시작하지_않는다() async throws {
    let gates = Gates()
    let m = try manager(TempPlace())
    try await m.submit(config: testConfig, fake("20261016-1500-a", gates, kind: .sourceReading))
    await tick()
    m.hold(.update)
    try await m.submit(config: testConfig, fake("20261016-1500-b", gates, kind: .sourceReading))
    await tick()
    #expect(m.blocker("20261016-1500-b") == .held(.update))
    gates.release("20261016-1500-a")
    #expect(await m.waitForEnd("20261016-1500-a").phase == "done")
    await tick()
    #expect(m.active.isEmpty && m.queue.count == 1)
    m.release(.update)
    await tick()
    #expect(m.isActive("20261016-1500-b"))
    gates.release("20261016-1500-b")
    #expect(await m.waitForEnd("20261016-1500-b").phase == "done")
  }

  @Test func 사용량이_기준을_넘으면_새_작업을_미루고_초기화되면_시작한다() async throws {
    let gates = Gates()
    let t = TempPlace()
    let m = try manager(t)
    m.setLimit(.conversation, 3)
    m.holdAtPercent = 90
    let reset = Date().addingTimeInterval(1.5)
    let high = UsageReading(
      fiveHour: UsageWindow(utilization: 0.93, resetsAt: reset.timeIntervalSince1970),
      sevenDay: UsageWindow(utilization: 0.24, resetsAt: Date().addingTimeInterval(86400).timeIntervalSince1970), at: Clock.isoLocal())
    try await m.submit(config: testConfig, fake("20261016-1600-a", gates, kind: .ask, usage: high))
    await tick()
    #expect(m.usage == high)
    #expect(UsageReading.load(t.folders) == high)
    #expect(m.snapshot("20261016-1600-a")?.usageStart == high)
    try await m.submit(config: testConfig, fake("20261016-1600-b", gates, kind: .ask))
    try await m.submit(config: testConfig, fake("20261016-1600-c", gates, kind: .ask))
    await tick()
    #expect(m.active.map(\.id) == ["20261016-1600-a"])
    #expect(m.blocker("20261016-1600-b") == .usage(high.fiveHour!, threshold: 90))
    // 사람이 고르면 미루지 않고 시작한다
    m.startDespiteUsage("20261016-1600-b")
    await tick()
    #expect(m.active.map(\.id) == ["20261016-1600-a", "20261016-1600-b"])
    gates.release("20261016-1600-a")
    #expect(await m.waitForEnd("20261016-1600-a").usageEnd == high)
    try await Task.sleep(for: .milliseconds(3500))
    #expect(m.isActive("20261016-1600-c"))
    gates.release("20261016-1600-b")
    gates.release("20261016-1600-c")
    #expect(await m.waitForEnd("20261016-1600-c").phase == "done")
  }

  @Test func 대기열에_넣을_때_기록을_남기고_앱이_끝나면_진행_중과_대기로_남긴다() async throws {
    let gates = Gates()
    let t = TempPlace()
    let m = try manager(t)
    func job(_ id: String, _ subject: String) -> (PrepareContext) async throws -> PreparedJob {
      { _ in PreparedJob(id: id, kind: .pageBuild, title: id, recipe: .pageBuild(subject: subject)) { _ in try await gates.wait(id) } }
    }
    func phase(_ id: String) -> String? { RunHistory.load(t.folders, id: id)?.snapshot.phase }
    try await m.submitAll(config: testConfig, [job("20261019-1000-a", "physics"), job("20261019-1000-b", "math"), job("20261019-1000-c", "chem")])
    await tick()
    #expect(gates.started == ["20261019-1000-a"])
    // 시작하지 않은 작업도 run.json 이 있고, 다시 준비할 입력과 넣은 프로세스가 적혀 있다
    let queued = try #require(RunHistory.load(t.folders, id: "20261019-1000-b"))
    #expect(queued.snapshot.phase == "queued" && queued.snapshot.recipe == .pageBuild(subject: "math") && queued.owner == .current)
    // 대기열에서 뺀 작업은 남길 것이 없다
    #expect(m.cancel("20261019-1000-c"))
    #expect(!FileOps.exists(t.folders.workDir("20261019-1000-c")))
    // 작업 화면의 최근 작업에 대기 중인 작업은 보이지 않는다
    #expect(RunHistory.load(t.folders, data: t.data).map(\.snapshot.id) == ["20261019-1000-a"])

    m.shutdown()
    try await Task.sleep(for: .milliseconds(200))
    // 앱이 끝나 멈춘 작업은 취소로 적지 않는다
    #expect(phase("20261019-1000-a").map { $0 != "cancelled" && $0 != "queued" } == true)
    #expect(phase("20261019-1000-b") == "queued")
    #expect(RunHistory.load(t.folders, id: "20261019-1000-a")?.snapshot.quit == true)
    #expect(!FileOps.exists(t.data.runsLog()))
    #expect(JobManager.leftovers(data: t.data, folders: t.folders).map(\.snapshot.id) == ["20261019-1000-a", "20261019-1000-b"])
  }

  @Test func 멈춘_작업을_시작했던_것부터_같은_차례로_다시_넣고_정리한다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    func record(_ id: String, _ phase: String, queued: String, order: Int, started: String? = nil, data: String? = nil, owner: ProcessStamp? = nil)
      -> RunRecord
    {
      var s = JobSnapshot(
        id: id, type: "page-build", typeLabel: "학습 페이지 만들기", title: id, phase: phase, phaseLabel: phase, queuedAt: queued,
        dataFolder: data ?? t.data.url.path, recipe: .pageBuild(subject: id), queueOrder: order)
      s.startedAt = started
      return RunRecord(snapshot: s, logs: [], owner: owner)
    }
    // 끝난 앱(주인이 없다)이 남긴 기록: 돌던 것 둘, 대기 둘(같은 시각에 넣은 것은 넣은 차례로)
    let dead = ProcessStamp(pid: getpid(), started: 1)
    for r in [
      record("20261019-1100-q2", "queued", queued: "2026-10-19T11:00:05+09:00", order: 4, owner: dead),
      record("20261019-1100-q1", "queued", queued: "2026-10-19T11:00:05+09:00", order: 3, owner: dead),
      record("20261019-1100-r2", "running", queued: "2026-10-19T11:00:00+09:00", order: 2, started: "2026-10-19T11:00:03+09:00", owner: dead),
      record("20261019-1100-r1", "checking", queued: "2026-10-19T11:00:00+09:00", order: 1, started: "2026-10-19T11:00:01+09:00"),
      // 끝난 작업, 다른 데이터 폴더의 작업, 살아 있는 다른 프로세스(명령줄)의 작업은 건드리지 않는다
      record("20261019-1100-done", "done", queued: "2026-10-19T10:00:00+09:00", order: 1),
      record("20261019-1100-else", "running", queued: "2026-10-19T10:00:00+09:00", order: 1, data: "/somewhere/else"),
      record("20261019-1100-live", "running", queued: "2026-10-19T10:00:00+09:00", order: 1, owner: ProcessStamp.of(getppid())),
    ] {
      JobManager.write(r, folders: t.folders)
    }
    let halted = JobManager.leftovers(data: t.data, folders: t.folders)
    #expect(halted.map(\.snapshot.id) == ["20261019-1100-r1", "20261019-1100-r2", "20261019-1100-q1", "20261019-1100-q2"])

    // 다시 넣는다. 토큰이 없으면 에이전트 작업은 넣지 않는다.
    let m = JobManager(data: t.data, folders: t.folders)
    let none = await m.restore(halted, agent: nil, runner: testConfig)
    #expect(none.count == 0 && none.problems.count == 4 && none.problems[0].contains("토큰이 없어"))
    #expect(m.queue.isEmpty && m.active.isEmpty)
    // 시작했던 작업은 중단됨으로 남고 실행 요약에 적힌다. 시작하지 않은 작업은 작업 폴더를 지운다.
    #expect(RunHistory.load(t.folders, id: "20261019-1100-r1")?.snapshot.phase == "interrupted")
    #expect(!FileOps.exists(t.folders.workDir("20261019-1100-q1")))
    #expect(try JSONLines.read(t.data.runsLog()).values.map { $0["result"] } == [.string("interrupted"), .string("interrupted")])
    #expect(RunHistory.load(t.folders, id: "20261019-1100-else")?.snapshot.phase == "running")
    #expect(RunHistory.load(t.folders, id: "20261019-1100-live")?.snapshot.phase == "running")
    #expect(JobManager.leftovers(data: t.data, folders: t.folders).isEmpty)

    // 같은 차례로 다시 넣는다 (페이지 대기열은 하나씩 돈다)
    m.hold(.backup)
    for r in halted { JobManager.write(r, folders: t.folders) }
    let again = await m.restore(halted, agent: testConfig, runner: testConfig)
    #expect(again.count == 4 && again.problems.isEmpty)
    #expect(m.queue.map(\.target) == ["20261019-1100-r1", "20261019-1100-r2", "20261019-1100-q1", "20261019-1100-q2"])
    #expect(m.queue.allSatisfy { !halted.map(\.snapshot.id).contains($0.id) })
    // 진행 중에 비정상 종료한 작업만 횟수를 센다
    #expect(m.queue.map { $0.crashes ?? 0 } == [1, 1, 0, 0])
    #expect(RunHistory.load(t.folders, id: m.queue[0].id)?.snapshot.crashes == 1)
  }

  @Test func 다시_할_때마다_앱이_끝나는_작업은_더_넣지_않는다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    func record(_ id: String, crashes: Int, quit: Bool? = nil) -> RunRecord {
      var s = JobSnapshot(
        id: id, type: "page-build", typeLabel: "학습 페이지 만들기", title: id, phase: "running", phaseLabel: "실행", queuedAt: Clock.isoLocal(),
        dataFolder: t.data.url.path, recipe: .pageBuild(subject: id), crashes: crashes, quit: quit)
      s.startedAt = Clock.isoLocal()
      return RunRecord(snapshot: s, logs: [])
    }
    let m = JobManager(data: t.data, folders: t.folders)
    m.hold(.backup)
    // 두 번 다시 넣었는데 또 끝났다. 앱을 끝내 멈춘 것은 세지 않는다.
    let r = await m.restore(
      [record("20261019-1300-poison", crashes: 2), record("20261019-1300-quit", crashes: 2, quit: true)], agent: testConfig, runner: testConfig)
    #expect(r.count == 1 && r.problems == ["학습 페이지 만들기 · 20261019-1300-poison: 다시 할 때마다 앱이 끝나 더 넣지 않았습니다"])
    #expect(m.queue.map(\.target) == ["20261019-1300-quit"] && m.queue.first?.crashes == 2)
  }
}

@Suite struct UsageTests {
  @Test func 사용량_이벤트에서_5시간과_주간_사용량을_읽는다() throws {
    let line =
      #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1791923400,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.3,"resetsAt":1791923400},"seven_day":{"utilization":0.17,"resetsAt":1791925200}}},"session_id":"s"}"#
    let r = try #require(UsageReading.parse(try JSONValue.parse(Data(line.utf8)), at: "2026-10-13T22:00:00+09:00"))
    #expect(r.fiveHour == UsageWindow(utilization: 0.3, resetsAt: 1791923400))
    #expect(r.sevenDay?.percent == 17)
    #expect(UsageReading.parse(try JSONValue.parse(Data(#"{"type":"assistant"}"#.utf8))) == nil)
  }

  @Test func 늦게_받은_값을_쓴다() {
    let early = UsageReading(fiveHour: UsageWindow(utilization: 0.5, resetsAt: 1), sevenDay: nil, at: "2026-10-14T10:00:00+09:00")
    let late = UsageReading(fiveHour: UsageWindow(utilization: 0.4, resetsAt: 1), sevenDay: nil, at: "2026-10-14T10:05:00+09:00")
    #expect(UsageReading.newer(early, late) == late)
    #expect(UsageReading.newer(late, early) == late)
    #expect(UsageReading.newer(nil, early) == early)
  }

  @Test func 실행_중의_턴을_num_turns_와_같은_방식으로_센다() throws {
    var c = TurnCounter()
    let events = [
      #"{"type":"system","subtype":"init"}"#,
      #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"a"}]}}"#,
      #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","name":"Read"}]}}"#,
      #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}"#,
      #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2"}]}}"#,
    ]
    let changed = try events.map { c.add(try JSONValue.parse(Data($0.utf8))) }
    #expect(changed == [false, true, false, true, true])
    #expect(c.count == 3)
  }
}
