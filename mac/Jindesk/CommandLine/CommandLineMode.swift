// 명령줄 모드. 앱 실행 파일에 명령을 주면 화면 없이 실행한다.
//   Jindesk doctor [--data <데이터 폴더>] [--out <결과 파일>]
//   Jindesk intake [--data <데이터 폴더>] --subject <과목> [--follow] <파일>…
//   Jindesk continue [--data <데이터 폴더>] [--only <종류>]
//   Jindesk rebuild-pages [--data <데이터 폴더>] [--unit <과목 id>/<단원 키>] [--list] [<개념 id>…]
//   Jindesk check-figure --vendor <폴더> <그림 조각.html>
//   Jindesk directive --data <데이터 폴더> (--accept | --keep) <요구 id>
//   Jindesk migrate --check <백업 폴더나 zip> [--sample <n>] [--keep]
//   Jindesk backup --out <폴더> [--data <데이터 폴더>]
//   Jindesk sync [--data <데이터 폴더>]
//   Jindesk version
import AppKit
import ArgumentParser
import Foundation
import JindeskKit

struct JindeskCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "Jindesk",
    abstract: "Jindesk 명령줄 모드",
    subcommands: [
      DoctorCommand.self, IntakeCommand.self, ContinueCommand.self, RebuildPagesCommand.self, DirectiveCommand.self, FigureCheckCommand.self, OutcomeCheckCommand.self, MigrateCommand.self,
      BackupCommand.self, SyncCommand.self,
      VersionCommand.self,
    ]
  )
}

@MainActor
enum CommandLineMode {
  static let commands: Set<String> = ["doctor", "intake", "continue", "rebuild-pages", "directive", "check-figure", "outcome-check", "migrate", "backup", "sync", "version", "help", "--help", "-h"]

  // 첫 인자가 명령이면 명령줄 모드다. "-" 로 시작하는 인자(-snapshotDir, Xcode 가 붙이는 -NSDocumentRevisionsDebugMode 등)만 있으면 앱으로 뜬다.
  // 모르는 명령도 명령줄 모드로 받아 오류를 보인다. 화면 앱으로 떠 버리면 스크립트가 멈춘다.
  static func handles(_ arguments: [String]) -> Bool {
    guard let first = arguments.first else { return false }
    return commands.contains(first) || !first.hasPrefix("-")
  }

