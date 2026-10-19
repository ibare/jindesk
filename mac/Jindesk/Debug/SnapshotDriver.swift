#if DEBUG
  // 디버그 빌드 전용: 정해 둔 화면들을 차례로 띄워 자기 창을 PNG 로 찍고 끝난다. 유지보수 세션이 화면을 확인하는 데 쓴다.
  // 사용: Jindesk.app/Contents/MacOS/Jindesk -snapshotDir <폴더> [-snapshotOnly <이름,…>]
  // 실제 데이터 폴더와 앱 지원 폴더 대신 <폴더>/data, <폴더>/support, <폴더>/cache 를 쓴다.
  // 창은 화면 밖에 두고 찍는다. 자기 프로세스의 창만 찍으므로 화면 기록 권한이 필요 없다.
  import AppKit
  import JindeskKit
  import ScreenCaptureKit

  @MainActor
  enum SnapshotDriver {
    static var directory: URL? {
      UserDefaults.standard.string(forKey: "snapshotDir").map { URL(fileURLWithPath: $0) }
    }

    static var dataFolder: DataFolder? { directory.map { DataFolder($0.appending(path: "data")) } }

    static var folders: AppFolders? {
      directory.map { AppFolders(support: $0.appending(path: "support"), cache: $0.appending(path: "cache")) }
    }

    enum Target { case main, settings, sheet }

    struct Scenario {
      let name: String
      var dark = false
      var target = Target.main
      let prepare: @MainActor (AppModel) async -> Void
    }

    static func scenarios() -> [Scenario] {
      [
        Scenario(name: "setup") { $0.phase = .connecting(nil) },
        Scenario(name: "setup-missing", dark: true) { $0.phase = .connecting("데이터 폴더를 찾지 못했습니다: /Users/학생/Jindesk. 리포를 다시 연결합니다") },
        Scenario(name: "today") { m in
          m.phase = .ready
          m.section = .today
        },
        Scenario(name: "today-dark", dark: true) { m in
          m.phase = .ready
          m.section = .today
          m.selection = nil
        },
        // 모아 보기의 확인 문제
        Scenario(name: "collections") { m in
          m.phase = .ready
          m.section = .collections
          m.collectionsTab = .checks
          m.selection = nil
        },
        Scenario(name: "collections-dark", dark: true) { m in
          m.phase = .ready
          m.section = .collections
          m.collectionsTab = .checks
        },
        // 과목 목록: 배우는 순서의 둘째 개념을 고른다 (고른 줄이 펼쳐진다)
        Scenario(name: "subjects-list-dark", dark: true) { m in
          m.phase = .ready
          m.section = .subjects
          let subject = m.concepts.keys.sorted().first
          m.selection = subject.flatMap { m.conceptMap($0, showOthers: false).learningOrder().dropFirst().first }.map { .concept($0) }
        },
        // 단원 개요: 첫 과목의 첫 단원 (-snapshotUnitSection 으로 아래 절까지 내려 찍는다)
        Scenario(name: "unit-overview", dark: true) { m in
          m.phase = .ready
          m.section = .subjects
          m.selection = firstUnit(m)
        },
        // 모아 보기의 용어와 command term, 찾기 (DECISIONS.md 34)
        Scenario(name: "collections-terms", dark: true) { m in
          m.phase = .ready
          m.section = .collections
          m.collectionsTab = .terms
          m.selection = .entry("term:interquartile range")
        },
        Scenario(name: "collections-command", dark: true) { m in
          m.phase = .ready
          m.section = .collections
          m.collectionsTab = .commandTerms
          m.selection = .entry("command:Compare")
        },
        Scenario(name: "search-quartile", dark: true) { m in
          m.phase = .ready
          m.section = .subjects
          m.searchText = "quartile"
          try? await Task.sleep(for: .seconds(2))
          m.selection = .entry("term:quartile")
        },
        // 자료와 나란히 (DECISIONS.md 34): 배우는 순서의 셋째 개념
        Scenario(name: "side-by-side", dark: true) { m in
          m.phase = .ready
          m.section = .subjects
          let subject = m.concepts.keys.sorted().first
          m.selection = subject.flatMap { m.conceptMap($0, showOthers: false).learningOrder().dropFirst(2).first }.map { .concept($0) }
          // 화면이 뜬 뒤에 켠다 (뜰 때의 값으로는 칸을 접지 않는다)
          try? await Task.sleep(for: .seconds(1))
          m.sideBySide = true
          try? await Task.sleep(for: .seconds(2))
        },
        Scenario(name: "jobs") { m in
          m.phase = .ready
          fakeUsage(m)
          await startFakeJobs(m)
          m.section = .jobs
          m.selectedJob = m.jobs?.active.first?.id
          try? await Task.sleep(for: .seconds(2))
        },
        Scenario(name: "jobs-dark", dark: true) { m in
          m.phase = .ready
          m.section = .jobs
        },
        // 과목 화면: 찍는 폴더의 data 에 자료가 있으면 첫 자료를 연다
        Scenario(name: "subjects") { m in
          m.phase = .ready
          m.section = .subjects
          m.selection = m.concepts.values.flatMap { $0 }.sorted { $0.id < $1.id }.first.map { .concept($0.id) } ?? m.library.sources.first.map { .source($0.id) }
        },
        Scenario(name: "subjects-dark", dark: true) { m in
          m.phase = .ready
          m.section = .subjects
          m.selection = m.library.sources.last.map { .source($0.id) }
        },
        // 개념 지도. -snapshotConcept 로 준 개념을 골라 둔다
        Scenario(name: "concept-map") { m in
          m.phase = .ready
          m.section = .subjects
          UserDefaults.standard.set(ConceptMap.Arrangement.learning.rawValue, forKey: "conceptMapArrangement")
          m.mapFocus = UserDefaults.standard.string(forKey: "snapshotConcept")
          m.selection = mapSubject(m).map { .map($0) }
        },
        Scenario(name: "concept-map-syllabus", dark: true) { m in
          m.phase = .ready
          m.section = .subjects
          UserDefaults.standard.set(ConceptMap.Arrangement.syllabus.rawValue, forKey: "conceptMapArrangement")
          m.selection = mapSubject(m).map { .map($0) }
        },
        // 학습 페이지 머리의 앞뒤 개념 지도 (-snapshotConcept 의 페이지)
        Scenario(name: "page-neighbors") { m in
          m.phase = .ready
          m.section = .subjects
          m.selection = snapshotConcept(m).map { .concept($0) }
        },
        // 앞뒤 개념 지도에서 이웃을 눌러 옮겨 간 뒤 (-snapshotWalk <개념 id>, 없으면 첫 다음 개념)
        Scenario(name: "page-neighbors-walk", dark: true) { m in
          m.phase = .ready
          m.section = .subjects
          guard let from = snapshotConcept(m), let concept = m.concept(from) else { return }
          let to = UserDefaults.standard.string(forKey: "snapshotWalk") ?? ConceptMap.neighborhood(of: concept, all: m.allConcepts).after.first?.node.id ?? from
          m.snapshotDebug = .object(["walk": .array([.string(from), .string(to)])])
          m.selection = .concept(from)
        },
        // 앞뒤 개념 지도의 "개념 지도에서 보기": 과목 지도가 이 개념을 고른 채 열린다
        Scenario(name: "page-neighbors-map") { m in
          m.phase = .ready
          m.section = .subjects
          UserDefaults.standard.set(ConceptMap.Arrangement.learning.rawValue, forKey: "conceptMapArrangement")
          m.snapshotDebug = .object(["openMap": .bool(true)])
          m.selection = snapshotConcept(m).map { .concept($0) }
          try? await Task.sleep(for: .milliseconds(800))
        },
        // 폭이 좁으면 위아래로 쌓는다
        Scenario(name: "page-neighbors-narrow") { m in
          m.phase = .ready
          m.section = .subjects
          m.snapshotDebug = .object(["narrow": .number(470)])
          m.selection = snapshotConcept(m).map { .concept($0) }
        },
        // 학습 페이지의 그림 블록 (-snapshotConcept <개념 id> 로 개념을 고른다)
        Scenario(name: "figure") { m in
          m.phase = .ready
          m.section = .subjects
          m.scrollToFigure = true
          m.selection = snapshotConcept(m).map { .concept($0) }
        },
        Scenario(name: "figure-dark", dark: true) { m in
          m.phase = .ready
          m.section = .subjects
          m.scrollToFigure = true
          m.selection = snapshotConcept(m).map { .concept($0) }
        },
        // 학습 페이지: 한국어를 모두 펼친다
        Scenario(name: "page-ko-dark", dark: true) { m in
          m.phase = .ready
          m.section = .subjects
          m.openAllKorean = true
          m.selection = m.concepts.values.flatMap { $0 }.sorted { $0.id < $1.id }.first.map { .concept($0.id) }
        },
        // 코멘트 스레드 (질문과 답)
        Scenario(name: "thread") { m in
          m.phase = .ready
          m.section = .subjects
          m.snapshotDebug = .object(["openThreads": .bool(true), "scrollTo": .string(".thread")])
          m.selection = snapshotConcept(m).map { .concept($0) }
        },
        // 새 판 비교
        Scenario(name: "compare", dark: true) { m in
          m.phase = .ready
          m.section = .subjects
          m.snapshotDebug = .object(["openCompare": .bool(true), "scrollTo": .string(".compare")])
          m.selection = snapshotConcept(m).map { .concept($0) }
        },
        // 곁 설명 (쉽게)
        Scenario(name: "easy") { m in
          m.phase = .ready
          m.section = .subjects
          m.snapshotDebug = .object(["openEasy": .bool(true), "scrollTo": .string(".side")])
          m.selection = snapshotConcept(m).map { .concept($0) }
        },
        // 한 단위까지 내려 연다 (-snapshotUnit <단위 id>, 여럿이면 쉼표로. 단위마다 unit-<id> 로 찍는다)
        Scenario(name: "unit") { m in
          m.phase = .ready
          m.section = .subjects
          m.snapshotDebug = .object(["scrollTo": .string("#" + (UserDefaults.standard.string(forKey: "snapshotUnit") ?? "p1"))])
          m.selection = snapshotConcept(m).map { .concept($0) }
        },
        // 찾기 결과 (-snapshotSearch <말>, 없으면 log)
        Scenario(name: "search") { m in
          m.phase = .ready
          m.searchText = UserDefaults.standard.string(forKey: "snapshotSearch") ?? "log"
          try? await Task.sleep(for: .milliseconds(800))
        },
        Scenario(name: "collections") { m in
          m.searchText = ""
          m.phase = .ready
          m.section = .collections
        },
        // 다시 만들기 시트: 찍을 개념의 첫 문단
        Scenario(name: "regen", target: .sheet) { m in
          m.phase = .ready
          m.section = .subjects
          guard let id = snapshotConcept(m), let c = m.concept(id) else { return }
          m.selection = .concept(id)
          try? await Task.sleep(for: .milliseconds(600))
          m.regenTarget = RegenTarget(concept: id, unit: "p1", rev: 1, ops: [.easy, .detail, .example, .visual, .fix], quote: String((c.units.first?.text ?? "").prefix(90)))
        },
        Scenario(name: "intake", target: .sheet) { m in
          m.phase = .ready
          m.showIntake = true
        },
        Scenario(name: "migrating") { $0.phase = .migrating("자동 백업: ~/Library/Application Support/com.mintae.Jindesk/backups/Jindesk-마이그레이션-1-2.zip") },
        Scenario(name: "migration-failed") {
          $0.phase = .migrationFailed(MigrationFailure(issues: ["learner/comments.jsonl: 줄 수가 12 → 11 로 바뀌었습니다", "records/runs/2026-10.jsonl: 기록이 바뀌었습니다"]).localizedDescription)
        },
        Scenario(name: "newer-data", dark: true) { $0.phase = .newerData(3) },
        Scenario(name: "settings-run", target: .settings) { m in
          m.phase = .ready
          m.settingsTab = .run
          AppDelegate.openSettingsWindow?()
        },
        Scenario(name: "settings-doctor", target: .settings) { m in
          await m.runDoctor()
          m.settingsTab = .doctor
          AppDelegate.openSettingsWindow?()
        },
        Scenario(name: "settings-data", dark: true, target: .settings) { m in
          m.settingsTab = .data
          AppDelegate.openSettingsWindow?()
        },
      ]
    }

    static func run(_ model: AppModel, to directory: URL) async {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let only = Set((UserDefaults.standard.string(forKey: "snapshotOnly") ?? "").split(separator: ",").map(String.init))
      let savedArrangement = UserDefaults.standard.object(forKey: "conceptMapArrangement")
      var log: [String] = []
      for scenario in scenarios() where only.isEmpty || only.contains(scenario.name) {
        NSApp.appearance = NSAppearance(named: scenario.dark ? .darkAqua : .aqua)
        // 시트도 화면 밖에서는 그려지지 않는다. 시트를 찍을 때는 메인 창을 화면 위에 두고 연다 (잠깐 보였다 닫힌다).
        if scenario.target == .sheet {
          for window in NSApp.windows where window.isVisible && AppDelegate.isMainWindow(window) { window.center() }
        }
        await scenario.prepare(model)
        // 새로 연 창은 한 번 그려진 뒤에 옮긴다 (그리기 전에 옮기면 빈 창이 찍힌다)
        try? await Task.sleep(for: .milliseconds(scenario.target == .main ? 500 : 2000))
        // 창 위치는 화면 가까이로 당겨져 겹칠 수 있다. 설정 창을 찍을 때는 메인 창을 잠시 내린다.
        let hidden = scenario.target == .settings ? NSApp.windows.filter { $0.isVisible && AppDelegate.isMainWindow($0) } : []
        for window in hidden { window.orderOut(nil) }
        defer { for window in hidden { window.orderFront(nil) } }
        if scenario.target != .sheet { moveOffscreen() }
        try? await Task.sleep(for: .milliseconds(1200))
        do {
          try await capture(scenario.target, to: directory.appending(path: "\(scenario.name).png"))
          let windows = NSApp.windows.filter(\.isVisible).map { "\($0.identifier?.rawValue ?? "-") \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" }
          log.append("찍음: \(scenario.name) — \(windows.joined(separator: " · "))")
        } catch {
          log.append("실패: \(scenario.name) — \(error.localizedDescription)")
        }
        for w in NSApp.windows where w.isVisible && w.identifier?.rawValue.hasPrefix("settings") == true { w.close() }
        model.showIntake = false
        model.searchText = ""
        model.sideBySide = false
        model.regenTarget = nil
        model.snapshotDebug = nil
        model.openAllKorean = false
        model.scrollToFigure = false
      }
      // 설정 메뉴 항목은 하나이고 숨지 않는다 (DECISIONS.md 33)
      let settingsItems = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }.filter { $0.title == "설정…" }
      log.append("설정 메뉴: \(settingsItems.count)개 · 숨김 \(settingsItems.map(\.isHidden))")
      if let jobs = model.jobs {
        jobs.cancel()
        for _ in 0..<50 where jobs.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
      }
      try? log.joined(separator: "\n").write(to: directory.appending(path: "snapshots.txt"), atomically: true, encoding: .utf8)
      // 개념 지도 장면이 바꾼 배치를 되돌린다
      UserDefaults.standard.set(savedArrangement, forKey: "conceptMapArrangement")
      // 화면 밖에 둔 창 위치가 실제 앱의 창 위치로 기억되지 않게 지운다
      for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame") || key.hasPrefix("NSSplitView") {
        UserDefaults.standard.removeObject(forKey: key)
      }
      for window in NSApp.windows { window.isRestorable = false }
      NSApp.terminate(nil)
    }

    // 첫 과목의 첫 단원 (단원 개요)
    static func firstUnit(_ m: AppModel) -> SubjectSelection? {
      guard let subject = m.concepts.keys.sorted().first, let c = m.inLearningOrder(m.concepts[subject] ?? []).first else { return nil }
      return .unit(subject, c.item.map { "item:\($0)" } ?? "proposed:\(c.itemProposed ?? "목차 밖")")
    }

    // 개념 지도를 찍을 과목: -snapshotConcept 로 준 개념의 과목, 없으면 개념이 가장 많은 과목
    static func mapSubject(_ m: AppModel) -> String? {
      if let id = UserDefaults.standard.string(forKey: "snapshotConcept"), let cid = ConceptID(id) { return cid.subject }
      return m.concepts.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
    }

    // 찍을 개념: -snapshotConcept 로 준 것, 없으면 그림이 있는 첫 개념
    static func snapshotConcept(_ m: AppModel) -> String? {
      if let id = UserDefaults.standard.string(forKey: "snapshotConcept") { return id }
      let all = m.concepts.values.flatMap { $0 }.sorted { $0.id < $1.id }
      return all.first { c in m.pageJSON(c).contains("\"figure\"") }?.id ?? all.first?.id
    }

    // 화면 밖으로 옮긴다. 사용자가 보는 화면을 가리지 않게 한다.
    static func moveOffscreen() {
      if UserDefaults.standard.bool(forKey: "snapshotStay") { return }
      // 설정 창(Form)은 화면 밖으로 옮기면 내용이 그려지지 않는다. 그 창은 화면 위에 둔 채 찍는다 (몇 초 보였다 닫힌다).
      for window in NSApp.windows where window.isVisible && window.frame.width > 300 {
        window.isRestorable = false
        guard window.identifier?.rawValue.hasPrefix("settings") != true else { continue }
        window.setFrame(NSRect(x: -6000, y: 200, width: 1200, height: 760), display: true)
      }
    }

    // 상태 막대의 사용량을 보려고 지어낸 사용량 (5시간 42%, 주간 69%)
    static func fakeUsage(_ model: AppModel) {
      let now = Date().timeIntervalSince1970
      let reading = UsageReading(
        fiveHour: UsageWindow(utilization: 0.42, resetsAt: now + 3 * 3600), sevenDay: UsageWindow(utilization: 0.69, resetsAt: now + 3 * 86400),
        at: Clock.isoLocal())
      if let data = try? JSONEncoder().encode(reading) { try? FileOps.write(data, to: model.folders.usageFile) }
      model.jobs?.reloadUsage()
    }

    // 작업 화면을 보려고 에이전트 없이 기록만 남기는 가짜 작업: 둘이 돌고 하나가 기다린다
    static func startFakeJobs(_ model: AppModel) async {
      guard let jobs = model.jobs, !jobs.isBusy else { return }
      let config = RunnerConfig(claudeToken: "x", tools: ToolPaths(), guardHelper: "", instructions: AppPaths.instructions, baseEnvironment: [:])
      _ = try? await jobs.submit(config: config) { _ in
        PreparedJob(id: "20261016-2100-snapshot-reading", kind: .sourceReading, title: "Kinematics slides.pptx") { c in
          await c.setPhase("running")
          await c.log(.info, "자료 읽기 지침 0.1")
          await c.log(.tool, "Read input/index.md")
          await c.log(.tool, "Read input/pages/0012.txt")
          await c.log(.warn, "맥이 4분 잠들어 있었습니다. 그 시간은 시간 상한에서 뺍니다")
          await c.setLiveTurns(18)
          try await Task.sleep(for: .seconds(60))
        }
      }
      _ = try? await jobs.submit(config: config) { _ in
        PreparedJob(id: "20261016-2100-snapshot-ask", kind: .ask, title: "왜 수평 속도는 안 바뀌어요?") { c in
          await c.setPhase("running")
          try await Task.sleep(for: .seconds(60))
        }
      }
      _ = try? await jobs.submit(config: config) { _ in
        PreparedJob(id: "20261016-2100-snapshot-curation", kind: .conceptCuration, title: "physics-hl · A.1 엔트리 8개") { _ in
          try await Task.sleep(for: .seconds(60))
        }
      }
      _ = try? await jobs.submit(config: config) { _ in
        PreparedJob(id: "20261016-2100-snapshot-curation-2", kind: .conceptCuration, title: "physics-hl · B.5 엔트리 3개") { _ in
          try await Task.sleep(for: .seconds(60))
        }
      }
    }

    static func capture(_ target: Target, to url: URL) async throws {
      let found: NSWindow? =
        switch target {
        case .main: NSApp.windows.first { $0.isVisible && AppDelegate.isMainWindow($0) }
        case .settings: NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("settings") == true }
        case .sheet: NSApp.windows.first { $0.isVisible && AppDelegate.isMainWindow($0) }?.attachedSheet
        }
      guard let window = found else { throw RequestError("찍을 창이 없습니다") }
      let content = try await SCShareableContent.currentProcess
      guard let shareable = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
        throw RequestError("창을 찾지 못했습니다")
      }
      let configuration = SCStreamConfiguration()
      configuration.width = Int(window.frame.width * 2)
      configuration.height = Int(window.frame.height * 2)
      configuration.showsCursor = false
      let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: shareable), configuration: configuration)
      try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
  }
#endif
