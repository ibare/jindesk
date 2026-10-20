// 개념과 과목 옮기기. 목차가 생겨 목차 밖 개념을 항목으로 옮길 때, 과목 꼬리표의 이름을 바꾸거나 합칠 때 쓴다 (DATA.md 의 id).
// 옮기면 id 가 바뀐다. 옛 id → 새 id 를 library/moves.jsonl 에 덧붙여, 옛 id 를 가리키는 코멘트와 요구가 새 자리를 찾게 한다.
// 개념 다시 정리는 단위도 옮긴다(kind "unit", DECISIONS.md 47). 자리는 "<개념 id>#<단위 id>"이고, 옮겨 갈 단위가 없으면(뺀 단위) 단위 id 가 비어 있다.
import Foundation

public struct MoveRecord: Sendable, Equatable {
  public let kind: String
  public let from: String
  public let to: String
}

public enum Moves {
  public static func file(_ data: DataFolder) -> URL { data.library.appending(path: "moves.jsonl") }

  static func append(_ data: DataFolder, kind: String, from: String, to: String, why: String) throws {
    let line: JSONValue = .object([
      "v": .number(1), "kind": .string(kind), "from": .string(from), "to": .string(to), "why": .string(why), "at": .string(Clock.isoLocal()),
    ])
    try FileOps.appendLine(JSONText.line(line), to: file(data))
  }

  // 단위 하나를 옮긴 줄. to 의 단위가 nil 이면 그 개념으로만 옮기고 단위는 없다 (뺀 단위)
  static func appendUnit(_ data: DataFolder, from: (concept: String, unit: String), to: (concept: String, unit: String?), why: String) throws {
    try append(data, kind: "unit", from: "\(from.concept)#\(from.unit)", to: "\(to.concept)#\(to.unit ?? "")", why: why)
  }

  public static func all(_ data: DataFolder) -> [MoveRecord] {
    ((try? JSONLines.read(file(data)))?.values ?? []).compactMap { v in
      guard let k = v["kind"]?.stringValue, let f = v["from"]?.stringValue, let t = v["to"]?.stringValue else { return nil }
      return MoveRecord(kind: k, from: f, to: t)
    }
  }

  // 옮기거나 없앤 개념의 옛 id. 새 개념에 다시 쓰지 않는다: 쓰면 그 id 의 줄이 새 개념의 코멘트와 요구를 옛 개념이 간 자리로 끌고 간다
  public static func formerConcepts(_ data: DataFolder) -> Set<String> {
    Set(all(data).filter { $0.kind == "concept" }.map(\.from))
  }

  // 옛 개념 id 를 지금 id 로 (여러 번 옮겼으면 끝까지 따라간다)
  public static func resolve(_ id: String, moves: [MoveRecord]) -> String {
    var current = id
    for _ in 0..<20 {
      guard let m = moves.last(where: { $0.kind == "concept" && $0.from == current }) else { break }
      current = m.to
    }
    return current
  }

  // 옛 자리(개념, 단위)를 지금 자리로. 단위를 옮긴 줄이 있으면 그것을, 없으면 개념을 옮긴 줄을 따라간다.
  // moved: 단위를 옮긴 줄을 하나라도 따라갔다. 그때 단위는 개념 단위(u…)이거나, 옮겨 갈 단위가 없으면 빈 문자열이다.
  public static func resolve(concept: String, unit: String, moves: [MoveRecord]) -> (concept: String, unit: String, moved: Bool) {
    var c = concept
    var u = unit
    var moved = false
    for _ in 0..<40 {
      if !u.isEmpty, let m = moves.last(where: { $0.kind == "unit" && $0.from == "\(c)#\(u)" }), let hash = m.to.lastIndex(of: "#") {
        c = String(m.to[..<hash])
        u = String(m.to[m.to.index(after: hash)...])
        moved = true
        continue
      }
      guard let m = moves.last(where: { $0.kind == "concept" && $0.from == c }) else { break }
      c = m.to
    }
    return (c, u, moved)
  }
}

