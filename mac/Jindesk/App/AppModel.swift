// 앱 상태. 켤 때의 차례(UPDATES.md): 마치지 못한 마이그레이션 정리 → 스키마 확인과 마이그레이션 → 대기열 열기.
// 환경 점검은 화면을 연 뒤 뒤에서 돈다.
import AppKit
import JindeskKit
import Observation

enum SidebarSection: String, CaseIterable, Identifiable {
  case today, subjects, collections, jobs

  var id: String { rawValue }

  var label: String {
    switch self {
    case .today: "오늘"
    case .subjects: "과목"
    case .collections: "모아 보기"
    case .jobs: "작업"
    }
  }

  var icon: String {
    switch self {
    case .today: "sun.max"
    case .subjects: "books.vertical"
    case .collections: "square.stack"
    case .jobs: "gearshape.2"
    }
  }
}

// 다시 만들기 시트의 대상
struct RegenTarget: Identifiable, Equatable {
  let concept: String
  let unit: String
  let rev: Int
  let ops: [DirectiveOp]
  let quote: String
  var fromComment: String?
  var note: String?
  var id: String { "\(concept)#\(unit)" }
}

// 과목 화면에서 고른 것
enum SubjectSelection: Hashable {
  case concept(String)
  case source(String)
}

enum ReadingState: Equatable {
  case unread, queued, read
  case reading(String)
  case failed(String)
}

@MainActor
@Observable
final class AppModel {
  enum Phase: Equatable {
    case starting
    // 처음 켤 때, 또는 기억한 폴더를 찾지 못했을 때
    case choosingFolder(String?)
    case migrating(String)
    case migrationFailed(String)
    // 데이터가 더 새 판의 Jindesk 가 만든 것이다
    case newerData(Int)
    case unusable(String)
    case ready
  }

  var phase: Phase = .starting
  let folders: AppFolders
  let app = AppPaths.version
  private(set) var data: DataFolder?
  private(set) var jobs: JobManager?
  // 켤 때 한 일 (복구, 정리)
  private(set) var notes: [String] = []
  private(set) var doctor: [CheckItem] = []
  private(set) var doctorRunning = false
  private(set) var admin: AdminSettings
  private(set) var tokenSaved = ClaudeToken.exists
  var section: SidebarSection = .today
  // 작업 화면에서 고른 작업 (상태 막대를 누르면 그 작업을 연다)
  var selectedJob: String?
  var adminTab: AdminTab = .run
  // 백업을 만드는 중이면 그 안내
  private(set) var backupStatus: String?
  private(set) var lastBackup: URL?
  private(set) var history: [RunRecord] = []
  // 자료 목록. 과목 목록은 자료의 꼬리표에서 모은다.
  private(set) var library = SourceLibrary(sources: [])
  // 과목마다 정리된 개념과 목차
  private(set) var concepts: [String: [Concept]] = [:]
  private(set) var syllabi: [String: Syllabus] = [:]
  // 자료마다 끝난 자료 읽기
  private(set) var readSources: [String: [String]] = [:]
  // 흐름이 끊겨 남은 일 (이어서 하기)
  private(set) var pendingWork: [PendingWork] = []
  // 과목 화면에서 고른 것 (개념이나 자료)
  var selection: SubjectSelection?
  // 출처 칩으로 연 원래 자료의 쪽
  var peek: SourcePeek?
  // 찾기 (영어 원문과 한국어 곁 층)
  var searchText = "" {
    didSet { if searchText != oldValue { runSearch() } }
  }
  private(set) var searchResults: [SearchHit] = []
  @ObservationIgnored private lazy var searchIndex = SearchIndex(folders)
  var showIntake = false
  let update = UpdateStatus()

  @ObservationIgnored var updater: UpdateController?
  @ObservationIgnored private let sleepGuard = SleepGuard()

  init(folders: AppFolders = .standard()) {
    self.folders = folders
    admin = AdminSettings.load(AppPaths.defaults)
  }

  var isBusy: Bool { (jobs?.isBusy ?? false) || backupStatus != nil }

