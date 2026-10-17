// 학습 페이지 (page.yaml)와 곁 층 (layers.yaml). PAGES.md.
// 페이지 단위는 원문 단위에서 온다(from: u3@<해시>). 문단의 글은 원문 단위의 글을 그대로 쓴다.
// 단위 id 는 페이지 안에서 유일하고 다시 쓰지 않는다 (next_id). 내용이 바뀌면 판(rev)을 올리고 이전 판은 history.jsonl 에 덧붙인다.
import Foundation

public enum PageUnitKind: String, Sendable, CaseIterable {
  case para, note, block

  // 단위 id 앞 글자
  var prefix: String {
    switch self {
    case .para: "p"
    case .note: "n"
    case .block: "b"
    }
  }
}

public enum NoteKind: String, Sendable, CaseIterable {
  case misconception
  case keyIdea = "key-idea"
  case commandTerm = "command-term"
}

public struct PageUnit: Sendable, Equatable {
  public let id: String
  public var rev: Int
  public let kind: PageUnitKind
  // <원문 단위 id>@<그 단위의 해시>
  public var from: String
  // source(자료에 있음) 또는 added(보충)
  public var prov: String
  public var text: String?
  public var note: NoteKind?
  // 블록 명세 (type, v, …): math(TeX), figure(그림 코드 파일과 해시)
  public var block: YAMLMap?
  // 그림 블록 아래의 설명 (영어). 번역 대상이다
  public var caption: String?
  public var claims: [UnitClaim]
  public var conditions: [String]

  public init(
    id: String, rev: Int, kind: PageUnitKind, from: String, prov: String, text: String? = nil, note: NoteKind? = nil, block: YAMLMap? = nil,
    caption: String? = nil, claims: [UnitClaim] = [], conditions: [String] = []
  ) {
    self.id = id
    self.rev = rev
    self.kind = kind
    self.from = from
    self.prov = prov
    self.text = text
    self.note = note
    self.block = block
    self.caption = caption
    self.claims = claims
    self.conditions = conditions
  }

  public var fromUnit: String { String(from.split(separator: "@").first ?? "") }
  public var fromHash: String { from.split(separator: "@").dropFirst().first.map(String.init) ?? "" }
  public var ref: String { "\(id)@r\(rev)" }

  // 옮길 영어 글: 문단과 강조 상자의 글, 그림 블록의 설명
  public var english: String? { (text ?? caption)?.nilIfBlank }

  public var isFigure: Bool { block?["type"]?.string == "figure" }

  // 페이지 단위의 해시: kind, text 또는 블록 명세(그림 블록은 코드 경로 대신 코드 해시), claims
  public var hash: String {
    var o: [String: JSONValue] = ["kind": .string(kind.rawValue), "claims": .array(claims.map(\.json))]
    if let text { o["text"] = .string(text) }
    if let note { o["note"] = .string(note.rawValue) }
    if var block {
      block["code"] = nil
      o["block"] = YAMLValue.map(block).json
    }
    if let caption { o["caption"] = .string(caption) }
    return MeaningHash.of(.object(o))
  }

  // 판을 가리지 않고 내용이 같은가 (새 판을 만들지 볼 때)
  func sameContent(_ other: PageUnit) -> Bool {
    hash == other.hash && from == other.from && prov == other.prov && conditions == other.conditions
  }

  var yaml: YAMLMap {
    var m: YAMLMap = ["id": .string(id), "rev": .int(rev), "kind": .string(kind.rawValue), "from": .string(from), "prov": .string(prov)]
    if let note { m["note"] = .string(note.rawValue) }
    if let text { m["text"] = .string(text) }
    if let block { m["block"] = .map(block) }
    if let caption { m["caption"] = .string(caption) }
    if !conditions.isEmpty { m["conditions"] = .array(conditions.map(YAMLValue.string)) }
    if !claims.isEmpty { m["claims"] = .array(claims.map(\.yaml)) }
    return m
  }

  init?(yaml: YAMLValue) {
    guard let id = yaml["id"]?.string, let kind = yaml["kind"]?.string.flatMap(PageUnitKind.init(rawValue:)), let from = yaml["from"]?.string else {
      return nil
    }
    self.init(
      id: id, rev: yaml["rev"]?.int ?? 1, kind: kind, from: from, prov: yaml["prov"]?.string ?? "source", text: yaml["text"]?.string,
      note: yaml["note"]?.string.flatMap(NoteKind.init(rawValue:)), block: yaml["block"]?.map, caption: yaml["caption"]?.string,
      claims: (yaml["claims"]?.array ?? []).compactMap(UnitClaim.init(yaml:)), conditions: yaml["conditions"]?.strings ?? [])
  }
}

public struct Page: Sendable, Equatable {
  public var concept: String
  public var titleKo: String?
  public var nextID: Int
  public var units: [PageUnit]
  public var provenance: YAMLMap

