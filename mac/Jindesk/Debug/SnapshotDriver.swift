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

    enum Target { case main, admin, sheet }

    struct Scenario {
      let name: String
      var dark = false
      var target = Target.main
      let prepare: @MainActor (AppModel) async -> Void
    }

    static func scenarios() -> [Scenario] {
      [
        Scenario(name: "setup") { $0.phase = .choosingFolder(nil) },
        Scenario(name: "setup-missing", dark: true) { $0.phase = .choosingFolder("데이터 폴더를 찾지 못했습니다: /Users/학생/Jindesk") },
        Scenario(name: "today") { m in
          m.phase = .ready
          m.section = .today
        },
        Scenario(name: "jobs") { m in
          m.phase = .ready
          await startFakeJobs(m)
          m.section = .jobs
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
        // 학습 페이지: 한국어를 모두 펼친다
        Scenario(name: "page-ko-dark", dark: true) { m in
          m.phase = .ready
          m.section = .subjects
          m.openAllKorean = true
          m.selection = m.concepts.values.flatMap { $0 }.sorted { $0.id < $1.id }.first.map { .concept($0.id) }
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
        Scenario(name: "admin-run", target: .admin) { m in
          m.phase = .ready
          m.adminTab = .run
          AppDelegate.openAdminWindow?()
        },
        Scenario(name: "admin-doctor", target: .admin) { m in
          await m.runDoctor()
          m.adminTab = .doctor
          AppDelegate.openAdminWindow?()
        },
        Scenario(name: "admin-data", dark: true, target: .admin) { m in
          m.adminTab = .data
          AppDelegate.openAdminWindow?()
        },
      ]
    }

    static func run(_ model: AppModel, to directory: URL) async {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let only = Set((UserDefaults.standard.string(forKey: "snapshotOnly") ?? "").split(separator: ",").map(String.init))
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
        // 창 위치는 화면 가까이로 당겨져 겹칠 수 있다. 관리자 창을 찍을 때는 메인 창을 잠시 내린다.
        let hidden = scenario.target == .admin ? NSApp.windows.filter { $0.isVisible && AppDelegate.isMainWindow($0) } : []
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
        for w in NSApp.windows where w.isVisible && w.identifier?.rawValue.hasPrefix("admin") == true { w.close() }
        model.showIntake = false
        model.openAllKorean = false
      }
      // 관리자 설정 메뉴 항목은 ⌥ 없이 열면 숨어 있어야 한다
      let adminItems = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }.filter { $0.title == AdminMenu.title }
      log.append("관리자 메뉴: \(adminItems.count)개 · 숨김 \(adminItems.map(\.isHidden))")
      if let jobs = model.jobs {
        jobs.cancel()
        for _ in 0..<50 where jobs.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
      }
      try? log.joined(separator: "\n").write(to: directory.appending(path: "snapshots.txt"), atomically: true, encoding: .utf8)
      // 화면 밖에 둔 창 위치가 실제 앱의 창 위치로 기억되지 않게 지운다
      for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame") || key.hasPrefix("NSSplitView") {
        UserDefaults.standard.removeObject(forKey: key)
      }
      for window in NSApp.windows { window.isRestorable = false }
      NSApp.terminate(nil)
    }

    // 화면 밖으로 옮긴다. 사용자가 보는 화면을 가리지 않게 한다.
    static func moveOffscreen() {
      if UserDefaults.standard.bool(forKey: "snapshotStay") { return }
      // 관리자 창(Form)은 화면 밖으로 옮기면 내용이 그려지지 않는다. 그 창은 화면 위에 둔 채 찍는다 (몇 초 보였다 닫힌다).
      for window in NSApp.windows where window.isVisible && window.frame.width > 300 {
        window.isRestorable = false
        guard window.identifier?.rawValue.hasPrefix("admin") != true else { continue }
        window.setFrame(NSRect(x: -6000, y: 200, width: 1200, height: 760), display: true)
      }
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
        case .admin: NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("admin") == true }
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