  // 화면 찍기 모드에서는 고른 폴더를 기억하지 않는다 (실제 앱 설정을 건드리지 않게)
  private var isSnapshot: Bool {
    #if DEBUG
      SnapshotDriver.directory != nil
    #else
      false
    #endif
  }
  var doctorFailures: [CheckItem] { doctor.filter { $0.status == .fail } }

  // MARK: - 켜기

  func start() async {
    do {
      try folders.prepare()
    } catch {
      phase = .unusable("앱 지원 폴더를 만들지 못했습니다: \(error.localizedDescription)")
      return
    }
    #if DEBUG
      if let snapshot = SnapshotDriver.dataFolder {
        await open(snapshot, creating: true)
        return
      }
    #endif
    guard let saved = DataFolderStore.load() else {
      phase = .choosingFolder(nil)
      return
    }
    // 기억한 폴더가 없어졌으면 새로 만들지 않고 고르게 한다 (학생의 데이터가 사라진 것처럼 보이지 않게)
    guard FileOps.exists(saved.url) || hasMigrationLeftovers(saved) else {
      phase = .choosingFolder("데이터 폴더를 찾지 못했습니다: \(saved.path)")
      return
    }
    await open(saved, creating: false)
  }

  private func hasMigrationLeftovers(_ data: DataFolder) -> Bool {
    FileOps.list(data.url.deletingLastPathComponent()).contains { $0.hasPrefix(".Jindesk-before-") }
  }

  // 화면에서 고른 폴더를 쓴다. 비어 있거나 없는 폴더면 새 데이터 폴더로 만든다.
  func useFolder(_ url: URL) async {
    let data = DataFolder(url)
    let errors = data.issues(appBundle: AppPaths.bundle).filter(\.isError)
    guard errors.isEmpty else {
      phase = .choosingFolder(errors.map(\.message).joined(separator: " "))
      return
    }
    await open(data, creating: true)
  }

  func open(_ data: DataFolder, creating: Bool) async {
    phase = .starting
    jobs?.shutdown()
    jobs = nil
    let migrator = Migrator(data: data, folders: folders, app: app, schemas: AppPaths.schemas)
    do {
      notes = try migrator.recoverInterrupted()
      notes += migrator.removePreviousCopies()
      switch migrator.state() {
      case .uninitialized:
        guard creating else {
          phase = .choosingFolder("\(data.path) 는 Jindesk 데이터 폴더가 아닙니다")
          return
        }
        try data.initialize(app: app)
      case .unreadable(let reason):
        phase = .unusable(reason)
        return
      case .newer(let version):
        self.data = data
        phase = .newerData(version)
        updater?.checkNow()
        return
      case .older(let from):
        self.data = data
        phase = .migrating("데이터를 새 모양으로 바꾸고 있습니다 (스키마 \(from) → \(CurrentSchema.version)). 그 전에 자동으로 백업합니다.")
        let report = try await migrator.migrate { message in
          await MainActor.run { [weak self] in if case .migrating = self?.phase { self?.phase = .migrating(message) } }
        }
        notes.append("스키마 \(report.from) → \(report.to) 마이그레이션 · 백업 \(report.backup.lastPathComponent)")
      case .current:
        break
      }
      try SchemaFile.noteOpened(data, by: app)
    } catch {
      self.data = data
      phase = .migrationFailed(error.localizedDescription)
      return
    }

    if !isSnapshot { DataFolderStore.save(data.url) }
    self.data = data
    let fixed = JobManager.markInterrupted(data: data, folders: folders)
    if !fixed.isEmpty { notes.append("앱이 끝나 중단된 작업 \(fixed.count)개를 중단됨으로 고쳤습니다") }
    let leftovers = SourceIntake.removeLeftovers(data)
    if !leftovers.isEmpty { notes.append("넣다가 멈춘 자료 \(leftovers.count)개를 치웠습니다") }
    self.data = data
    reloadLibrary()
    let manager = JobManager(data: data, folders: folders)
    apply(admin, to: manager)
    manager.onFinish = { [weak self] _ in self?.jobsChanged() }
    manager.onPhase = { [weak self] _ in self?.jobsChanged() }
    jobs = manager
    history = RunHistory.load(folders, data: data)
    phase = .ready
    Task { await runDoctor() }
  }

  func retryMigration() async {
    guard let data else { return }
    await open(data, creating: false)
  }