// 옮겨 간 자리를 지금 페이지의 단위로 (DECISIONS.md 47). 단위를 옮긴 줄은 개념 단위(u…)를 가리키므로,
// 그 개념의 페이지에서 그 원문 단위의 문단을 찾는다. 페이지가 아직 없거나 문단이 없으면 개념 단위 그대로 둔다.
public struct AnchorResolver {
  let data: DataFolder
  let moves: [MoveRecord]
  private var pages: [String: Page?] = [:]

  public init(_ data: DataFolder, moves: [MoveRecord]) {
    self.data = data
    self.moves = moves
  }

  public mutating func resolve(concept: String, unit: String) -> (concept: String, unit: String, moved: Bool) {
    let r = Moves.resolve(concept: concept, unit: unit, moves: moves)
    guard r.moved, !r.unit.isEmpty else { return r }
    if pages[r.concept] == nil { pages[r.concept] = ConceptID(r.concept).flatMap { Page.load(ConceptFolder($0, in: data)) } }
    let para = pages[r.concept]??.units.first { $0.kind == .para && $0.fromUnit == r.unit }
    return (r.concept, para?.id ?? r.unit, true)
  }
}

public enum ConceptMove {
  // 개념 폴더를 옮기고 안의 id 를 바꾼다. 다른 개념의 선수 개념과 연결도 고친다.
  public static func move(_ data: DataFolder, from: ConceptID, to: ConceptID, why: String) throws {
    guard from != to else { return }
    let source = ConceptFolder(from, in: data)
    let target = ConceptFolder(to, in: data)
    guard FileOps.exists(source.concept) else { throw ToolError("옮길 개념이 없습니다: \(from.text)") }
    guard !FileOps.exists(target.url) else { throw ToolError("옮길 자리에 이미 개념이 있습니다: \(to.text)") }
    var concept = try Concept.read(source.concept)
    try FileOps.move(source.url, to: target.url)
    concept.cid = to
    if !to.isUnplaced { concept.itemProposed = nil }
    try concept.write(data)
    if var page = Page.load(target) {
      page.concept = to.text
      try page.write(target)
      if var layers = Layers.load(target) {
        layers.concept = to.text
        try layers.write(target, order: page.units.map(\.id))
      }
    }
    try repoint(data, from: from.text, to: to.text)
    // 레퍼런스는 개념 id 로 묶여 있다. 옮긴 id 로 다시 묶어야 다시 찾지 않는다.
    var refs = References.load(data)
    if let r = refs.concepts.removeValue(forKey: from.text) {
      refs.concepts[to.text] = r
      try refs.write(data)
    }
    try Moves.append(data, kind: "concept", from: from.text, to: to.text, why: why)
  }

  // 옛 개념을 가리키는 다른 개념의 선수 개념과 연결을 새 개념으로 바꾼다. 자기 자신을 가리키게 되면 뺀다 (다시 정리로 합쳤을 때).
  static func repoint(_ data: DataFolder, from: String, to: String) throws {
    for var other in ConceptStore.everything(data) where other.prerequisites.contains(from) || other.links.contains(where: { $0.concept == from }) {
      var prerequisites: [String] = []
      for p in other.prerequisites.map({ $0 == from ? to : $0 }) where p != other.id && !prerequisites.contains(p) { prerequisites.append(p) }
      other.prerequisites = prerequisites
      other.links = other.links.map { $0.concept == from ? ConceptLink(concept: to, note: $0.note) : $0 }
      try other.write(data)
    }
  }
}

// 과목 꼬리표의 이름을 바꾸거나 다른 과목에 합친다. 과목 id 가 바뀌면 엔트리, 개념, 목차를 새 과목으로 옮긴다.
public enum SubjectRename {
  public struct Result: Sendable, Equatable {
    public var sources = 0
    public var entries = 0
    public var concepts = 0
  }