  public init(concept: String, titleKo: String?, nextID: Int, units: [PageUnit], provenance: YAMLMap) {
    self.concept = concept
    self.titleKo = titleKo
    self.nextID = nextID
    self.units = units
    self.provenance = provenance
  }

  public var yaml: YAMLMap {
    [
      "kind": "page",
      "v": 1,
      "concept": .string(concept),
      "title_ko": titleKo.map(YAMLValue.string) ?? .null,
      "next_id": .int(nextID),
      "units": .array(units.map { .map($0.yaml.with(style: .block)) }),
      "provenance": .map(provenance),
    ]
  }

  public static func read(_ url: URL) throws -> Page {
    let v = try YAML.read(url)
    guard v["kind"]?.string == "page", let concept = v["concept"]?.string else { throw ToolError("\(url.path) 의 모양이 맞지 않습니다") }
    return Page(
      concept: concept, titleKo: v["title_ko"]?.string, nextID: v["next_id"]?.int ?? 1,
      units: (v["units"]?.array ?? []).compactMap(PageUnit.init(yaml:)), provenance: v["provenance"]?.map ?? YAMLMap([]))
  }

  public static func load(_ folder: ConceptFolder) -> Page? { try? read(folder.page) }

  public func write(_ folder: ConceptFolder) throws {
    try FileOps.writeAtomic(YAML.stringify(yaml), to: folder.page)
  }

  // 지침 판 (provenance.instructions.version)
  public var instructionsVersion: String? { provenance["instructions"]?["version"]?.string }
}

// 곁 층 하나 (지금은 한국어 ko 만 쓴다)
public struct LayerText: Sendable, Equatable {
  // 어느 단위의 몇 판에서 만들었는지: p1@r2
  public let from: String
  // 만들 때 그 단위의 해시
  public let unitHash: String
  public let text: String
  public let prov: YAMLMap

  public init(from: String, unitHash: String, text: String, prov: YAMLMap) {
    self.from = from
    self.unitHash = unitHash
    self.text = text
    self.prov = prov
  }

  public func isCurrent(for unit: PageUnit) -> Bool { from == unit.ref && unitHash == unit.hash }

  var yaml: YAMLMap {
    ["from": .string(from), "unit_hash": .string(unitHash), "text": .string(text), "prov": .map(prov)]
  }

  init?(yaml: YAMLValue) {
    guard let from = yaml["from"]?.string, let text = yaml["text"]?.string else { return nil }
    self.init(from: from, unitHash: yaml["unit_hash"]?.string ?? "", text: text, prov: yaml["prov"]?.map ?? YAMLMap([]))
  }
}

public struct Layers: Sendable, Equatable {
  public var concept: String
  // 단위 id → 한국어
  public var ko: [String: LayerText]

  public init(concept: String, ko: [String: LayerText] = [:]) {
    self.concept = concept
    self.ko = ko
  }

  // 페이지 단위 차례대로 쓴다. 페이지에 없는 단위의 층은 끝에 이름 차례로 둔다.
  public func yaml(order: [String]) -> YAMLMap {
    var units = YAMLMap([])
    let ids = order.filter { ko[$0] != nil } + ko.keys.filter { !order.contains($0) }.sorted()
    for id in ids { units[id] = .map(YAMLMap([("ko", .map(ko[id]!.yaml.with(style: .block)))], style: .block)) }
    return ["kind": "layers", "v": 1, "concept": .string(concept), "units": .map(units.with(style: .block))]
  }

  public static func read(_ url: URL) throws -> Layers {
    let v = try YAML.read(url)
    guard v["kind"]?.string == "layers", let concept = v["concept"]?.string else { throw ToolError("\(url.path) 의 모양이 맞지 않습니다") }
    var ko: [String: LayerText] = [:]
    for entry in v["units"]?.map?.entries ?? [] {
      if let layer = entry.value["ko"].flatMap(LayerText.init(yaml:)) { ko[entry.key] = layer }
    }
    return Layers(concept: concept, ko: ko)
  }

  public static func load(_ folder: ConceptFolder) -> Layers? { try? read(folder.layers) }

  public func write(_ folder: ConceptFolder, order: [String]) throws {
    try FileOps.writeAtomic(YAML.stringify(yaml(order: order)), to: folder.layers)
  }
}

extension YAMLValue {
  // 순서를 지키는 값을 JSON 값으로 (해시용)
  var json: JSONValue {
    switch self {
    case .null: .null
    case .bool(let b): .bool(b)
    case .int(let n): .number(Double(n))
    case .double(let d): .number(d)
    case .string(let s): .string(s)
    case .array(let a): .array(a.map(\.json))
    case .map(let m): .object(Dictionary(m.entries.map { ($0.key, $0.value.json) }, uniquingKeysWith: { a, _ in a }))
    }
  }
}
