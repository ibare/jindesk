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
// 모아 보기의 범주 (DECISIONS.md 34): 사전, 모음, 내 것
enum CollectionsTab: String, CaseIterable, Identifiable {
  case terms, symbols, commandTerms, formulas, mistakes, references, ib, links, checks, memos, sources

  var id: String { rawValue }

  var label: String {
    switch self {
    case .terms: "용어"
    case .symbols: "기호"
    case .commandTerms: "Command terms"
    case .formulas: "공식"
    case .mistakes: "실수"
    case .references: "더 볼 자료"
    case .ib: "IB 맥락"
    case .links: "연결"
    case .checks: "문제"
    case .memos: "메모"
    case .sources: "자료"
    }
  }

  static let groups: [(name: String, tabs: [CollectionsTab])] = [
    ("사전", [.terms, .symbols, .commandTerms]), ("모음", [.formulas, .mistakes, .references, .ib, .links]), ("내 것", [.checks, .memos, .sources]),
  ]
}

enum SubjectSelection: Hashable {
  case concept(String)
  case source(String)
  // 과목의 개념 지도 (과목 id)
  case map(String)
  // 단원 개요 (과목 id, 단원 키: "item:<목차 코드>" 또는 "proposed:<단원 제안>", DECISIONS.md 34)
  case unit(String, String)
  // 모아 보기의 항목 ("<범주>:<키>", DECISIONS.md 34)
  case entry(String)
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
    // 처음 켤 때, 또는 연결한 데이터 폴더를 찾지 못했을 때: 데이터 리포를 연결한다 (DATA.md 의 데이터 리포)
    case connecting(String?)
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
  private(set) var runSettings: RunSettings
  private(set) var tokenSaved = ClaudeToken.exists
  var section: SidebarSection = .today
  // 작업 화면에서 고른 작업 (상태 막대를 누르면 그 작업을 연다)
  var selectedJob: String?
  var settingsTab: SettingsTab = .run
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
  // 개념 지도를 열 때 골라 둘 개념 (학습 페이지의 "개념 지도에서 보기")
  var mapFocus: String?
  // 목록 칸이 따라가 보여 줄 개념 (학습 페이지의 앞뒤 개념이나 개념 지도에서 옮겨 갔을 때)
  var revealInList: String?
  // 출처 칩으로 연 원래 자료의 쪽
  var peek: SourcePeek?
  // 학습 페이지의 "자료와 나란히" (DECISIONS.md 34): 켜면 사이드바와 목록 칸을 접고 근거 쪽을 옆에 보인다
  var sideBySide = false
  // 모아 보기에서 고른 범주와 과목 (nil 이면 모든 과목)
  var collectionsTab = CollectionsTab.terms
  var collectionsSubject: String?
  // 찾기 (영어 원문과 한국어 곁 층)
  var searchText = "" {
    didSet { if searchText != oldValue { runSearch() } }
  }
  private(set) var searchResults: [SearchHit] = []
  // 찾기의 원래 자료 (자료 쪽 글자층, DECISIONS.md 34)
  private(set) var searchPageHits: [PageHit] = []
  @ObservationIgnored private lazy var searchIndex = SearchIndex(folders)
  var showIntake = false
  let update = UpdateStatus()
  // 데이터 리포 (DATA.md 의 데이터 리포): 이 맥의 앱 설정에서 연결한 리포, 마지막으로 커밋하고 올린 결과, 켤 때 받기의 문제
  private(set) var repoLink: RepoLink?
  private(set) var repo: DataRepo.Outcome?
  private(set) var repoPullProblem: String?
  private(set) var repoSyncing = false
  private(set) var repoTokenSaved = RepoToken.exists
  // 자료 버킷 (DATA.md 의 자료 버킷): 이 맥의 앱 설정에서 연결한 버킷, 마지막으로 맞춘 결과
  private(set) var bucketLink = BucketLinkStore.load()
  private(set) var bucketKeySaved = BucketKeyStore.mac.exists
  private(set) var bucket: SourceFiles.Outcome?
  private(set) var bucketSyncing = false
  @ObservationIgnored private var bucketAgain = false
  // 다음 커밋에 담을 까닭 (몇 초 모았다가 한 번에 커밋한다)
  @ObservationIgnored private var syncReasons: [String] = []
  @ObservationIgnored private var syncWait: Task<Void, Never>?