  static func run(_ arguments: [String]) -> Never {
    // 파일로 넘겨도 기록이 바로바로 보이도록 줄 단위로 내보낸다
    setvbuf(stdout, nil, _IOLBF, 0)
    // 그림 검사기가 화면 밖 창을 쓴다. Dock 에는 나타나지 않게 한다.
    NSApplication.shared.setActivationPolicy(.prohibited)
    // 띄운 프로세스 그룹을 기록하고, 앱이나 명령줄이 비정상 종료해 남은 그룹(claude 등)을 끝낸다
    let children = AppFolders.standard().children
    ProcessGroups.shared.keepRecords(in: children)
    let reaped = ProcessGroups.reapOrphans(in: children)
    if reaped > 0 { FileHandle.standardError.write(Data("! 지난번에 끝나지 않은 하위 프로세스 \(reaped)개를 끝냈습니다\n".utf8)) }
    Task { @MainActor in
      do {
        var command = try JindeskCommand.parseAsRoot(arguments)
        if var asyncCommand = command as? AsyncParsableCommand {
          try await asyncCommand.run()
        } else {
          try command.run()
        }
        exit(0)
      } catch {
        JindeskCommand.exit(withError: error)
      }
    }
    // 메인 런루프를 돌린다. 타이머가 없으면 run() 이 바로 돌아온다.
    Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in }
    RunLoop.main.run()
    exit(0)
  }

  // 에이전트 작업의 설정 (화면의 설정과 같다). 그림 검사기는 화면 밖 웹 보기를 쓴다.
  static func agentConfig(_ folder: DataFolder) async throws -> RunnerConfig {
    var config = try await ConfigLoader.load(
      settings: RunSettings.load(AppPaths.defaults), data: folder, guardHelper: AppPaths.guardHelper, instructions: AppPaths.instructions,
      katex: AppPaths.katex)
    config.figureChecker = WebFigureChecker(renderer: AppPaths.renderer)
    return config
  }

  // 기록을 화면에 내보내는 작업 관리자
  static func manager(_ folder: DataFolder) -> JobManager {
    let jobs = JobManager(data: folder, folders: .standard())
    jobs.onLog = { print("\($0.kind == .info ? "·" : $0.kind == .error ? "✗" : $0.kind == .warn ? "!" : " ") \($0.message)") }
    jobs.onFinish = { s in
      let counts = (s.counts ?? []).map { "\($0.label) \($0.count)" }.joined(separator: " · ")
      print("■ \(s.typeLabel) \(s.title): \(s.phaseLabel)\(counts.isEmpty ? "" : " — " + counts)\(s.error.map { " — " + $0 } ?? "")")
    }
    return jobs
  }

  // 대기열이 빌 때까지 기다린 뒤 데이터 리포에 올린다. 실패한 작업이 있으면 끝 코드 1.
  // also: 이 전에 끝난 작업 (커밋 글에 함께 적는다)
  static func waitAll(_ jobs: JobManager, also: [String] = []) async throws {
    var failed = false
    var done = also
    let previous = jobs.onFinish
    jobs.onFinish = { s in
      previous?(s)
      done.append(reason(s))
      if s.phase == "failed" { failed = true }
    }
    await jobs.waitUntilIdle()
    await syncRepo(jobs.data, done)
    if failed { throw ExitCode(1) }
  }

  // 커밋 글에 적는 작업 이름
  static func reason(_ s: JobSnapshot) -> String {
    "\(s.typeLabel) · \(s.title)\(s.phase == "failed" ? " (실패)" : "")"
  }

  // 앱 설정에서 연결한 데이터 리포에 커밋하고 올린다 (DATA.md 의 데이터 리포). 연결한 데이터 폴더가 아니면 아무것도 하지 않는다.
  static func syncRepo(_ folder: DataFolder, _ reasons: [String]) async {
    guard let link = RepoLinkStore.load(), link.owns(folder) else { return }
    let out = await DataRepo.sync(folder, link: link, token: RepoToken.read(), message: DataRepo.message(reasons))
    let commit = out.commit.map { "커밋 \($0.prefix(7))" } ?? "바뀐 것 없음"
    print("· 데이터 리포: \(commit) · \(out.pushed ? "올림" : "올리지 못함")\(out.error.map { " — " + $0 } ?? "")")
    for f in out.excluded { print("! 데이터 리포에서 뺀 파일 (100MB 이상): \(f)") }
  }

  // --data 를 주지 않으면 앱에서 연결한 데이터 폴더
  static func dataFolder(_ path: String?) -> DataFolder? {
    path.map(DataFolder.init(path:)) ?? RepoLinkStore.load()?.folder ?? DataFolderStore.load()
  }
}

// 결과를 화면과 (주어지면) 파일에 함께 쓴다. Dock 이나 open 으로 띄운 경우는 화면 출력이 보이지 않으므로 파일로 확인한다.
struct Output {
  let file: String?
  private var lines: [String] = []

  init(file: String?) {
    self.file = file
  }

  mutating func line(_ text: String) {
    print(text)
    lines.append(text)
  }

  func save() throws {
    guard let file else { return }
    try (lines.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
  }
}

struct DoctorCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "doctor", abstract: "실행 환경을 점검한다")

  @Option(help: "데이터 폴더. 주지 않으면 앱에서 고른 폴더") var data: String?
  @Option(help: "결과를 쓸 파일") var out: String?

  func run() async throws {
    var output = Output(file: out)
    output.line("실행 파일: \(AppPaths.executable.path)")
    let input = await Doctor.Input(
      guardHelper: AppPaths.guardHelper, instructions: AppPaths.instructions, schemas: AppPaths.schemas, data: CommandLineMode.dataFolder(data),
      folders: .standard(), claudePath: RunSettings.load(AppPaths.defaults).claudePath, app: AppPaths.version, repo: RepoLinkStore.load(), bucket: BucketLinkStore.load())
    let items = await Doctor.run(input)
    for item in items {
      let mark = switch item.status {
      case .ok: "✓"
      case .warn: "!"
      case .fail: "✗"
      }
      output.line("\(mark) \(item.name) — \(item.detail)")
    }
    try output.save()
    if items.contains(where: { $0.status == .fail }) { throw ExitCode(1) }
  }
}