  public static func run(_ data: DataFolder, from subject: String, toName: String) throws -> Result {
    let name = toName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw RequestError("새 과목 이름이 비었습니다") }
    let library = SourceLibrary.load(data)
    let canonical = LabelMatch.canonical(name, among: library.usedValues(SourceLabels.subject))
    let target = SubjectID.make(canonical)
    var result = Result()
    // 꼬리표
    for s in library.sources where s.labels.labels.subjectID == subject {
      var file = s.labels
      file.labels[SourceLabels.subject] = canonical
      try file.write(to: s.folder)
      result.sources += 1
    }
    guard target != subject else { return result }
    // 엔트리: 새 과목의 같은 자리에 옮기고 id 를 바꾼다. 겹치면 -2, -3 … 을 붙인다.
    var entryMap: [String: String] = [:]
    for e in EntryStore.all(data, subject: subject) {
      let rest = e.id.split(separator: "/").dropFirst().joined(separator: "/")
      var newID = "\(target)/\(rest)"
      var n = 2
      while FileOps.exists(data.entryFile(newID)) || entryMap.values.contains(newID) {
        newID = "\(target)/\(rest)-\(n)"
        n += 1
      }
      let moved = Entry(
        id: newID, subject: target, item: e.item, itemProposed: e.itemProposed, title: e.title, sources: e.sources, claims: e.claims,
        symbols: e.symbols, examples: e.examples, misconceptions: e.misconceptions, body: e.body, recorded: e.recorded, provenance: e.provenance,
        held: e.held)
      try FileOps.writeNew(moved.markdown, to: data.entryFile(newID))
      FileOps.remove(data.entryFile(e.id))
      try Moves.append(data, kind: "entry", from: e.id, to: newID, why: "과목 \(subject) → \(target)")
      entryMap[e.id] = newID
      result.entries += 1
    }
    FileOps.remove(data.entriesDir(subject))
    // 개념: 같은 slug 가 있거나 옮기거나 없앤 개념의 옛 id 면 뒤에 수를 붙인다
    let former = Moves.formerConcepts(data)
    for c in ConceptStore.all(data, subject: subject) {
      var slug = c.cid.slug
      var n = 2
      func taken(_ s: String) -> Bool {
        let id = ConceptID(subject: target, item: c.cid.item, slug: s)
        return FileOps.exists(data.conceptDir(id)) || former.contains(id.text)
      }
      while taken(slug) {
        slug = "\(c.cid.slug)-\(n)"
        n += 1
      }
      let to = ConceptID(subject: target, item: c.cid.item, slug: slug)
      try ConceptMove.move(data, from: c.cid, to: to, why: "과목 \(subject) → \(target)")
      var moved = try Concept.read(ConceptFolder(to, in: data).concept)
      moved.occurrences = moved.occurrences.map { Occurrence(entry: entryMap[$0.entry] ?? $0.entry, source: $0.source, pages: $0.pages) }
      try moved.write(data)
      result.concepts += 1
    }
    FileOps.remove(data.conceptsRoot.appending(path: subject))
    FileOps.remove(data.unplacedRoot.appending(path: subject))
    // 목차: 새 과목에 목차가 없을 때만 옮긴다
    if FileOps.exists(data.syllabusFile(subject)) && !FileOps.exists(data.syllabusFile(target)) {
      var v = try YAML.read(data.syllabusFile(subject)).map ?? YAMLMap([])
      v["subject"] = .string(target)
      try FileOps.writeAtomic(YAML.stringify(v), to: data.syllabusFile(target))
      FileOps.remove(data.syllabusFile(subject))
    }
    // 용어 어휘의 과목
    var glossary = Glossary.load(data)
    if glossary.terms.contains(where: { $0.subjects.contains(subject) }) {
      for i in glossary.terms.indices where glossary.terms[i].subjects.contains(subject) {
        glossary.terms[i].subjects = glossary.terms[i].subjects.map { $0 == subject ? target : $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
      }
      try glossary.write(data)
    }
    try Moves.append(data, kind: "subject", from: subject, to: target, why: "과목 이름 \(canonical)")
    return result
  }
}
