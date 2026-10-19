import Foundation
import JindeskKit

// 자료 묶음 (DECISIONS.md 35): 오늘의 묶음 카드와 묶음 보기가 쓴다.
extension AppModel {
  func bundle(_ id: String) -> SourceBundle? { bundles.first { $0.id == id } }

  func bundle(of source: String) -> SourceBundle? { bundles.first { $0.sources.contains(source) } }

  func members(_ bundle: SourceBundle) -> [SourceSummary] { bundle.sources.compactMap(library.source) }

  // 묶음 이름. 읽기 전에는 첫 파일 이름
  func bundleTitle(_ bundle: SourceBundle) -> String {
    bundle.title ?? members(bundle).first.map(SourceRow.title) ?? bundle.id
  }

  // 묶음이 마지막으로 바뀐 때 (가장 늦게 넣은 자료). 나중에 자료를 더한 묶음은 더한 날로 올라온다.
  func lastReceived(_ bundle: SourceBundle) -> String {
    members(bundle).map(\.meta.received).max() ?? bundle.created
  }

  func recentBundles(days: Int) -> [SourceBundle] {
    let since = Clock.isoLocal(Date().addingTimeInterval(-Double(days) * 86400))
    return bundles.filter { lastReceived($0) >= since }.sorted { lastReceived($0) > lastReceived($1) }
  }

  // 묶음의 자료에서 정리된 개념 (배우는 순서)
  func concepts(fromBundle bundle: SourceBundle) -> [Concept] {
    let members = Set(bundle.sources)
    return inLearningOrder(allConcepts.filter { c in c.occurrences.contains { members.contains($0.source) } })
  }

  // 묶음의 자료에서 나왔는데 아직 개념이 되지 못한 엔트리와 보류 까닭
  func heldEntries(_ bundle: SourceBundle) -> [(entry: Entry, reason: String)] {
    guard let data, let subject = BundleStore.subject(bundle, library: library) else { return [] }
    let members = Set(bundle.sources)
    return ConceptCuration.heldEntries(data, subject: subject).filter { members.contains($0.entry.source) }
  }

  enum StageState: Equatable {
    case none
    case waiting(String)
    case active(String)
    case done(String)
    case failed(String)

    var label: String {
      switch self {
      case .none: ""
      case .waiting(let s), .active(let s), .done(let s), .failed(let s): s
      }
    }
  }

  // 묶음의 단계: 묶음 읽기, 묶음 정리, 페이지, 한국어
  struct BundleProgress: Equatable {
    var reading = StageState.none
    var curation = StageState.none
    var pages = StageState.none
    var korean = StageState.none

    var stages: [(name: String, state: StageState)] {
      [("묶음 읽기", reading), ("묶음 정리", curation), ("페이지", pages), ("한국어", korean)]
    }

    // 지금 단계 한 줄 (오늘의 카드)
    var summary: String {
      for (name, state) in stages {
        switch state {
        case .active(let s): return "\(name) · \(s)"
        case .failed(let s): return "\(name) 실패 · \(s)"
        case .waiting(let s): return "\(name) \(s)"
        default: continue
        }
      }
      return "끝남"
    }
  }

  func progress(_ bundle: SourceBundle) -> BundleProgress {
    var p = BundleProgress()
    let active = jobs?.active ?? []
    let queue = jobs?.queue ?? []
    func job(_ kind: JobKind, _ target: String) -> StageState? {
      if let s = active.first(where: { $0.kind == kind && $0.target == target }) { return .active(s.phaseLabel) }
      if queue.contains(where: { $0.kind == kind && $0.target == target }) { return .waiting("대기") }
      return nil
    }
    func failed(_ kind: JobKind, _ target: String) -> String? {
      guard let last = history.first(where: { $0.snapshot.kind == kind && $0.snapshot.target == target }), last.snapshot.phase == "failed" else { return nil }
      return last.snapshot.error ?? "실패"
    }
    let members = members(bundle)
    let unread = members.filter { readSources[$0.id] == nil }.count
    if let j = job(.sourceReading, bundle.id) {
      p.reading = j
    } else if unread == 0 {
      p.reading = .done("자료 \(members.count)")
    } else if let why = failed(.sourceReading, bundle.id) {
      p.reading = .failed(why)
    } else {
      p.reading = .waiting(members.count > unread ? "더한 자료 \(unread)" : "남음")
    }
    guard unread == 0 else { return p }

    let subject = BundleStore.subject(bundle, library: library)
    if let j = job(.conceptCuration, bundle.id) {
      p.curation = j
    } else if pendingWork.contains(where: { $0.kind == .conceptCuration && $0.target == bundle.id }) {
      p.curation = failed(.conceptCuration, bundle.id).map(StageState.failed) ?? .waiting("남음")
    } else {
      let concepts = concepts(fromBundle: bundle)
      p.curation = .done("개념 \(concepts.count)")
    }
    guard case .done = p.curation else { return p }

    let concepts = concepts(fromBundle: bundle)
    let states = concepts.map(pageState)
    let made = states.filter(\.hasPage).count
    if let subject, let j = job(.pageBuild, subject), made < concepts.count {
      p.pages = .active("\(j.label) \(made)/\(concepts.count)")
    } else if made < concepts.count {
      p.pages = .waiting("\(made)/\(concepts.count)")
    } else {
      p.pages = .done("\(made)")
    }
    guard case .done = p.pages else { return p }

    let missing = states.filter { $0.note != nil }.count
    if let subject, let j = job(.translation, subject), missing > 0 {
      p.korean = j
    } else {
      p.korean = missing > 0 ? .waiting("\(missing)개 남음") : .done("")
    }
    return p
  }

  // 자료를 다른 묶음으로 옮긴다. 묶음 id 가 nil 이면 새 묶음
  func moveSource(_ source: String, to target: String?) throws {
    guard let data else { throw RequestError("데이터 폴더가 열려 있지 않습니다") }
    let moved = try BundleStore.move(data, source: source, to: target)
    reloadLibrary()
    scheduleSync("자료 묶음 옮기기")
    if case .bundle(let id)? = selection, bundle(id) == nil { selection = .bundle(moved) }
  }

  // 한 묶음의 자료를 모두 다른 묶음으로 옮긴다
  func mergeBundle(_ from: String, into target: String) throws {
    guard let data else { throw RequestError("데이터 폴더가 열려 있지 않습니다") }
    try BundleStore.merge(data, from: from, into: target)
    reloadLibrary()
    scheduleSync("자료 묶음 합치기")
    selection = .bundle(target)
  }

  func setBundleMemo(_ id: String, memo: String?) throws {
    guard let data else { throw RequestError("데이터 폴더가 열려 있지 않습니다") }
    try BundleStore.setMemo(data, id: id, memo: memo)
    reloadLibrary()
    scheduleSync("자료 묶음 메모")
  }
}