  // 작업이 시작하거나 끝날 때: 잠자기 막기, 자료 목록 다시 읽기, 기다리던 업데이트 설치
  func jobsChanged() {
    commentsVersion += 1
    sleepGuard.update(active: !(jobs?.active.isEmpty ?? true) || backupStatus != nil)
    if let data { history = RunHistory.load(folders, data: data) }
    reloadLibrary()
    updater?.installIfIdle()
  }

  func reloadLibrary() {
    guard let data else { return }
    let fresh = SourceLibrary.load(data)
    if fresh != library { library = fresh }
    var byID: [String: [Concept]] = [:]
    for subject in ConceptStore.subjects(data) { byID[subject] = ConceptStore.all(data, subject: subject) }
    if byID != concepts { concepts = byID }
    var syl: [String: Syllabus] = [:]
    for s in fresh.subjects { if let y = Syllabus.load(data, subject: s.id) { syl[s.id] = y } }
    if syl != syllabi { syllabi = syl }
    let read = SourceReading.readSources(data)
    if read != readSources { readSources = read }
    let pending = Pipeline.pending(data, instructions: AppPaths.instructions)
    if pending != pendingWork { pendingWork = pending }
    let index = searchIndex
    Task.detached { [weak self] in
      if index.update(data) { await self?.runSearch() }
    }
  }

  func runSearch() {
    let q = searchText
    let index = searchIndex
    Task.detached { [weak self] in
      let hits = index.search(q)
      await MainActor.run { [weak self] in
        guard let self, self.searchText == q else { return }
        self.searchResults = hits
      }
    }
  }

  func concept(_ id: String) -> Concept? {
    guard let cid = ConceptID(id) else { return nil }
    return concepts[cid.subject]?.first { $0.id == id }
  }

  // 렌더러에 넘길 페이지 (JSON 글)
  func pageJSON(_ concept: Concept) -> String {
    guard let data else { return "{}" }
    _ = commentsVersion
    var json = PageComposer.json(PageComposer.load(data, concept: concept, library: library, all: concepts.values.flatMap { $0 }))
    if openAllKorean || scrollToFigure || snapshotDebug != nil, case .object(var o) = json {
      if openAllKorean { o["openAll"] = .bool(true) }
      if scrollToFigure { o["scrollToFigure"] = .bool(true) }
      if let snapshotDebug { o["debug"] = snapshotDebug }
      json = .object(o)
    }
    return JSONText.stringify(YAMLValue(json: json))
  }

  // 학습 페이지를 한국어를 모두 펼친 채로 연다 (화면 찍기)
  var openAllKorean = false
  // 학습 페이지를 첫 그림 블록까지 내려 연다 (화면 찍기)
  var scrollToFigure = false
  // 화면 찍기: 스레드·비교를 펼치고 그 자리로 간다 ({ openThreads, openCompare, scrollTo })
  var snapshotDebug: JSONValue?

  // 자료의 읽기 상태
  func readingState(_ sourceID: String) -> ReadingState {
    if let s = jobs?.active.first(where: { $0.kind == .sourceReading && $0.target == sourceID }) { return .reading(s.phaseLabel) }
    if jobs?.queue.contains(where: { $0.kind == .sourceReading && $0.target == sourceID }) == true { return .queued }
    if readSources[sourceID] != nil { return .read }
    if let last = history.first(where: { $0.snapshot.kind == .sourceReading && $0.snapshot.target == sourceID }), last.snapshot.phase == "failed" {
      return .failed(last.snapshot.error ?? "실패")
    }
    return .unread
  }

  struct PageState {
    var titleKo: String?
    var note: String?
  }

  // 개념 줄에 보일 페이지 상태: 한국어 제목, 페이지가 없거나 한국어가 덜 된 것
  func pageState(_ concept: Concept) -> PageState {
    guard let data else { return PageState() }
    let folder = ConceptFolder(concept.cid, in: data)
    guard let page = Page.load(folder) else { return PageState(note: "페이지 만드는 중") }
    let missing = Translation.targets(page, layers: Layers.load(folder)).count
    return PageState(titleKo: page.titleKo, note: missing > 0 ? "한국어 \(missing)곳 남음" : nil)
  }

