// 개념 지도 (PAGES.md 의 개념 지도, DECISIONS.md 26). 과목의 개념을 선수 개념(prerequisites)으로 이은 그래프와 그 배치.
// 파일로 저장하지 않는다. 개념 목록에서 그릴 때마다 계산한다. "다음 개념"은 선수 개념을 거꾸로 찾은 것이다.
import Foundation

public struct ConceptMap: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    // 이 과목의 개념
    case concept
    // 다른 과목의 개념. 이 과목 개념의 선수 개념일 때만 지도에 든다
    case other(subject: String)
    // 아직 없는 개념("missing:<제목>"), 또는 찾지 못한 개념 id
    case missing
  }

  public struct Node: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let kind: Kind
    // 개념 폴더의 항목(a.1). 목차 밖이면 nil
    public let item: String?
    // 목차 밖 개념의 단원·주제 제안
    public let itemProposed: String?
    // 개념을 정리한 작업의 날짜 (provenance.job 의 앞 8자리, yyyyMMdd)
    public let curatedOn: String?
  }

  // 선수 개념(from) → 개념(to)
  public struct Edge: Sendable, Equatable, Hashable {
    public let from: String
    public let to: String
  }

  public let subject: String
  public let nodes: [Node]
  public let edges: [Edge]
  // 감춘 다른 과목 선수 개념으로 가는 연결 수
  public let hiddenLinks: Int
  private let index: [String: Int]
  private let preds: [String: [String]]
  private let succs: [String: [String]]

  // concepts: 이 과목의 개념, all: 모든 과목의 개념 (다른 과목 선수 개념의 이름)
  public init(subject: String, concepts: [Concept], all: [Concept], showOthers: Bool = true) {
    self.subject = subject
    let mine = concepts.filter { $0.subject == subject }
    var nodes: [Node] = []
    var index: [String: Int] = [:]
    func add(_ n: Node) {
      index[n.id] = nodes.count
      nodes.append(n)
    }
    for c in mine where index[c.id] == nil {
      add(Node(id: c.id, title: c.title, kind: .concept, item: c.item, itemProposed: c.itemProposed, curatedOn: Self.day(c.provenance)))
    }
    let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var edges: [Edge] = []
    var seen = Set<Edge>()
    var hidden = 0
    for c in mine {
      for ref in c.prerequisites where ref != c.id {
        if index[ref] == nil {
          if let other = byID[ref], other.subject != subject {
            guard showOthers else {
              hidden += 1
              continue
            }
            add(
              Node(
                id: ref, title: other.title, kind: .other(subject: other.subject), item: other.item, itemProposed: other.itemProposed,
                curatedOn: Self.day(other.provenance)))
          } else {
            add(Node(id: ref, title: Self.missingTitle(ref), kind: .missing, item: nil, itemProposed: nil, curatedOn: nil))
          }
        }
        let e = Edge(from: ref, to: c.id)
        if seen.insert(e).inserted { edges.append(e) }
      }
    }
    var preds: [String: [String]] = [:]
    var succs: [String: [String]] = [:]
    for e in edges {
      preds[e.to, default: []].append(e.from)
      succs[e.from, default: []].append(e.to)
    }
    self.nodes = nodes
    self.edges = edges
    self.hiddenLinks = hidden
    self.index = index
    self.preds = preds
    self.succs = succs
  }

  static func day(_ provenance: YAMLMap) -> String? {
    guard let job = provenance["job"]?.string, job.count >= 8 else { return nil }
    let d = String(job.prefix(8))
    return d.allSatisfy(\.isNumber) ? d : nil
  }

  static func missingTitle(_ ref: String) -> String {
    ref.hasPrefix("missing:") ? String(ref.dropFirst(8)) : ref
  }

  // MARK: - 찾기

  public func node(_ id: String) -> Node? { index[id].map { nodes[$0] } }

  // 바로 앞 선수 개념
  public func prerequisites(of id: String) -> [String] { preds[id] ?? [] }

  // 바로 다음 개념 (이 개념을 선수 개념으로 둔 개념)
  public func next(of id: String) -> [String] { succs[id] ?? [] }

  // 거슬러 올라가는 선수 개념 전체
  public func ancestors(of id: String) -> Set<String> { reach(id, preds) }

  // 이어지는 개념 전체
  public func descendants(of id: String) -> Set<String> { reach(id, succs) }

  private func reach(_ start: String, _ next: [String: [String]]) -> Set<String> {
    var out = Set<String>()
    var stack = next[start] ?? []
    while let id = stack.popLast() {
      guard out.insert(id).inserted else { continue }
      stack += next[id] ?? []
    }
    out.remove(start)
    return out
  }

  // 가장 먼 선수 개념까지 몇 단계인지 (선수 개념이 없으면 0)
  public func depth(of id: String) -> Int {
    var memo: [String: Int] = [:]
    var visiting = Set<String>()
    func walk(_ id: String) -> Int {
      if let v = memo[id] { return v }
      guard visiting.insert(id).inserted else { return 0 }
      let ps = preds[id] ?? []
      let v = ps.isEmpty ? 0 : ps.map(walk).max()! + 1
      visiting.remove(id)
      memo[id] = v
      return v
    }
    return walk(id)
  }

  public var conceptCount: Int { nodes.filter { $0.kind == .concept }.count }
  public var missingCount: Int { nodes.filter { $0.kind == .missing }.count }
  // 선수 연결 수 (감춘 다른 과목 연결도 센다)
  public var linkCount: Int { edges.count + hiddenLinks }

  // MARK: - 배치

  public enum Arrangement: String, Sendable, CaseIterable {
    // 선수 개념이 몇 겹 쌓였는지로 칸을 나눈다. 왼쪽이 먼저 배울 것
    case learning
    // 강의 계획 항목마다 한 칸
    case syllabus
  }

  public struct Layout: Sendable, Equatable {
    // 칸과 행. 행은 노드 하나의 높이를 1 로 센 위치다 (배우는 순서에서는 소수가 될 수 있다)
    public struct Place: Sendable, Equatable {
      public let column: Int
      public let row: Double
    }

    // 목차대로일 때 칸 머리
    public enum Header: Sendable, Equatable {
      // 다른 과목·아직 없는 개념
      case outside
      // 목차 항목 (개념 폴더의 항목, a.1)
      case item(String)
      // 목차 밖. 단원 제안이 있으면 그 이름
      case unplaced(String?)
    }

    public let places: [String: Place]
    public let columns: Int
    // 가장 아래 노드의 행 + 1
    public let rows: Double
    public let headers: [Header]
  }

  public func layout(_ arrangement: Arrangement, syllabus: Syllabus? = nil) -> Layout {
    switch arrangement {
    case .learning: learningLayout()
    case .syllabus: syllabusLayout(syllabus)
    }
  }

  // 칸: 이 과목 개념은 선수 개념이 몇 겹인지. 선수 개념이 없는 개념과 다른 과목·아직 없는 개념은 가장 이른 다음 개념의 바로 앞 칸.
  // 순환은 그 자리에서 끊는다.
  public func layers() -> [String: Int] {
    var layer: [String: Int] = [:]
    var visiting = Set<String>()
    let isConcept = { (id: String) in index[id].map { nodes[$0].kind == .concept } ?? false }
    func walk(_ id: String) -> Int {
      if let v = layer[id] { return v }
      guard visiting.insert(id).inserted else { return 0 }
      let ps = (preds[id] ?? []).filter(isConcept)
      let v = ps.isEmpty ? 0 : ps.map(walk).max()! + 1
      visiting.remove(id)
      layer[id] = v
      return v
    }
    for n in nodes where n.kind == .concept { _ = walk(n.id) }
    for n in nodes where n.kind == .concept && !(preds[n.id] ?? []).contains(where: isConcept) {
      if let m = (succs[n.id] ?? []).compactMap({ layer[$0] }).min() { layer[n.id] = max(layer[n.id] ?? 0, m - 1) }
    }
    for n in nodes where n.kind != .concept {
      layer[n.id] = ((succs[n.id] ?? []).compactMap { layer[$0] }.min() ?? 1) - 1
    }
    if let low = layer.values.min(), low < 0 {
      for k in layer.keys { layer[k]! -= low }
    }
    return layer
  }

  // 이 과목 개념의 배우는 순서 (목록의 차례, DECISIONS.md 32): 배우는 순서 배치의 칸, 같은 칸에서는 위에서 아래로
  public func learningOrder() -> [String] {
    let places = learningLayout().places
    return nodes.enumerated().filter { $0.element.kind == .concept }.sorted { a, b in
      let pa = places[a.element.id], pb = places[b.element.id]
      return (pa?.column ?? 0, pa?.row ?? 0, a.offset) < (pb?.column ?? 0, pb?.row ?? 0, b.offset)
    }.map(\.element.id)
  }

  // 한 칸 안에서 원하는 높이 차례로 놓되 1 행씩은 떨어지게. 밀려 내려간 만큼 칸 전체를 조금 올린다.
  static func pack(_ wants: [Double]) -> [Double] {
    var out: [Double] = []
    for (k, w) in wants.enumerated() { out.append(k == 0 ? w : max(w, out[k - 1] + 1)) }
    guard !out.isEmpty else { return out }
    let shift = zip(wants, out).map { $0 - $1 }.reduce(0, +) / Double(out.count)
    return out.map { $0 + shift }
  }

  private func learningLayout() -> Layout {
    let layer = layers()
    let count = (layer.values.max() ?? -1) + 1
    var cols = Array(repeating: [String](), count: count)
    for n in nodes { cols[layer[n.id] ?? 0].append(n.id) }
    let avg = { (a: [Double]) in a.reduce(0, +) / Double(a.count) }
    // 왼쪽 칸부터 선수 개념의 높이에 가깝게 놓는다. 선수 개념이 없는 노드는 앞 차례에서 정한 다음 개념의 높이를 따른다.
    var prev: [String: Double]?
    var y: [String: Double] = [:]
    for _ in 0..<3 {
      y = [:]
      for col in cols {
        var items: [(id: String, want: Double, i: Int)] = col.enumerated().map { k, id in
          let ps = (preds[id] ?? []).compactMap { y[$0] }
          if !ps.isEmpty { return (id, avg(ps), k) }
          if let prev {
            let ss = (succs[id] ?? []).compactMap { prev[$0] }
            return (id, ss.isEmpty ? prev[id] ?? Double(k) : avg(ss), k)
          }
          return (id, Double(k), k)
        }
        items.sort { $0.want != $1.want ? $0.want < $1.want : $0.i < $1.i }
        for (k, v) in Self.pack(items.map(\.want)).enumerated() { y[items[k].id] = v }
      }
      prev = y
    }
    let low = y.values.min() ?? 0
    var places: [String: Layout.Place] = [:]
    for n in nodes { places[n.id] = Layout.Place(column: layer[n.id] ?? 0, row: (y[n.id] ?? 0) - low) }
    let rows = nodes.isEmpty ? 0 : (y.values.max() ?? 0) - low + 1
    return Layout(places: places, columns: count, rows: rows, headers: [])
  }

  private func syllabusLayout(_ syllabus: Syllabus?) -> Layout {
    let layer = layers()
    var byKey: [Layout.Header: [Node]] = [:]
    for n in nodes {
      let key: Layout.Header
      switch n.kind {
      case .other, .missing: key = .outside
      case .concept: key = n.item.map { .item($0) } ?? .unplaced(n.itemProposed?.nilIfBlank)
      }
      byKey[key, default: []].append(n)
    }
    // 차례: 다른 과목·아직 없음, 목차 차례의 항목, 목차에 없는 항목, 목차 밖
    var order: [Layout.Header] = []
    if byKey[.outside] != nil { order.append(.outside) }
    for entry in syllabus?.flat ?? [] {
      let key = Layout.Header.item(ItemPath.dir(entry.item.code))
      if byKey[key] != nil && !order.contains(key) { order.append(key) }
    }
    var items: [String] = []
    var proposals: [String?] = []
    for key in byKey.keys where !order.contains(key) {
      switch key {
      case .item(let i): items.append(i)
      case .unplaced(let p): proposals.append(p)
      case .outside: break
      }
    }
    order += items.sorted().map { .item($0) }
    order += proposals.sorted { ($0 ?? "") < ($1 ?? "") }.map { .unplaced($0) }
    var places: [String: Layout.Place] = [:]
    var rows = 0
    let rank = Dictionary(nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    for (ci, key) in order.enumerated() {
      let col = (byKey[key] ?? []).sorted { (layer[$0.id] ?? 0, rank[$0.id] ?? 0) < (layer[$1.id] ?? 0, rank[$1.id] ?? 0) }
      for (k, n) in col.enumerated() { places[n.id] = Layout.Place(column: ci, row: Double(k)) }
      rows = max(rows, col.count)
    }
    return Layout(places: places, columns: order.count, rows: Double(rows), headers: order)
  }
}