struct IntakeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "intake", abstract: "자료를 넣는다 (화면의 자료 넣기와 같다)",
    discussion: "꼬리표는 이전에 쓴 값과 대소문자·띄어쓰기만 다르면 그 값으로 맞춘다.")

  @Option(help: "데이터 폴더. 주지 않으면 앱에서 고른 폴더") var data: String?
  @Option(help: "학년 꼬리표 (예: DP1)") var grade: String?
  @Option(help: "과목 꼬리표 (예: Physics)") var subject: String?
  @Option(help: "수준 꼬리표 (예: HL)") var level: String?
  @Option(help: "메모") var memo: String?
  @Flag(help: "목차의 근거로 표시한다") var syllabusBasis = false
  @Flag(help: "뒤따르는 작업(자료 읽기 → 개념 정리 → 학습 페이지 → 번역)까지 넣고 모두 끝날 때까지 기다린다") var follow = false
  @Argument(help: "넣을 파일들") var files: [String]

  @MainActor
  func run() async throws {
    guard let folder = CommandLineMode.dataFolder(data), folder.isInitialized else { throw ValidationError("Jindesk 데이터 폴더를 찾지 못했습니다") }
    let request = IntakeRequest(
      files: files.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }, labels: SourceLabels(grade: grade, subject: subject, level: level),
      memo: memo, syllabusBasis: syllabusBasis)
    let jobs = CommandLineMode.manager(folder)
    let settings = RunSettings.load(AppPaths.defaults)
    let config =
      follow
      ? try await CommandLineMode.agentConfig(folder)
      : await ConfigLoader.loadForRunner(settings: settings, guardHelper: AppPaths.guardHelper, instructions: AppPaths.instructions)
    let id = try await jobs.submit(config: config) { try SourceIntake.prepare(request, $0) }
    let end = await jobs.waitForEnd(id)
    print("\(end.phaseLabel): " + (end.counts ?? []).map { "\($0.label) \($0.count)" }.joined(separator: " · "))
    guard end.phase == "done" else {
      await CommandLineMode.syncRepo(folder, [CommandLineMode.reason(end)])
      throw ExitCode(1)
    }
    if follow {
      try await CommandLineMode.waitAll(jobs, also: [CommandLineMode.reason(end)])
    } else {
      await CommandLineMode.syncRepo(folder, [CommandLineMode.reason(end)])
    }
  }
}

// 흐름이 끊겨 남은 일을 넣고 모두 끝날 때까지 기다린다 (화면의 "이어서 하기"와 같다)
struct ContinueCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "continue", abstract: "남은 일(읽지 않은 자료, 정리하지 않은 엔트리, 없거나 낡은 페이지와 한국어)을 이어서 한다")

  @Option(help: "데이터 폴더. 주지 않으면 앱에서 고른 폴더") var data: String?
  @Option(help: "이 종류만 넣는다 (source-split, source-reading, regen, ask, syllabus-build, concept-curation, page-build, translation, facets)") var only: String?
  @Flag(help: "남은 일만 보이고 넣지 않는다") var list = false

  @MainActor
  func run() async throws {
    guard let folder = CommandLineMode.dataFolder(data), folder.isInitialized else { throw ValidationError("Jindesk 데이터 폴더를 찾지 못했습니다") }
    var work = Pipeline.pending(folder)
    if let only { work = work.filter { $0.kind.rawValue == only } }
    for w in work { print("· \(w.kind.label): \(w.label)") }
    if work.isEmpty { print("남은 일이 없습니다") }
    if list || work.isEmpty { return }
    let jobs = CommandLineMode.manager(folder)
    let config = try await CommandLineMode.agentConfig(folder)
    try await jobs.submitAll(config: config, work.map { Pipeline.prepare($0) })
    try await CommandLineMode.waitAll(jobs)
  }
}

