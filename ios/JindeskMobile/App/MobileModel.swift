// 폰 앱 상태 (MOBILE.md). 받아 둔 사본에서 과목, 개념, 목차를 읽고, 데이터 리포에서 새 판을 받는다.
import JindeskKit
import Observation
import SwiftUI

@MainActor
@Observable
final class MobileModel {
  enum SyncState: Equatable {
    case idle
    case syncing(done: Int, total: Int)
    case failed(String)
  }

  // 출처 칩을 눌렀을 때 여는 원래 자료의 쪽 (MOBILE.md 의 원래 자료의 쪽)
  struct SourcePeek: Identifiable, Equatable {
    let source: String
    let title: String
    let total: Int
    var page: Int
    var id: String { source }
  }

  // 읽기 토큰을 둘 키체인 항목 (SETUP.md 의 폰 앱)
  static let tokenService = "com.mintae.Jindesk.mobile"
  static let tokenAccount = "github-read-token"
  static let configKey = "repo"
  // 자료 버킷 (DATA.md 의 자료 버킷): 이름은 설정에, 폰의 읽기 전용 HMAC 키는 키체인에 둔다
  static let bucketKey = "bucket"
  static let bucketKeys = BucketKeyStore(service: tokenService, account: "files-bucket-read-key")
  // 마지막으로 받기를 해 본 지 이만큼 지나야 앱으로 돌아올 때 다시 받는다
  static let quietInterval: TimeInterval = 60

  let mirror: RepoMirror
  private(set) var config: RepoConfig
  private(set) var hasToken: Bool
  private(set) var state: SyncState = .idle
  private(set) var manifest: MirrorManifest?
  private(set) var library = SourceLibrary(sources: [])
  private(set) var concepts: [String: [Concept]] = [:]
  private(set) var syllabi: [String: Syllabus] = [:]
  @ObservationIgnored private var lastAttempt: Date?

  // 과목 → 단원 → 개념 → 학습 페이지 (DECISIONS.md 39, 43).
  // 왼쪽 칸(iPhone 은 한 스택)에서 들어간 목록 단계. 비어 있으면 첫 화면(과목 목록)이다. 고른 것(.page)은 넣지 않는다.
  var lists: [Route] = []
  // 오른쪽 칸(iPhone 은 목록 위)에 연 것. 바뀌면 개념 지도의 상태를 비운다.
  var page: PageRoute? {
    didSet {
      guard page != oldValue else { return }
      mapSelected = nil
      mapPage = nil
      // 다른 것을 열면 페이지 안 찾기 막대를 닫는다 (찾기 결과에서 연 개념은 그 개념의 막대를 이미 열어 두었다)
      if let find = pageFind, page != .concept(find.concept) { pageFind = nil }
    }
  }
  // 학습 페이지 안 찾기 (DECISIONS.md 48). 찾기 결과에서 연 개념은 친 말로 연다
  var pageFind: PageFind?
  // 과목 개념 지도에서 고른 개념과, 지도에서 연 학습 페이지. iPad 를 돌리면 칸을 새로 만들므로(SplitLayout) 화면이 아니라 모델에 둔다.
  var mapSelected: String?
  var mapPage: String?
  var sourcePeek: SourcePeek?
  private(set) var bucketName = UserDefaults.standard.string(forKey: bucketKey) ?? ""
  private(set) var hasBucketKey = bucketKeys.exists
  @ObservationIgnored private var pagesFrom: URL?
  // 스키마 버전이 달라 받지 못했을 때 띄울 업데이트 안내 (MOBILE.md 의 안내)
  var updateNotice: String?
  var showSettings = false
  // 찾기와 사전에서 고른 용어나 기호 (시트로 보인다, DECISIONS.md 34)
  var lookup: Lookup?
  // 화면 찍기: 학습 페이지에 넘길 debug 값 (renderer/page.js 의 page.debug)
  var pageDebug: JSONValue?

  init(mirror: RepoMirror? = nil) {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    self.mirror = mirror ?? RepoMirror(root: support.appending(path: "mirror"))
    let saved = UserDefaults.standard.data(forKey: Self.configKey).flatMap { try? JSONDecoder().decode(RepoConfig.self, from: $0) }
    config = saved ?? RepoConfig()
    hasToken = Keychain.exists(service: Self.tokenService, account: Self.tokenAccount)
    #if DEBUG
      applyDebugArguments()
    #endif
    manifest = self.mirror.manifest
    reload()
    #if DEBUG
      applyDebugSelection(UserDefaults.standard)
    #endif
  }