  @ObservationIgnored var updater: UpdateController?
  @ObservationIgnored private let sleepGuard = SleepGuard()

  init(folders: AppFolders = .standard()) {
    self.folders = folders
    runSettings = RunSettings.load(AppPaths.defaults)
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
    guard let link = RepoLinkStore.load() else {
      phase = .connecting(nil)
      return
    }
    // 연결한 폴더가 없어졌으면 새로 만들지 않고 다시 연결하게 한다 (데이터가 사라진 것처럼 보이지 않게)
    let saved = link.folder
    guard FileOps.exists(saved.url) || hasMigrationLeftovers(saved) else {
      phase = .connecting("데이터 폴더를 찾지 못했습니다: \(saved.path). 리포를 다시 연결합니다")
      return
    }
    repoLink = link
    await pullOnOpen(saved, link)
    await open(saved, creating: false)
  }

  private func hasMigrationLeftovers(_ data: DataFolder) -> Bool {
    FileOps.list(data.url.deletingLastPathComponent()).contains { $0.hasPrefix(".Jindesk-before-") }
  }

  // 데이터 리포를 연결하고 그 클론을 데이터 폴더로 연다 (처음 켤 때, 설정의 리포 바꾸기).
  // 빈 리포면 데이터 폴더를 새로 만들어 첫 커밋을 올리고, Jindesk 리포면 클론한다. 이전 리포와 그 폴더는 건드리지 않는다.
  // 실패하면 그 까닭을 돌려준다.
  func connect(url: String, token: String, path: String) async -> String? {
    guard !(jobs?.isBusy ?? false) else { return "작업이 도는 동안에는 바꿀 수 없습니다. 작업이 끝난 뒤 다시 합니다" }
    let link = RepoLink(url: url, path: DataFolder(path: (path as NSString).expandingTildeInPath).path)
    let errors = link.folder.issues(appBundle: AppPaths.bundle).filter { $0.isError && !$0.message.contains("다른 파일이 들어 있는") }
    guard errors.isEmpty else { return errors.map(\.message).joined(separator: " ") }
    if let value = token.nilIfBlank {
      do { try RepoToken.save(value) } catch { return error.localizedDescription }
      repoTokenSaved = RepoToken.exists
    }
    guard let saved = RepoToken.read() else { return "토큰을 넣습니다" }
    do {
      let result = try await DataRepo.connect(link, token: saved, app: app)
      RepoLinkStore.save(link)
      DataFolderStore.save(link.folder.url)
      repoLink = link
      repoPullProblem = nil
      if case .opened = result { await pullOnOpen(link.folder, link) }
      await open(link.folder, creating: false)
      if case .created(let error?) = result { repo = DataRepo.Outcome(at: Clock.isoLocal(), remote: link.url, error: error) }
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  func saveRepoToken(_ token: String) throws {
    try RepoToken.save(token)
    repoTokenSaved = RepoToken.exists
  }

  // 켤 때 원격이 앞서 있으면 받는다. 받지 못한 까닭은 앱 창에 보인다.
  private func pullOnOpen(_ data: DataFolder, _ link: RepoLink) async {
    guard let result = await DataRepo.pull(data, link: link, token: RepoToken.read()) else { return }
    switch result {
    case .pulled: notes.append("데이터 리포에서 새 판을 받았습니다")
    case .diverged: repoPullProblem = "기록이 갈라졌습니다. 다른 곳에서 이 리포에 올렸습니다. 올리지 않습니다"
    case .blocked: repoPullProblem = "리포에 새 판이 있는데 올리지 않은 변경이 있어 받지 못했습니다"
    case .unreachable(let why): repoPullProblem = "리포에 닿지 못해 새 판을 받지 못했습니다 — \(why)"
    case .same, .ahead: repoPullProblem = nil
    }
  }

  func open(_ data: DataFolder, creating: Bool) async {
    phase = .starting
    jobs?.shutdown()
    jobs = nil
    syncWait?.cancel()
    syncReasons = []
    repo = nil
    let migrator = Migrator(data: data, folders: folders, app: app, schemas: AppPaths.schemas)
    // 켠 뒤 첫 커밋의 까닭 (마이그레이션했으면 그 결과가 담긴다)
    var opened = "켤 때 남은 변경"
    do {
      notes = try migrator.recoverInterrupted()
      notes += migrator.removePreviousCopies()
      switch migrator.state() {
      case .uninitialized:
        guard creating else {
          phase = .connecting("\(data.path) 는 Jindesk 데이터 폴더가 아닙니다")
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
        opened = "스키마 \(report.from) → \(report.to) 마이그레이션"
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
    apply(runSettings, to: manager)
    manager.onFinish = { [weak self] s in
      self?.jobsChanged()
      // 넣은 자료의 원본과 쪽 이미지를 자료 버킷에 올린다
      if s.kind == .sourceIntake && s.phase == "done" { self?.syncBucket() }
      self?.scheduleSync("\(s.typeLabel) · \(s.title)\(s.phase == "failed" ? " (실패)" : "")")
    }
    manager.onPhase = { [weak self] _ in self?.jobsChanged() }
    jobs = manager
    history = RunHistory.load(folders, data: data)
    phase = .ready
    scheduleSync(opened)
    syncBucket()
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
      let pages = index.sourcePages(q)
      await MainActor.run { [weak self] in
        guard let self, self.searchText == q else { return }
        self.searchResults = hits
        self.searchPageHits = pages
      }
    }
  }

  // 원래 자료의 쪽에서 찾은 곳 (모아 보기의 용어)
  func sourcePageHits(_ query: String) -> [PageHit] { searchIndex.sourcePages(query) }

  // 찾기의 용어: 영어나 한국어에 찾는 말이 든 용어집의 용어
  func searchTerms(_ query: String) -> [GlossaryTerm] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard let data, !q.isEmpty else { return [] }
    return Glossary.load(data).terms.filter { t in (t.names + [t.ko]).contains { $0.localizedCaseInsensitiveContains(q) } }
      .sorted { $0.en.localizedCaseInsensitiveCompare($1.en) == .orderedAscending }
  }

  // 찾기의 기호: 기호나 뜻에 찾는 말이 든 개념의 기호
  func searchSymbols(_ query: String) -> [(symbol: String, meaning: String)] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return [] }
    var seen = Set<String>()
    return allConcepts.flatMap(\.symbols).filter { s in
      (TexText.display(s.symbol).localizedCaseInsensitiveContains(q) || s.meaning.localizedCaseInsensitiveContains(q)) && seen.insert(s.symbol).inserted
    }.map { ($0.symbol, $0.meaning) }
  }

  // 원래 자료의 그 쪽을 쓴 개념
  func concepts(using source: String, page: Int) -> [Concept] {
    inLearningOrder(allConcepts.filter { c in c.occurrences.contains { $0.source == source && $0.pages.contains(page) } })
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
    var hasPage = false
    // 7일 안에 페이지를 만들었다 (페이지의 작업 id 날짜로 본다)
    var isNew = false
    // 페이지를 만든 시각 (HH:mm)
    var madeAt: String?
    var checks = 0
  }

  // 개념 줄에 보일 페이지 상태: 한국어 제목, 페이지가 없거나 한국어가 덜 된 것, 새로 만든 것, 확인 문제 수
  func pageState(_ concept: Concept) -> PageState {
    guard let data else { return PageState() }
    let folder = ConceptFolder(concept.cid, in: data)
    guard let page = Page.load(folder) else { return PageState(note: "페이지 만드는 중") }
    let missing = Translation.targets(page, layers: Layers.load(folder)).count
    let job = page.provenance["job"]?.string ?? ""
    return PageState(
      titleKo: page.titleKo, note: missing > 0 ? "한국어 \(missing)곳 남음" : nil, hasPage: true,
      isNew: job.prefix(8) >= JobID.stamp(Date().addingTimeInterval(-7 * 86400)).prefix(8), madeAt: Self.jobTime(job),
      checks: page.units.filter { $0.kind == .check }.count)
  }

  // 작업 id 의 시각 ("20261018-2301-page-…" → "23:01")
  static func jobTime(_ job: String) -> String? {
    let parts = job.split(separator: "-")
    guard parts.count > 1, parts[1].count == 4, parts[1].allSatisfy(\.isNumber) else { return nil }
    return "\(parts[1].prefix(2)):\(parts[1].suffix(2))"
  }

  // 과목 개념의 배우는 순서 (DECISIONS.md 32)
  func learningRank(_ subject: String) -> [String: Int] {
    Dictionary(conceptMap(subject, showOthers: false).learningOrder().enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
  }

  // 배우는 순서로 놓는다. 과목이 섞이면 과목끼리 모은다.
  func inLearningOrder(_ list: [Concept]) -> [Concept] {
    var ranks: [String: [String: Int]] = [:]
    for s in Set(list.map(\.subject)) { ranks[s] = learningRank(s) }
    return list.sorted { a, b in
      a.subject != b.subject ? a.subject < b.subject : (ranks[a.subject]?[a.id] ?? .max, a.id) < (ranks[b.subject]?[b.id] ?? .max, b.id)
    }
  }

  // 단원: 이름, 개념(배우는 순서), 목차의 MYP 탐구 진술 (DECISIONS.md 34)
  struct UnitContents {
    let title: String
    let concepts: [Concept]
    let inquiry: String?
  }

  func unit(_ subject: String, _ key: String) -> UnitContents {
    let all = concepts[subject] ?? []
    if key.hasPrefix("item:") {
      let code = String(key.dropFirst(5))
      let item = syllabi[subject]?.item(code)
      return UnitContents(
        title: item.map { "\($0.code) \($0.title)" } ?? code, concepts: inLearningOrder(all.filter { $0.item.map(ItemPath.dir) == ItemPath.dir(code) }),
        inquiry: item?.myp?.statementOfInquiry)
    }
    let name = String(key.dropFirst(9))
    return UnitContents(title: name, concepts: inLearningOrder(all.filter { $0.item == nil && ($0.itemProposed ?? "목차 밖") == name }), inquiry: nil)
  }

  // 과목의 개념 지도 (PAGES.md 의 개념 지도). 저장하지 않고 지금 읽어 둔 개념 목록에서 계산한다.
  func conceptMap(_ subject: String, showOthers: Bool = true) -> ConceptMap {
    ConceptMap(subject: subject, concepts: concepts[subject] ?? [], all: allConcepts, showOthers: showOthers)
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
    scheduleSync("코멘트")
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
    scheduleSync("코멘트 지우기")
  }

  // MARK: - 오늘과 모아 보기

  var allConcepts: [Concept] { concepts.values.flatMap { $0 }.sorted { $0.id < $1.id } }

  // 최근 며칠 사이에 넣은 자료 (오늘), 새것부터
  func recentSources(days: Int) -> [SourceSummary] {
    let since = Clock.isoLocal(Date().addingTimeInterval(-Double(days) * 86400))
    return library.sources.filter { $0.meta.received >= since }.sorted { $0.meta.received > $1.meta.received }
  }

  // 자료에서 정리된 개념 (개념의 출처에 그 자료가 있다), 배우는 순서로
  func concepts(from source: String) -> [Concept] {
    inLearningOrder(allConcepts.filter { c in c.occurrences.contains { $0.source == source } })
  }

  // 자료가 붙은 과목의 이름
  func subjectName(_ source: SourceSummary) -> String? {
    library.subjects.first { s in s.sources.contains { $0.id == source.id } }?.name
  }

  // 개념마다 남은 코멘트 수 (답글은 빼고)
  func commentCounts() -> [String: Int] {
    guard let data else { return [:] }
    _ = commentsVersion
    var out: [String: Int] = [:]
    for c in CommentStore.load(data) where c.kind != .answer {
      if let id = c.anchor?.concept { out[id, default: 0] += 1 }
    }
    return out
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
    let concept: Concept
    let unit: String
    let question: String
    let answer: String?
    var id: String { "\(concept.id)#\(unit)" }
  }

  // 모든 학습 페이지의 확인 문제. 과목끼리, 배우는 순서로
  func allChecks() -> [PageCheck] {
    guard let data else { return [] }
    return inLearningOrder(allConcepts).flatMap { c in
      (Page.load(ConceptFolder(c.cid, in: data))?.units ?? []).filter { $0.kind == .check }.map {
        PageCheck(concept: c, unit: $0.id, question: $0.text ?? "", answer: $0.block?["answer"]?.string)
      }
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
    scheduleSync("다시 만들기 요구 · \(op.label)")
    let id = d.id
    try await jobs.submit(config: config) { try Regen.prepare(directiveID: id, $0) }
  }

  func acceptDirective(_ id: String) async {
    guard let data else { return }
    do {
      _ = try Regen.accept(data, directiveID: id)
      commentsVersion += 1
      scheduleSync("새 판 받아들이기")
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
    scheduleSync("지금 판 유지")
  }

  // 화면에 보일 마지막 오류 (다시 만들기 받아들이기 등)
  var lastError: String?

  // 코멘트가 바뀌면 올린다 (학습 페이지를 다시 그리는 기준)
  private(set) var commentsVersion = 0

  // 처음 만든 목차를 확인한다
  func confirmSyllabus(_ subject: String) throws {
    guard let data, var s = Syllabus.load(data, subject: subject) else { return }
    s.confirmed = (by: "사람", at: Clock.isoLocal())
    try s.write(data)
    reloadLibrary()
    scheduleSync("목차 확인 · \(subject)")
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
    scheduleSync("과목 이름 바꾸기 · \(subject) → \(name)")
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
      settings: runSettings, data: data, guardHelper: AppPaths.guardHelper, instructions: AppPaths.instructions, katex: AppPaths.katex)
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
      config = await ConfigLoader.loadForRunner(settings: runSettings, guardHelper: AppPaths.guardHelper, instructions: AppPaths.instructions)
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
    scheduleSync("자료 꼬리표")
  }

  // 쪽 이미지. 캐시에 없으면 다시 그린다 (메인 스레드 밖에서).
  // 쪽 보기: 맥과 폰이 같이 보는 쪽 이미지(HEIC, 긴 변 2000). 로컬에 없으면 원본에서 그리거나 자료 버킷에서 받는다.
  func pageImage(_ source: SourceSummary, page: Int) async -> URL? {
    let folders = folders
    let client = bucketClient()
    return await Task.detached { try? await SourceFiles.viewImage(source, page: page, folders: folders, client: client) }.value
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
      claudePath: runSettings.claudePath, app: app, repo: repoLink, bucket: bucketLink)
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
      // 백업하는 동안 미룬 커밋
      if !syncReasons.isEmpty { armSync() }
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

  // MARK: - 데이터 리포

  // 바뀐 것을 몇 초 모았다가 커밋하고 올린다 (DATA.md 의 데이터 리포). 연결한 리포의 데이터 폴더가 아니면 하지 않는다.
  func scheduleSync(_ reason: String) {
    guard let data, let link = repoLink, link.owns(data) else { return }
    if !syncReasons.contains(reason) { syncReasons.append(reason) }
    armSync()
  }

  // "지금 올리기", "다시 올리기"
  func syncNow() {
    guard let data, let link = repoLink, link.owns(data) else { return }
    if syncReasons.isEmpty { syncReasons.append("다시 올리기") }
    armSync(after: .zero)
  }

  private func armSync(after delay: Duration = .seconds(3)) {
    syncWait?.cancel()
    syncWait = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.runSync()
    }
  }

  // 한 번에 하나만 돈다. 도는 동안 들어온 까닭은 끝난 뒤에 다시 한다. 백업을 만드는 동안과 마이그레이션 중에는 하지 않는다.
  private func runSync() async {
    guard let data, let link = repoLink, !repoSyncing, backupStatus == nil, phase == .ready, !syncReasons.isEmpty else { return }
    repoSyncing = true
    let reasons = syncReasons
    syncReasons = []
    let outcome = await DataRepo.sync(data, link: link, token: RepoToken.read(), message: DataRepo.message(reasons))
    repoSyncing = false
    repo = outcome
    if outcome.pushed { repoPullProblem = nil }
    if !syncReasons.isEmpty { armSync() }
  }

  // MARK: - 자료 버킷

  func bucketClient() -> GCSClient? {
    guard let link = bucketLink, !link.name.isEmpty, let key = BucketKeyStore.mac.read() else { return nil }
    return GCSClient(bucket: link.name, key: key)
  }

  // 버킷 이름과 쓰기용 키를 저장하고 맞춘다 (설정)
  func saveBucket(name: String, accessID: String, secret: String) throws {
    let link = BucketLink(name: name)
    guard !link.name.isEmpty else { throw RequestError("버킷 이름을 넣습니다") }
    if !accessID.trimmingCharacters(in: .whitespaces).isEmpty || !secret.trimmingCharacters(in: .whitespaces).isEmpty {
      try BucketKeyStore.mac.save(BucketKey(accessID: accessID, secret: secret))
    }
    guard BucketKeyStore.mac.exists else { throw RequestError("접근 id 와 비밀을 넣습니다") }
    BucketLinkStore.save(link)
    bucketLink = link
    bucketKeySaved = true
    bucket = nil
    syncBucket()
  }

  // 로컬에 없는 원본을 받고, 다 올리지 않은 자료를 올린다. 한 번에 하나만 돈다. 도는 동안 부르면 끝난 뒤 한 번 더 한다.
  func syncBucket() {
    // 화면 찍기 모드는 실제 버킷을 건드리지 않는다
    guard phase == .ready, !isSnapshot, let client = bucketClient() else { return }
    guard !bucketSyncing else {
      bucketAgain = true
      return
    }
    bucketSyncing = true
    let library = library
    let folders = folders
    Task { [weak self] in
      let outcome = await Task.detached { await SourceFiles.sync(library, folders: folders, client: client) }.value
      guard let self else { return }
      self.bucket = outcome
      self.bucketSyncing = false
      if outcome.downloaded > 0 { self.reloadLibrary() }
      if self.bucketAgain {
        self.bucketAgain = false
        self.syncBucket()
      }
    }
  }

  // 앱 창에 보일 데이터 리포의 문제 (올리지 못했거나 받지 못했다)
  var repoProblem: String? {
    if let error = repo?.error { return error }
    return repoPullProblem
  }

  // MARK: - 설정

  func saveRunSettings(_ settings: RunSettings) {
    runSettings = settings
    settings.save(AppPaths.defaults)
    if let jobs { apply(settings, to: jobs) }
  }

  private func apply(_ settings: RunSettings, to manager: JobManager) {
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