  // MARK: - 코멘트

  // 단위에 코멘트를 단다. 질문이면 물어보기를 대기열에 넣는다.
  func addComment(concept: String, unit: String, rev: Int, quote: String, kind: CommentKind, text: String) async throws {
    guard let data else { throw RequestError("데이터 폴더가 열려 있지 않습니다") }
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return }
    let comment = Comment(
      id: Comment.makeID(), at: Clock.isoLocal(), by: "learner", kind: kind, anchor: CommentAnchor(concept: concept, unit: unit, rev: rev, quote: quote),
      text: body)
    try CommentStore.append(data, comment)
    commentsVersion += 1
    if kind == .ask, let jobs {
      let config = try await agentConfig()
      let id = comment.id
      try await jobs.submit(config: config) { try Ask.prepare(commentID: id, $0) }
    }
  }

  func deleteComment(_ id: String) throws {
    guard let data else { return }
    try CommentStore.append(data, Comment(id: Comment.makeID(), at: Clock.isoLocal(), by: "learner", kind: .delete, target: id))
    commentsVersion += 1
  }

  // MARK: - 오늘과 모아 보기

  var allConcepts: [Concept] { concepts.values.flatMap { $0 }.sorted { $0.id < $1.id } }

  // 최근 며칠 사이에 페이지가 만들어진 개념 (페이지의 작업 id 날짜로 본다)
  func recentConcepts(days: Int) -> [Concept] {
    guard let data else { return [] }
    let since = JobID.stamp(Date().addingTimeInterval(-Double(days) * 86400)).prefix(8)
    _ = commentsVersion
    return allConcepts.compactMap { c -> (Concept, String)? in
      guard let page = Page.load(ConceptFolder(c.cid, in: data)), let job = page.provenance["job"]?.string, job.prefix(8) >= since else { return nil }
      return (c, job)
    }.sorted { $0.1 > $1.1 }.map(\.0)
  }

  func recentAnswers(days: Int) -> [(question: Comment, answer: Comment)] {
    guard let data else { return [] }
    _ = commentsVersion
    let all = CommentStore.load(data)
    let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let since = Clock.isoLocal(Date().addingTimeInterval(-Double(days) * 86400))
    return all.filter { $0.kind == .answer && $0.at >= since }.compactMap { a in a.replyTo.flatMap { byID[$0] }.map { ($0, a) } }.reversed()
  }

  func candidates() -> [Directive] {
    guard let data else { return [] }
    _ = commentsVersion
    return DirectiveStore.load(data).filter { $0.status == .candidate }
  }

  struct CrossLink {
    let from: Concept
    let to: Concept
    let note: String
    var id: String { "\(from.id)>\(to.id)" }
  }

  func crossLinks() -> [CrossLink] {
    let byID = Dictionary(allConcepts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return allConcepts.flatMap { c in c.links.compactMap { l in byID[l.concept].map { CrossLink(from: c, to: $0, note: l.note) } } }
  }

  struct PageCheck {
    let concept: String
    let title: String
    let question: String
    var id: String { "\(concept)#\(question.prefix(40))" }
  }

  func allChecks() -> [PageCheck] {
    guard let data else { return [] }
    return allConcepts.flatMap { c in
      (Page.load(ConceptFolder(c.cid, in: data))?.units ?? []).filter { $0.kind == .check }.map { PageCheck(concept: c.id, title: c.title, question: $0.text ?? "") }
    }
  }

  func allComments() -> [Comment] {
    guard let data else { return [] }
    _ = commentsVersion
    return CommentStore.load(data).filter { $0.kind != .answer }.reversed()
  }

  // MARK: - 다시 만들기

  // 다시 만들기 시트를 열 때의 대상
  var regenTarget: RegenTarget?

  // 요구를 남기고 다시 만들기를 대기열에 넣는다. 고치기는 그 결과를 답글로 달 이상해요 코멘트가 있어야 한다.
  func requestRegen(_ target: RegenTarget, op: DirectiveOp, note: String) async throws {
    guard let data, let jobs else { throw RequestError("데이터 폴더가 열려 있지 않습니다") }
    let config = try await agentConfig()
    var from = target.fromComment
    if op == .fix && from == nil {
      let flag = Comment(
        id: Comment.makeID(), at: Clock.isoLocal(), by: "learner", kind: .flag,
        anchor: CommentAnchor(concept: target.concept, unit: target.unit, rev: target.rev, quote: target.quote), text: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "고쳐 주세요" : note)
      try CommentStore.append(data, flag)
      from = flag.id
    }
    let d = try DirectiveStore.request(
      data, op: op, target: DirectiveTarget(concept: target.concept, unit: target.unit, rev: target.rev), note: note, fromComment: from)
    commentsVersion += 1
    let id = d.id
    try await jobs.submit(config: config) { try Regen.prepare(directiveID: id, $0) }
  }

  func acceptDirective(_ id: String) async {
    guard let data else { return }
    do {
      _ = try Regen.accept(data, directiveID: id)
      commentsVersion += 1
      if let d = DirectiveStore.load(data).first(where: { $0.id == id }), let cid = ConceptID(d.target.concept), let jobs, let config = try? await agentConfig() {
        let subject = cid.subject
        _ = try? await jobs.submit(config: config) { try Translation.prepare(subject: subject, $0) }
      }
    } catch {
      lastError = error.localizedDescription
      commentsVersion += 1
    }
  }

  func keepDirective(_ id: String) {
    guard let data else { return }
    try? Regen.keep(data, directiveID: id)
    commentsVersion += 1
  }

  // 화면에 보일 마지막 오류 (다시 만들기 받아들이기 등)
  var lastError: String?

  // 코멘트가 바뀌면 올린다 (학습 페이지를 다시 그리는 기준)
  private(set) var commentsVersion = 0

  // 처음 만든 목차를 확인한다 (관리자)
  func confirmSyllabus(_ subject: String) throws {
    guard let data, var s = Syllabus.load(data, subject: subject) else { return }
    s.confirmed = (by: "관리자", at: Clock.isoLocal())
    try s.write(data)
    reloadLibrary()
  }

  // 과목 꼬리표의 이름을 바꾸거나 다른 과목에 합친다. 작업이 도는 동안에는 하지 않는다.
  func renameSubject(_ subject: String, to name: String) throws -> SubjectRename.Result {
    guard let data else { throw RequestError("데이터 폴더가 열려 있지 않습니다") }
    guard !(jobs?.isBusy ?? false) else { throw RequestError("작업이 도는 동안에는 바꿀 수 없습니다. 작업이 끝난 뒤 다시 하세요") }
    let lock = DataLock(data)
    guard lock.tryAcquire() else { throw RequestError("다른 Jindesk 프로세스가 이 데이터 폴더를 쓰고 있습니다") }
    defer { lock.release() }
    let result = try SubjectRename.run(data, from: subject, toName: name)
    selection = nil
    reloadLibrary()
    return result
  }

  // 남은 일 가운데 아직 대기열에 없는 것
  var waitingWork: [PendingWork] {
    let busy = (jobs?.active ?? []) + (jobs?.queue ?? [])
    return pendingWork.filter { w in !busy.contains { $0.kind == w.kind && $0.target == w.target } }
  }

  // MARK: - 자료

  // 에이전트 작업의 설정. 토큰이 없거나 claude 가 너무 오래됐으면 던진다.
  func agentConfig() async throws -> RunnerConfig {
    guard let data else { throw RequestError("데이터 폴더가 열려 있지 않습니다") }
    var config = try await ConfigLoader.load(
      settings: admin, data: data, guardHelper: AppPaths.guardHelper, instructions: AppPaths.instructions, katex: AppPaths.katex)
    config.figureChecker = WebFigureChecker(renderer: AppPaths.renderer)
    return config
  }

  // 자료 넣기를 대기열에 넣는다. 넣기는 에이전트를 띄우지 않으므로 토큰이 없어도 된다.
  // 토큰이 있으면 그 설정으로 넣어, 뒤따르는 자료 읽기가 같은 설정으로 돈다.
  func submitIntake(_ request: IntakeRequest) async throws {
    guard let jobs else { throw RequestError("데이터 폴더가 열려 있지 않습니다") }
    let config: RunnerConfig
    if let agent = try? await agentConfig() {
      config = agent
    } else {
      config = await ConfigLoader.loadForRunner(settings: admin, guardHelper: AppPaths.guardHelper, instructions: AppPaths.instructions)
    }
    try await jobs.submit(config: config) { try SourceIntake.prepare(request, $0) }
  }

  // 남은 일을 모두 대기열에 넣는다
  func continuePending() async throws {
    guard let jobs else { throw RequestError("데이터 폴더가 열려 있지 않습니다") }
    let work = waitingWork
    guard !work.isEmpty else { return }
    let config = try await agentConfig()
    try await jobs.submitAll(config: config, work.map { w in Pipeline.prepare(w) })
  }

  // 자료 하나를 (다시) 읽는다
  func read(_ source: SourceSummary) async throws {
    guard let jobs else { throw RequestError("데이터 폴더가 열려 있지 않습니다") }
    let config = try await agentConfig()
    let id = source.id
    try await jobs.submit(config: config) { try SourceReading.prepare(sourceID: id, $0) }
  }

  // 자료의 꼬리표, 메모, 목차의 근거 표시를 고친다 (labels.yaml)
  func updateLabels(_ source: SourceSummary, labels: SourceLabels, memo: String?, syllabusBasis: Bool) throws {
    let canonical = LabelMatch.canonical(labels) { name in library.usedValues(name) }
    try SourceLabelsFile(source: source.id, labels: canonical, memo: memo, syllabusBasis: syllabusBasis).write(to: source.folder)
    reloadLibrary()
  }

  // 쪽 이미지. 캐시에 없으면 다시 그린다 (메인 스레드 밖에서).
  func pageImage(_ source: SourceSummary, page: Int) async -> URL? {
    let folder = source.folder
    let folders = folders
    return await Task.detached { try? SourcePages.image(folder, page: page, folders: folders) }.value
  }

  // 업데이트를 설치해도 되는가: 작업도, 백업도, 마이그레이션도 돌고 있지 않다
  var canInstallUpdate: Bool {
    guard backupStatus == nil else { return false }
    if case .migrating = phase { return false }
    return jobs?.active.isEmpty ?? true
  }

  // MARK: - 환경 점검

  func runDoctor() async {
    guard !doctorRunning else { return }
    doctorRunning = true
    let input = Doctor.Input(
      guardHelper: AppPaths.guardHelper, instructions: AppPaths.instructions, schemas: AppPaths.schemas, data: data, folders: folders,
      claudePath: admin.claudePath, app: app)
    doctor = await Doctor.run(input)
    tokenSaved = ClaudeToken.exists
    doctorRunning = false
  }

  // MARK: - 백업

  func makeBackup(into directory: URL) async -> String {
    guard let data else { return "데이터 폴더가 없습니다" }
    backupStatus = "백업을 만들고 있습니다"
    jobs?.hold(.backup)
    jobsChanged()
    defer {
      backupStatus = nil
      jobs?.release(.backup)
      jobsChanged()
    }
    do {
      let url = try await Backup.make(data, into: directory) {
        await MainActor.run { [weak self] in self?.backupStatus = "지금 도는 작업이 끝나면 백업을 만듭니다" }
      }
      lastBackup = url
      return "백업을 만들었습니다: \(url.lastPathComponent)"
    } catch {
      return "백업을 만들지 못했습니다: \(error.localizedDescription)"
    }
  }

  // MARK: - 관리자 설정

  func saveAdmin(_ settings: AdminSettings) {
    admin = settings
    settings.save(AppPaths.defaults)
    if let jobs { apply(settings, to: jobs) }
  }

  private func apply(_ settings: AdminSettings, to manager: JobManager) {
    manager.holdAtPercent = settings.resolvedHoldAtPercent
    for lane in JobLane.allCases where lane.adjustable { manager.setLimit(lane, settings.limit(lane)) }
  }

  func saveToken(_ token: String) throws {
    try ClaudeToken.save(token)
    tokenSaved = ClaudeToken.exists
  }

  func deleteToken() throws {
    try ClaudeToken.delete()
    tokenSaved = ClaudeToken.exists
  }

  func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func shutdown() {
    jobs?.shutdown()
    sleepGuard.update(active: false)
  }
}