// 고른 개념이나 단원의 학습 페이지를 지금 지침으로 다시 만들고 끝날 때까지 기다린다 (화면의 "페이지 다시 만들기"와 같다, DECISIONS.md 46)
struct RebuildPagesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rebuild-pages", abstract: "고른 개념이나 단원의 학습 페이지를 지금 지침으로 다시 만든다 (낡지 않았어도)")

  @Option(help: "데이터 폴더. 주지 않으면 앱에서 고른 폴더") var data: String?
  @Option(help: "단원 하나의 개념 모두: <과목 id>/<단원 키>. 단원 키는 item:<목차 코드> 또는 proposed:<단원 제안>") var unit: String?
  @Flag(help: "다시 만들 개념만 보이고 넣지 않는다") var list = false
  @Argument(help: "개념 id (<과목 id>/<항목>/<slug>)") var concepts: [String] = []

  @MainActor
  func run() async throws {
    guard let folder = CommandLineMode.dataFolder(data), folder.isInitialized else { throw ValidationError("Jindesk 데이터 폴더를 찾지 못했습니다") }
    var ids = concepts
    if let unit {
      guard let slash = unit.firstIndex(of: "/") else { throw ValidationError("--unit 은 <과목 id>/<단원 키> 다") }
      let subject = String(unit[..<slash])
      let key = String(unit[unit.index(after: slash)...])
      let units = SubjectUnits.make(ConceptStore.all(folder, subject: subject), syllabus: Syllabus.load(folder, subject: subject))
      guard let found = units.first(where: { $0.key == key }) else {
        throw ValidationError("단원을 찾지 못했습니다: \(unit). 이 과목의 단원 키: \(units.map(\.key).joined(separator: ", "))")
      }
      ids += found.concepts.map(\.id)
    }
    guard !ids.isEmpty else { throw ValidationError("개념 id 나 --unit 을 준다") }
    var bySubject: [String: [String]] = [:]
    for id in Set(ids) {
      guard let subject = ConceptID(id)?.subject, ConceptStore.all(folder, subject: subject).contains(where: { $0.id == id }) else {
        throw ValidationError("개념을 찾지 못했습니다: \(id)")
      }
      bySubject[subject, default: []].append(id)
    }
    let groups = bySubject.keys.sorted().map { ($0, bySubject[$0]!.sorted()) }
    for (_, list) in groups { for id in list { print("· \(id)") } }
    if list { return }
    let jobs = CommandLineMode.manager(folder)
    let config = try await CommandLineMode.agentConfig(folder)
    let prepares: [(PrepareContext) async throws -> PreparedJob] = groups.map { subject, list in { try PageBuild.prepare(subject: subject, rebuild: list, $0) } }
    try await jobs.submitAll(config: config, prepares)
    try await CommandLineMode.waitAll(jobs)
  }
}

// 다시 만들기 후보를 받아들이거나 지금 판을 유지한다 (화면의 "새 판 받아들이기", "지금 판 유지"와 같다)
struct DirectiveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "directive", abstract: "다시 만들기 후보를 받아들이거나 지금 판을 유지한다")

  @Option(help: "데이터 폴더. 주지 않으면 앱에서 고른 폴더") var data: String?
  @Flag(help: "새 판을 받아들인다") var accept = false
  @Flag(help: "지금 판을 유지한다") var keep = false
  @Argument(help: "요구 id (d7 …)") var id: String

  @MainActor
  func run() async throws {
    guard let folder = CommandLineMode.dataFolder(data), folder.isInitialized else { throw ValidationError("Jindesk 데이터 폴더를 찾지 못했습니다") }
    guard accept != keep else { throw ValidationError("--accept 와 --keep 가운데 하나를 준다") }
    if keep {
      try Regen.keep(folder, directiveID: id)
      print("\(id): 지금 판 유지")
      await CommandLineMode.syncRepo(folder, ["지금 판 유지 · \(id)"])
    } else {
      let unit = try Regen.accept(folder, directiveID: id)
      print("\(id): 받아들임 (\(unit ?? "-"))")
      await CommandLineMode.syncRepo(folder, ["새 판 받아들이기 · \(id)"])
    }
  }
}