extension ConceptMap.Layout.Header: Hashable {}

// MARK: - 앞뒤 개념

// 학습 페이지 머리의 작은 지도 (PAGES.md 의 개념 지도 · 학습 페이지 머리, DECISIONS.md 27).
// 한 개념의 바로 앞(선수 개념)과 바로 다음(이 개념을 선수 개념으로 둔 개념)만 본다. 다른 과목 개념도 앞뒤 모두 든다.
extension ConceptMap {
  public struct Neighbor: Sendable, Equatable {
    public let node: Node
    // 그 너머로 더 이어지는 개념 수: 앞쪽 개념이면 제 선수 개념, 뒤쪽 개념이면 제 다음 개념
    public let beyond: Int
  }

  public struct Neighborhood: Sendable, Equatable {
    public let before: [Neighbor]
    public let after: [Neighbor]
  }

  // all: 모든 과목의 개념. 노드의 종류(이 과목, 다른 과목, 아직 없음)는 concept 의 과목에서 본다.
  public static func neighborhood(of concept: Concept, all: [Concept]) -> Neighborhood {
    let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    func refs(_ c: Concept) -> [String] {
      var seen = Set<String>()
      return c.prerequisites.filter { $0 != c.id && seen.insert($0).inserted }
    }
    var next: [String: [String]] = [:]
    for c in all {
      for ref in refs(c) { next[ref, default: []].append(c.id) }
    }
    func node(_ id: String) -> Node {
      guard let c = byID[id] else { return Node(id: id, title: missingTitle(id), kind: .missing, item: nil, itemProposed: nil, curatedOn: nil) }
      return Node(
        id: c.id, title: c.title, kind: c.subject == concept.subject ? .concept : .other(subject: c.subject), item: c.item, itemProposed: c.itemProposed,
        curatedOn: day(c.provenance))
    }
    let before = refs(concept).map { id in Neighbor(node: node(id), beyond: byID[id].map { refs($0).count } ?? 0) }
    // 이 과목의 개념을 먼저, 다른 과목의 개념은 뒤에 둔다
    let after = (next[concept.id] ?? []).map { id in Neighbor(node: node(id), beyond: next[id]?.count ?? 0) }
    return Neighborhood(before: before, after: after.filter { $0.node.kind == .concept } + after.filter { $0.node.kind != .concept })
  }
}