  var data: DataFolder? { mirror.data }

  // 받아 둔 사본을 다시 읽는다
  func reload() {
    guard let data = mirror.data else {
      library = SourceLibrary(sources: [])
      concepts = [:]
      syllabi = [:]
      return
    }
    library = SourceLibrary.load(data)
    concepts = Dictionary(uniqueKeysWithValues: ConceptStore.subjects(data).map { ($0, ConceptStore.all(data, subject: $0)) })
    syllabi = Dictionary(uniqueKeysWithValues: concepts.keys.compactMap { s in Syllabus.load(data, subject: s).map { (s, $0) } })
    // 새 판에서 사라진 과목, 단원, 개념은 닫는다
    if let end = lists.firstIndex(where: { !exists($0) }) { lists.removeSubrange(end...) }
    if let page, !exists(page) { self.page = nil }
    if let mapSelected, concept(mapSelected) == nil { self.mapSelected = nil }
    if let mapPage, concept(mapPage) == nil { self.mapPage = nil }
  }

  private func exists(_ route: Route) -> Bool {
    switch route {
    case .subject(let s): concepts[s] != nil
    case .unit(let s, let key): units(s).contains { $0.key == key }
    case .dictionary: true
    case .page(let page): exists(page)
    }
  }

  private func exists(_ route: PageRoute) -> Bool {
    switch route {
    case .concept(let id): concept(id) != nil
    case .summary(let s, let key): units(s).contains { $0.key == key }
    case .map(let s): concepts[s] != nil
    }
  }

