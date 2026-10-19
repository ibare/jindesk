// 정리된 개념 (concept.yaml). 개념 정리가 엔트리를 묶어 원문을 단위(units)로 쓴다. 학습 페이지의 기준이다.
// 단위 id(u1, u2 …)와 해시는 러너가 붙인다. 한 번 쓴 단위 id 는 다시 쓰지 않는다 (next_id).
import Foundation

public struct UnitClaim: Sendable, Equatable {
  public let id: String
  public let text: String
  public let src: [String]

  public init(id: String, text: String, src: [String]) {
    self.id = id
    self.text = text
    self.src = src
  }

  var yaml: YAMLValue { .map(["id": .string(id), "text": .string(text), "src": .array(src.map(YAMLValue.string))]) }
  var json: JSONValue { .object(["id": .string(id), "text": .string(text), "src": .array(src.map(JSONValue.string))]) }

  init?(yaml: YAMLValue) {
    guard let id = yaml["id"]?.string, let text = yaml["text"]?.string else { return nil }
    self.init(id: id, text: text, src: yaml["src"]?.strings ?? [])
  }
}

// 주장 id ("u2.c1": 단위 id.주장 id). 한 장 요약과 공식이 고른 주장을 가리킨다 (DECISIONS.md 34).
extension Concept {
  public func claim(_ ref: String) -> UnitClaim? {
    let parts = ref.split(separator: ".", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    return units.first { $0.id == parts[0] }?.claims.first { $0.id == parts[1] }
  }

  // 이 개념의 모든 주장 id 와 글 (단위 차례)
  public var claimRefs: [(ref: String, claim: UnitClaim)] {
    units.flatMap { u in u.claims.map { ("\(u.id).\($0.id)", $0) } }
  }
}

public struct ConceptUnit: Sendable, Equatable {
  public let id: String
  public let hash: String
  public let text: String
  public let conditions: [String]
  public let claims: [UnitClaim]

  public init(id: String, text: String, conditions: [String], claims: [UnitClaim]) {
    self.id = id
    self.text = text
    self.conditions = conditions
    self.claims = claims
    hash = Self.hash(text: text, conditions: conditions, claims: claims)
  }

  // 원문 단위의 해시: text, conditions, claims(출처 포함)
  public static func hash(text: String, conditions: [String], claims: [UnitClaim]) -> String {
    MeaningHash.of(.object(["text": .string(text), "conditions": .array(conditions.map(JSONValue.string)), "claims": .array(claims.map(\.json))]))
  }

  public var refs: Set<String> { Set(claims.flatMap(\.src)) }

  var yaml: YAMLValue {
    .map([
      "id": .string(id), "hash": .string(hash), "text": .string(text),
      "conditions": .array(conditions.map(YAMLValue.string)), "claims": .array(claims.map(\.yaml)),
    ])
  }

  init?(yaml: YAMLValue) {
    guard let id = yaml["id"]?.string, let text = yaml["text"]?.string else { return nil }
    self.init(
      id: id, text: text, conditions: yaml["conditions"]?.strings ?? [], claims: (yaml["claims"]?.array ?? []).compactMap(UnitClaim.init(yaml:)))
  }
}

public struct Occurrence: Sendable, Equatable {
  public let entry: String
  public let source: String
  public let pages: [Int]

  public init(entry: String, source: String, pages: [Int]) {
    self.entry = entry
    self.source = source
    self.pages = pages
  }

  var yaml: YAMLValue { .map(["entry": .string(entry), "source": .string(source), "pages": .array(pages.map(YAMLValue.int))]) }

  init?(yaml: YAMLValue) {
    guard let e = yaml["entry"]?.string, let s = yaml["source"]?.string else { return nil }
    self.init(entry: e, source: s, pages: (yaml["pages"]?.array ?? []).compactMap(\.int))
  }

  // 목록에 보일 쪽 ("12–24쪽", "7쪽"). source 를 주면 그 자료의 쪽만, 주지 않았는데 자료가 여럿이면 "자료 2개"
  public static func pagesLabel(_ occurrences: [Occurrence], source: String? = nil) -> String? {
    let mine = occurrences.filter { source == nil || $0.source == source }
    if source == nil, Set(mine.map(\.source)).count > 1 { return "자료 \(Set(mine.map(\.source)).count)개" }
    let pages = Set(mine.flatMap(\.pages)).sorted()
    guard let first = pages.first, let last = pages.last else { return nil }
    return first == last ? "\(first)쪽" : "\(first)–\(last)쪽"
  }
}

// 목록에 보일 이름: 콜론 앞(머리)과 뒤(나머지). "Measures of spread: range and IQR" → "Measures of spread", "range and IQR"
public struct TitleParts: Sendable, Equatable {
  public let head: String
  public let tail: String?

  public init(_ title: String) {
    let t = title.trimmingCharacters(in: .whitespaces)
    if let r = t.range(of: #"\s*[:：]\s*"#, options: .regularExpression), r.lowerBound > t.startIndex, r.upperBound < t.endIndex {
      head = String(t[..<r.lowerBound])
      tail = String(t[r.upperBound...])
    } else {
      head = t
      tail = nil
    }
  }

  init(head: String, tail: String?) {
    self.head = head
    self.tail = tail
  }
}

// 과목 사이 연결: 다른 과목의 개념과 그 관계 한 문장 (영어)
public struct ConceptLink: Sendable, Equatable {
  public let concept: String
  public let note: String

  public init(concept: String, note: String) {
    self.concept = concept
    self.note = note
  }

  var yaml: YAMLValue { .map(["concept": .string(concept), "note": .string(note)]) }