// 저장된 학습 페이지마다 학습 목표 시험을 돌려 본다 (판을 견주거나 진단할 때). 판정에 토큰을 쓴다.
struct OutcomeCheckCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "outcome-check", abstract: "저장된 학습 페이지에 학습 목표 시험을 돌린다")

  @Option(help: "데이터 폴더. 주지 않으면 앱에서 고른 폴더") var data: String?
  @Option(help: "학습 목표를 이 데이터 폴더의 읽기 기록에서 가져온다 (자료 id 가 같을 때)") var outcomesFrom: String?
  @Option(help: "결과 JSON 을 쓸 파일") var out: String?

  @MainActor
  func run() async throws {
    guard let folder = CommandLineMode.dataFolder(data), folder.isInitialized else { throw ValidationError("Jindesk 데이터 폴더를 찾지 못했습니다") }
    let goalsFolder = outcomesFrom.map { DataFolder(path: ($0 as NSString).expandingTildeInPath) } ?? folder
    let config = try await CommandLineMode.agentConfig(folder)
    let scratch = FileManager.default.temporaryDirectory.appending(path: "jindesk-outcome-check-\(UUID().uuidString.prefix(8))")
    defer { FileOps.remove(scratch) }
    let library = SourceLibrary.load(folder)
    var report: [JSONValue] = []
    for (i, c) in ConceptStore.everything(folder).enumerated() {
      guard let page = Page.load(ConceptFolder(c.cid, in: folder)) else { continue }
      let outcomes = SourceReading.outcomes(goalsFolder, sources: Set(c.occurrences.map(\.source)))
      let goals = outcomes.enumerated().map { OutcomeTest.Goal(key: "o\($0.offset + 1)", text: $0.element.text) }
      let level = ReaderTest.level(library.sources.first { $0.labels.labels.subjectID == c.subject }?.labels.labels)
      let others = ConceptStore.all(folder, subject: c.subject).filter { $0.id != c.id }.map(\.title)
      let (verdicts, error) = await OutcomeTest.check(
        text: PageBuild.studyText(page: page, concept: c), goals: goals, level: level, subject: c.subject, others: others, config: config,
        scratch: scratch.appending(path: "c\(i)"))
      print("== \(c.id)\(error.map { " (판정 못 함: \($0))" } ?? "")")
      for v in verdicts where v.applies {
        let text = goals.first { $0.key == v.key }?.text ?? v.key
        print("  \(v.met ? "✓" : "✗")해냄 \(v.practiced ? "✓" : "✗")연습  \(text)\(v.missing.isEmpty ? "" : "\n      " + v.missing)")
      }
      report.append(.object([
        "concept": .string(c.id), "title": .string(c.title), "error": error.map(JSONValue.string) ?? .null,
        "outcomes": .array(verdicts.map { v in
          .object([
            "text": .string(goals.first { $0.key == v.key }?.text ?? v.key), "applies": .bool(v.applies), "met": .bool(v.met),
            "practiced": .bool(v.practiced), "missing": .string(v.missing),
          ])
        }),
      ]))
    }
    if let out { try FileOps.write(JSONText.record(.array(report)), to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath)) }
  }
}

// 그림 조각 하나를 블록 틀에 넣어 학습 페이지 만들기의 러너 검사와 같게 돌려 본다
struct FigureCheckCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "check-figure", abstract: "그림 블록 조각이 돌아가는지 본다 (러너 검사와 같다)")

  @Option(help: "바깥 라이브러리를 받아 둘 폴더 (데이터 폴더의 library/vendor 와 같은 모양)") var vendor: String
  @Argument(help: "그림 조각 HTML 파일") var file: String

  @MainActor
  func run() async throws {
    let code = try String(contentsOfFile: (file as NSString).expandingTildeInPath, encoding: .utf8)
    let store = VendorStore(root: URL(fileURLWithPath: (vendor as NSString).expandingTildeInPath))
    let result = await WebFigureChecker(renderer: AppPaths.renderer).check(html: FigureFrame.compose(code), vendor: store)
    print("그려짐: \(result.painted ? "예" : "아니오") · 응답: \(result.responsive ? "예" : "아니오") · 받은 파일 \(result.fetched.count)개")
    for f in result.fetched { print("  + \(f)") }
    for e in result.errors { print("  ✗ \(e)") }
    if result.controlsDead { print("  ⨯ 조작해도 화면이 바뀌지 않음") }
    for o in result.overlaps { print("  ⨯ 겹침 \(o)") }
    if !result.problems.isEmpty { throw ExitCode(1) }
  }
}