  // 개념이 있는 과목. 이름은 자료의 과목 꼬리표에서 온다.
  var subjects: [(id: String, name: String, count: Int)] {
    let names = Dictionary(library.subjects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    let order = library.subjects.map(\.id).filter { concepts[$0] != nil } + concepts.keys.filter { names[$0] == nil }.sorted()
    return order.map { ($0, names[$0] ?? $0, concepts[$0]?.count ?? 0) }
  }

  // 과목의 단원 (이름의 알파벳순, DECISIONS.md 39)
  func units(_ subject: String) -> [SubjectUnit] {
    SubjectUnits.make(concepts[subject] ?? [], syllabus: syllabi[subject])
  }

  // 그 과목에 하루 안에 정리된 개념이 있다
  func hasNew(subject: String) -> Bool {
    (concepts[subject] ?? []).contains { $0.isNew() }
  }

  var allConcepts: [Concept] { concepts.values.flatMap { $0 }.sorted { $0.id < $1.id } }

  func concept(_ id: String) -> Concept? {
    guard let cid = ConceptID(id) else { return nil }
    return concepts[cid.subject]?.first { $0.id == id }
  }

  // 학습 페이지의 앞뒤 개념, 찾기, 용어 시트, 단원 요약에서 개념을 연다: 목록이 그 개념의 단원까지 따라 들어가고 페이지를 연다.
  // 찾기에서 열면 친 말로 페이지 안 찾기 막대를 열어 찾은 말에 표시를 한다
  func open(_ id: String, find query: String? = nil) {
    guard let c = concept(id) else { return }
    let path: [Route] = [.subject(c.subject), .unit(c.subject, SubjectUnits.key(c, syllabus: syllabi[c.subject]))]
    if lists != path { lists = path }
    if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty { pageFind = PageFind(concept: id, query: query) }
    page = .concept(id)
  }

  // 학습 페이지 도구 막대의 찾기 단추
  func showPageFind(_ concept: String) {
    if pageFind?.concept != concept { pageFind = PageFind(concept: concept) }
    pageFind?.focus += 1
  }

  // 렌더러가 알린 수 (그 개념의 막대에만 적는다)
  func pageFindReport(concept: String, total: Int, index: Int) {
    guard pageFind?.concept == concept else { return }
    pageFind?.total = total
    pageFind?.index = index
  }

  // MARK: - 과목 개념 지도

  // 학습 페이지의 "개념 지도에서 보기": 목록을 그 과목의 단원 목록(개념 지도 줄이 있는 곳)으로 옮기고, 지도를 그 개념을 고른 채 연다
  func openMap(focus id: String) {
    guard let cid = ConceptID(id) else { return }
    if lists != [.subject(cid.subject)] { lists = [.subject(cid.subject)] }
    page = .map(cid.subject)
    mapPage = nil
    mapSelected = id
  }

  // 저장하지 않고 지금 받아 둔 개념에서 계산한다 (맥과 같은 엔진, PAGES.md 의 개념 지도)
  func conceptMap(_ subject: String, showOthers: Bool) -> ConceptMap {
    ConceptMap(subject: subject, concepts: concepts[subject] ?? [], all: allConcepts, showOthers: showOthers)
  }

  // 지도 노드에 보일 것: 목차 코드, 한국어 이름, 학습 페이지가 있는지, 오늘 정리됐는지
  struct NodeInfo: Equatable {
    // 다른 과목 개념이면 그 과목 이름
    var subject: String?
    var code: String?
    var ko: String?
    var hasPage = false
    var isNew = false
  }

  func nodeInfo(_ node: ConceptMap.Node) -> NodeInfo {
    var info = NodeInfo(code: node.item.map { $0.uppercased() } ?? node.itemProposed)
    if case .other(let subject) = node.kind { info.subject = subjectName(subject) }
    if let c = concept(node.id) {
      let titles = pageTitles(c)
      info.ko = titles.ko
      info.hasPage = titles.hasPage
      info.isNew = c.isNew()
    }
    return info
  }

  func subjectName(_ id: String) -> String { subjects.first { $0.id == id }?.name ?? id }

  func pageTitles(_ c: Concept) -> (ko: String?, hasPage: Bool) {
    guard let data, let page = Page.load(ConceptFolder(c.cid, in: data)) else { return (nil, false) }
    return (page.titleKo, true)
  }

  // 렌더러에 넘길 페이지 (JSON 글). 쓰는 단추를 그리지 않게 readOnly 를 넣는다.
  func pageJSON(_ c: Concept) -> String {
    guard let data else { return "{}" }
    var json = PageComposer.json(PageComposer.load(data, concept: c, library: library, all: allConcepts))
    if case .object(var o) = json {
      o["readOnly"] = .bool(true)
      if let pageDebug { o["debug"] = pageDebug }
      json = .object(o)
    }
    return JSONText.stringify(YAMLValue(json: json))
  }

  func sourceTitle(_ id: String) -> String {
    guard let s = library.source(id) else { return id }
    return (s.meta.original.name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
  }

  // 출처 칩: 그 자료의 그 쪽을 연다
  func openSource(_ id: String, page: Int) {
    sourcePeek = SourcePeek(source: id, title: sourceTitle(id), total: max(library.source(id)?.meta.pages ?? page, page), page: page)
  }

  // 받은 쪽은 앱 지원 폴더의 pages/ 에 둔다
  var pageImages: PageImages {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let client = bucketName.isEmpty ? nil : Self.bucketKeys.read().map { GCSClient(bucket: bucketName, key: $0) }
    return PageImages(root: support.appending(path: "pages"), client: client, localSource: pagesFrom)
  }

  func saveBucket(name: String, accessID: String, secret: String) throws {
    bucketName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    UserDefaults.standard.set(bucketName, forKey: Self.bucketKey)
    if !accessID.trimmingCharacters(in: .whitespaces).isEmpty || !secret.trimmingCharacters(in: .whitespaces).isEmpty {
      try Self.bucketKeys.save(BucketKey(accessID: accessID, secret: secret))
    }
    hasBucketKey = Self.bucketKeys.exists
  }

  // MARK: - 받기

  // 데이터 리포에서 새 판을 받는다. force 가 아니면 마지막으로 해 본 지 1분이 지났을 때만 한다.
  func sync(force: Bool) async {
    if case .syncing = state { return }
    guard config.isComplete, let token = (try? Keychain.read(service: Self.tokenService, account: Self.tokenAccount)) ?? nil else {
      if force { state = .failed("설정에서 리포와 토큰을 넣습니다") }
      return
    }
    if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.quietInterval { return }
    lastAttempt = Date()
    state = .syncing(done: 0, total: 0)
    do {
      let outcome = try await mirror.sync(config, token: token) { done, total in
        Task { @MainActor in
          if case .syncing = self.state { self.state = .syncing(done: done, total: total) }
        }
      }
      state = .idle
      manifest = mirror.manifest
      if case .updated = outcome { reload() }
    } catch {
      state = .failed(error.localizedDescription)
      if let mismatch = error as? MirrorError, mismatch.schema != nil { updateNotice = mismatch.message }
    }
  }

  func save(_ config: RepoConfig, token: String?) throws {
    self.config = config
    UserDefaults.standard.set(try JSONEncoder().encode(config), forKey: Self.configKey)
    if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
      try Keychain.write(service: Self.tokenService, account: Self.tokenAccount, value: token, label: "Jindesk 데이터 리포 읽기 토큰")
    }
    hasToken = Keychain.exists(service: Self.tokenService, account: Self.tokenAccount)
  }

  func deleteToken() throws {
    try Keychain.delete(service: Self.tokenService, account: Self.tokenAccount)
    hasToken = false
  }

  func clearMirror() {
    mirror.clear()
    pageImages.clear()
    manifest = nil
    state = .idle
    lastAttempt = nil
    reload()
  }

  #if DEBUG
    // 화면 확인 (MOBILE.md 의 빌드와 시험): -mirrorFrom <데이터 폴더> -openConcept <개념 id> [-findText <말>] -walkTo <이웃 개념 id> -openMap <개념 id 또는 과목 id> -openSettings YES
    private func applyDebugArguments() {
      let defaults = UserDefaults.standard
      if let path = defaults.string(forKey: "mirrorFrom") {
        do {
          try mirror.importLocal(URL(fileURLWithPath: path))
          config = RepoConfig(owner: "example", name: "jindesk-data", branch: "main")
        } catch {
          state = .failed("받아 둔 사본을 만들지 못했습니다: \(error.localizedDescription)")
        }
      }
      showSettings = defaults.bool(forKey: "openSettings")
      // 쪽 이미지를 버킷 대신 이 폴더(맥의 캐시처럼 <자료 id>/view/<쪽>.heic)에서 가져온다
      pagesFrom = defaults.string(forKey: "pagesFrom").map { URL(fileURLWithPath: $0) }
    }

    // 받아 둔 사본을 읽은 뒤에 고른다
    private func applyDebugSelection(_ defaults: UserDefaults) {
      if let id = defaults.string(forKey: "openConcept") {
        // 앞뒤 개념 지도에서 이 이웃을 누른다 (renderer/page.js 의 page.debug.walk)
        if let next = defaults.string(forKey: "walkTo") { pageDebug = .object(["walk": .array([.string(id), .string(next)])]) }
        // 페이지 안 찾기 막대를 이 말로 연다
        open(id, find: defaults.string(forKey: "findText"))
      } else if let id = defaults.string(forKey: "openMap") {
        // 과목 지도를 그 개념을 고른 채 연다. 과목 id 만 주면 고르지 않고 연다.
        if ConceptID(id) != nil { openMap(focus: id) } else {
          lists = [.subject(id)]
          page = .map(id)
        }
      } else if let s = defaults.string(forKey: "openSubject") {
        lists = [.subject(s)]
      }
      // 단원의 개념 목록을 연다 (-openUnit "unit:<과목 id>|<단원 키>", -openUnitSummary YES 면 단원 요약까지 연다).
      // 단원 키는 "item:<목차 코드>" 또는 "proposed:<단원 제안>"이다. 용어 시트를 띄운다 (-lookupTerm <영어 용어>)
      if let u = defaults.string(forKey: "openUnit"), u.hasPrefix("unit:") {
        let parts = u.dropFirst(5).split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2 {
          lists = [.subject(parts[0]), .unit(parts[0], parts[1])]
          if defaults.bool(forKey: "openUnitSummary") { page = .summary(parts[0], parts[1]) }
        }
      }
      if let t = defaults.string(forKey: "lookupTerm") { lookup = .term(t) }
      // 원래 자료의 그 쪽을 연다 (-openSource <자료 id>#<쪽>)
      if let text = defaults.string(forKey: "openSource"), let hash = text.firstIndex(of: "#"), let page = Int(text[text.index(after: hash)...]) {
        openSource(String(text[..<hash]), page: page)
      }
    }
  #endif
}