  init?(yaml: YAMLValue) {
    guard let c = yaml["concept"]?.string, let n = yaml["note"]?.string else { return nil }
    self.init(concept: c, note: n)
  }
}

public struct Concept: Sendable, Equatable, Identifiable {
  public var cid: ConceptID
  public var title: String
  // 목차 밖 개념의 단원·주제 제안 (목록에서 묶어 보인다)
  public var itemProposed: String?
  public var level: String?
  public var occurrences: [Occurrence]
  public var symbols: [SymbolDef]
  // 먼저 알아야 할 개념의 id. 아직 없는 개념은 "missing:<제목>"
  public var prerequisites: [String] = []
  public var links: [ConceptLink] = []
  public var nextID: Int
  public var units: [ConceptUnit]
  public var provenance: YAMLMap

  public var id: String { cid.text }
  public var subject: String { cid.subject }
  // 목차 항목 코드 (목차 밖이면 nil)
  public var item: String? { cid.isUnplaced ? nil : cid.item }

  public init(
    cid: ConceptID, title: String, itemProposed: String?, level: String? = nil, occurrences: [Occurrence], symbols: [SymbolDef], nextID: Int,
    units: [ConceptUnit], provenance: YAMLMap
  ) {
    self.cid = cid
    self.title = title
    self.itemProposed = itemProposed
    self.level = level
    self.occurrences = occurrences
    self.symbols = symbols
    self.nextID = nextID
    self.units = units
    self.provenance = provenance
  }

  public var sources: [String] {
    var out: [String] = []
    for o in occurrences where !out.contains(o.source) { out.append(o.source) }
    return out
  }

  public var refs: Set<String> { Set(units.flatMap(\.refs)) }

  public var yaml: YAMLMap {
    [
      "kind": "concept",
      "v": 1,
      "id": .string(id),
      "title": .string(title),
      "subject": .string(subject),
      "item": item.map(YAMLValue.string) ?? .null,
      "item_proposed": itemProposed.map(YAMLValue.string) ?? .null,
      "level": level.map(YAMLValue.string) ?? .null,
      "occurrences": .array(occurrences.map(\.yaml)),
      "symbols": .array(symbols.map(\.yaml)),
      "prerequisites": .array(prerequisites.map(YAMLValue.string)),
      "links": .array(links.map(\.yaml)),
      "next_id": .int(nextID),
      "units": .array(units.map(\.yaml)),
      "provenance": .map(provenance),
    ]
  }

  public static func read(_ url: URL) throws -> Concept {
    let v = try YAML.read(url)
    guard v["kind"]?.string == "concept", let idText = v["id"]?.string, let cid = ConceptID(idText), let title = v["title"]?.string else {
      throw ToolError("\(url.path) 의 모양이 맞지 않습니다")
    }
    var c = Concept(
      cid: cid, title: title, itemProposed: v["item_proposed"]?.string, level: v["level"]?.string,
      occurrences: (v["occurrences"]?.array ?? []).compactMap(Occurrence.init(yaml:)),
      symbols: (v["symbols"]?.array ?? []).compactMap(SymbolDef.init(yaml:)), nextID: v["next_id"]?.int ?? 1,
      units: (v["units"]?.array ?? []).compactMap(ConceptUnit.init(yaml:)), provenance: v["provenance"]?.map ?? YAMLMap([]))
    c.prerequisites = v["prerequisites"]?.strings ?? []
    c.links = (v["links"]?.array ?? []).compactMap(ConceptLink.init(yaml:))
    return c
  }

  public func write(_ data: DataFolder) throws {
    try FileOps.writeAtomic(YAML.stringify(yaml), to: ConceptFolder(cid, in: data).concept)
  }
}

public enum ConceptStore {
  // 과목의 개념 (목차 안과 목차 밖). id 순서.
  public static func all(_ data: DataFolder, subject: String) -> [Concept] {
    var urls: [URL] = []
    let placed = data.conceptsRoot.appending(path: subject)
    for item in FileOps.list(placed) where !item.hasPrefix(".") {
      for slug in FileOps.list(placed.appending(path: item)) where !slug.hasPrefix(".") {
        urls.append(placed.appending(path: item).appending(path: slug).appending(path: "concept.yaml"))
      }
    }
    let unplaced = data.unplacedRoot.appending(path: subject)
    for slug in FileOps.list(unplaced) where !slug.hasPrefix(".") {
      urls.append(unplaced.appending(path: slug).appending(path: "concept.yaml"))
    }
    return urls.compactMap { try? Concept.read($0) }.sorted { $0.id < $1.id }
  }

  public static func load(_ data: DataFolder, id: ConceptID) -> Concept? {
    try? Concept.read(ConceptFolder(id, in: data).concept)
  }

  // 모든 과목의 개념
  public static func everything(_ data: DataFolder) -> [Concept] {
    subjects(data).flatMap { all(data, subject: $0) }
  }

  // 개념이 있는 과목 id
  public static func subjects(_ data: DataFolder) -> [String] {
    let names = FileOps.list(data.conceptsRoot) + FileOps.list(data.unplacedRoot)
    return Array(Set(names.filter { !$0.hasPrefix(".") })).sorted()
  }

  // 이미 개념에 들어간 엔트리 id
  public static func curatedEntries(_ concepts: [Concept]) -> Set<String> {
    Set(concepts.flatMap { $0.occurrences.map(\.entry) })
  }

  // concept.yaml 파일 해시 (반영 직전에 기준이 그대로인지 볼 때)
  public static func fileHash(_ data: DataFolder, id: ConceptID) -> String? {
    (try? Data(contentsOf: ConceptFolder(id, in: data).concept)).map(Hash.short)
  }
}
