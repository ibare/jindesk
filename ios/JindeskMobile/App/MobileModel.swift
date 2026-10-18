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

  // 목록에서 고른 과목과 개념 (학습 페이지의 앞뒤 개념을 누르면 개념이 바뀐다)
  var subject: String?
  var concept: String?
  var sourcePeek: SourcePeek?
  private(set) var bucketName = UserDefaults.standard.string(forKey: bucketKey) ?? ""
  private(set) var hasBucketKey = bucketKeys.exists
  @ObservationIgnored private var pagesFrom: URL?
  // 스키마 버전이 달라 받지 못했을 때 띄울 업데이트 안내 (MOBILE.md 의 안내)
  var updateNotice: String?
  // 과목 개념 지도를 열 때 골라 둘 개념 (학습 페이지의 "개념 지도에서 보기")
  var mapFocus: String?
  var showSettings = false
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
    if let subject, concepts[subject] == nil { self.subject = nil }
    if let concept, self.concept(concept) == nil, Self.mapSubject(concept).flatMap({ concepts[$0] }) == nil { self.concept = nil }
  }

  // 개념이 있는 과목. 이름은 자료의 과목 꼬리표에서 온다.
  var subjects: [(id: String, name: String, count: Int)] {
    let names = Dictionary(library.subjects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    let order = library.subjects.map(\.id).filter { concepts[$0] != nil } + concepts.keys.filter { names[$0] == nil }.sorted()
    return order.map { ($0, names[$0] ?? $0, concepts[$0]?.count ?? 0) }
  }

  var allConcepts: [Concept] { concepts.values.flatMap { $0 }.sorted { $0.id < $1.id } }

  func concept(_ id: String) -> Concept? {
    guard let cid = ConceptID(id) else { return nil }
    return concepts[cid.subject]?.first { $0.id == id }
  }

  // 학습 페이지의 앞뒤 개념이나 목록에서 개념을 연다
  func open(_ id: String) {
    guard let cid = ConceptID(id), concept(id) != nil else { return }
    subject = cid.subject
    concept = id
  }

  // MARK: - 과목 개념 지도

  // 목록에서 개념 지도 줄의 선택 값
  static func mapSelection(_ subject: String) -> String { "map:" + subject }

  static func mapSubject(_ selection: String?) -> String? {
    guard let selection, selection.hasPrefix("map:") else { return nil }
    return String(selection.dropFirst(4))
  }

  // 학습 페이지의 "개념 지도에서 보기": 과목 지도를 그 개념을 고른 채 연다
  func openMap(focus id: String) {
    guard let cid = ConceptID(id) else { return }
    subject = cid.subject
    mapFocus = id
    concept = Self.mapSelection(cid.subject)
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
    }
    info.isNew = node.curatedOn == JobID.stamp(Date()).prefix(8).description
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
    // 화면 확인 (MOBILE.md 의 빌드와 시험): -mirrorFrom <데이터 폴더> -openConcept <개념 id> -walkTo <이웃 개념 id> -openMap <개념 id 또는 과목 id> -openSettings YES
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
        open(id)
      } else if let id = defaults.string(forKey: "openMap") {
        // 과목 지도를 그 개념을 고른 채 연다. 과목 id 만 주면 고르지 않고 연다.
        if ConceptID(id) != nil { openMap(focus: id) } else {
          subject = id
          concept = Self.mapSelection(id)
        }
      } else if let s = defaults.string(forKey: "openSubject") {
        subject = s
      }
      // 원래 자료의 그 쪽을 연다 (-openSource <자료 id>#<쪽>)
      if let text = defaults.string(forKey: "openSource"), let hash = text.firstIndex(of: "#"), let page = Int(text[text.index(after: hash)...]) {
        openSource(String(text[..<hash]), page: page)
      }
    }
  #endif
}
