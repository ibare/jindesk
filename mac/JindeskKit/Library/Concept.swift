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
}

public struct Concept: Sendable, Equatable, Identifiable {
  public let cid: ConceptID
  public var title: String
  // 목차 밖 개념의 단원·주제 제안 (목록에서 묶어 보인다)
  public var itemProposed: String?
  public var level: String?
  public var occurrences: [Occurrence]
  public var symbols: [SymbolDef]
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
    return Concept(
      cid: cid, title: title, itemProposed: v["item_proposed"]?.string, level: v["level"]?.string,
      occurrences: (v["occurrences"]?.array ?? []).compactMap(Occurrence.init(yaml:)),
      symbols: (v["symbols"]?.array ?? []).compactMap(SymbolDef.init(yaml:)), nextID: v["next_id"]?.int ?? 1,
      units: (v["units"]?.array ?? []).compactMap(ConceptUnit.init(yaml:)), provenance: v["provenance"]?.map ?? YAMLMap([]))
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