struct MigrateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "migrate", abstract: "데이터 폴더 사본에서 마이그레이션을 시험한다. 원래 폴더는 건드리지 않는다",
    discussion: "학생에게 받은 백업 폴더나 zip 으로, 릴리즈 전에 이번 판의 마이그레이션이 통과하는지 본다 (MIGRATION.md).")

  @Option(name: .customLong("check"), help: "백업 폴더나 zip") var check: String
  @Option(help: "에이전트 단계는 표본 n 개만 돌린다") var sample: Int?
  @Flag(help: "시험한 사본을 지우지 않고 남긴다 (바뀐 파일을 직접 볼 때)") var keep = false

  func run() async throws {
    let source = URL(fileURLWithPath: (check as NSString).expandingTildeInPath)
    guard FileOps.exists(source) else { throw ValidationError("없는 경로입니다: \(source.path)") }
    let folders = AppFolders.standard()
    try folders.prepare()
    let report = try await MigrationCheck.run(source: source, folders: folders, app: AppPaths.version, sample: sample, schemas: AppPaths.schemas) {
      print("· \($0)")
    }
    print("스키마: \(report.from.map(String.init) ?? "\(report.to)") → \(report.to) (앱 \(CurrentSchema.version))")
    for note in report.notes { print(note) }
    print("더해진 파일 \(report.added.count) · 지워진 파일 \(report.removed.count) · 바뀐 파일 \(report.changed.count)")
    for path in report.added { print("  + \(path)") }
    for path in report.removed { print("  - \(path)") }
    for path in report.changed { print("  ~ \(path)") }
    if report.issues.isEmpty {
      print("✓ 검증 통과")
    } else {
      print("✗ 검증 실패 \(report.issues.count)건")
      for issue in report.issues { print("  · \(issue)") }
    }
    if keep {
      print("사본: \(report.workFolder.path)")
    } else {
      FileOps.remove(report.workFolder)
    }
    if !report.issues.isEmpty { throw ExitCode(1) }
  }
}

struct BackupCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "backup", abstract: "데이터 폴더의 백업 zip 을 만든다. 작업이 돌고 있으면 끝날 때까지 기다린다")

  @Option(help: "백업 zip 을 둘 폴더") var out: String
  @Option(help: "데이터 폴더. 주지 않으면 앱에서 고른 폴더") var data: String?

  func run() async throws {
    guard let folder = await CommandLineMode.dataFolder(data), folder.isInitialized else { throw ValidationError("Jindesk 데이터 폴더를 찾지 못했습니다") }
    let url = try await Backup.make(folder, into: URL(fileURLWithPath: (out as NSString).expandingTildeInPath)) {
      print("다른 Jindesk 프로세스가 작업 중입니다. 끝나기를 기다립니다…")
    }
    print(url.path)
  }
}

// 데이터 폴더의 바뀐 것을 데이터 리포에 커밋하고 올린다 (화면에서는 작업이 끝날 때마다 저절로 한다)
struct SyncCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "sync", abstract: "데이터 폴더를 앱 설정에서 연결한 데이터 리포에 커밋하고 올린다")

  @Option(help: "데이터 폴더. 주지 않으면 앱에서 고른 폴더") var data: String?

  @MainActor
  func run() async throws {
    guard let folder = CommandLineMode.dataFolder(data), folder.isInitialized else { throw ValidationError("Jindesk 데이터 폴더를 찾지 못했습니다") }
    guard let link = RepoLinkStore.load() else {
      print("데이터 리포를 연결하지 않았습니다. 앱의 설정에서 연결합니다 (SETUP.md 의 데이터 리포)")
      throw ExitCode(1)
    }
    guard link.owns(folder) else {
      print("연결한 데이터 폴더(\(link.path))가 아니라 올리지 않습니다")
      throw ExitCode(1)
    }
    let out = await DataRepo.sync(folder, link: link, token: RepoToken.read(), message: "명령줄에서 올리기")
    print(out.commit.map { "커밋 \($0)" } ?? "바뀐 것이 없습니다")
    print(out.pushed ? "올렸습니다: \(out.remote)" : "올리지 못했습니다: \(out.error ?? "")")
    for f in out.excluded { print("100MB 이상이라 뺀 파일: \(f)") }
    if out.error != nil { throw ExitCode(1) }
  }
}

struct VersionCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "version", abstract: "앱 판과 스키마 버전을 보인다")

  func run() async throws {
    let version = AppPaths.version
    print("Jindesk \(version.label) · 스키마 \(CurrentSchema.version)")
  }
}
