// 개념과 과목 옮기기. 목차가 생겨 목차 밖 개념을 항목으로 옮길 때, 과목 꼬리표의 이름을 바꾸거나 합칠 때 쓴다 (DATA.md 의 id).
// 옮기면 id 가 바뀐다. 옛 id → 새 id 를 library/moves.jsonl 에 덧붙여, 옛 id 를 가리키는 코멘트와 요구가 새 자리를 찾게 한다.
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

  public static func all(_ data: DataFolder) -> [MoveRecord] {
    ((try? JSONLines.read(file(data)))?.values ?? []).compactMap { v in
      guard let k = v["kind"]?.stringValue, let f = v["from"]?.stringValue, let t = v["to"]?.stringValue else { return nil }
      return MoveRecord(kind: k, from: f, to: t)
    }
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
    // 이 개념을 가리키는 다른 개념의 선수 개념과 연결
    for var other in ConceptStore.everything(data) where other.prerequisites.contains(from.text) || other.links.contains(where: { $0.concept == from.text }) {
      other.prerequisites = other.prerequisites.map { $0 == from.text ? to.text : $0 }
      other.links = other.links.map { $0.concept == from.text ? ConceptLink(concept: to.text, note: $0.note) : $0 }
      try other.write(data)
    }
    // 레퍼런스는 개념 id 로 묶여 있다. 옮긴 id 로 다시 묶어야 다시 찾지 않는다.
    var refs = References.load(data)
    if let r = refs.concepts.removeValue(forKey: from.text) {
      refs.concepts[to.text] = r
      try refs.write(data)
    }
    try Moves.append(data, kind: "concept", from: from.text, to: to.text, why: why)
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
        id: newID, subject: target, item: e.item, itemProposed: e.itemProposed, title: e.title, source: e.source, pages: e.pages, claims: e.claims,
        symbols: e.symbols, examples: e.examples, misconceptions: e.misconceptions, body: e.body, recorded: e.recorded, provenance: e.provenance)
      try FileOps.writeNew(moved.markdown, to: data.entryFile(newID))
      FileOps.remove(data.entryFile(e.id))
      try Moves.append(data, kind: "entry", from: e.id, to: newID, why: "과목 \(subject) → \(target)")
      entryMap[e.id] = newID
      result.entries += 1
    }
    FileOps.remove(data.entriesDir(subject))
    // 개념: 같은 slug 가 있으면 뒤에 수를 붙인다
    for c in ConceptStore.all(data, subject: subject) {
      var slug = c.cid.slug
      var n = 2
      while FileOps.exists(data.conceptDir(ConceptID(subject: target, item: c.cid.item, slug: slug))) {
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
