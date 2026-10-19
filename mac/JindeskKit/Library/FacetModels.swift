// 관점 (facets.yaml, JOBS.md 의 관점 붙이기). 관점은 고정이고, 값은 어휘로 맞춘다.
// 강의 계획 항목과 수준은 러너가 채운다. 명령어, MYP 핵심 개념, 글로벌 맥락, TOK 지식 영역은 고정 목록이고, 관련 개념과 NOS 는 과목별 어휘다.
import Foundation

public enum FacetVocabulary {
  public static let commandTerms = [
    "Analyse", "Annotate", "Apply", "Calculate", "Classify", "Comment", "Compare", "Compare and contrast", "Construct", "Contrast", "Deduce", "Define",
    "Demonstrate", "Derive", "Describe", "Design", "Determine", "Discuss", "Distinguish", "Draw", "Estimate", "Evaluate", "Examine", "Explain", "Explore",
    "Formulate", "Hence", "Hence or otherwise", "Identify", "Integrate", "Interpret", "Investigate", "Justify", "Label", "List", "Measure", "Outline",
    "Plot", "Predict", "Prove", "Show", "Show that", "Sketch", "Solve", "State", "Suggest", "Summarize", "To what extent", "Verify", "Write down",
  ]
  public static let keyConcepts = [
    "Aesthetics", "Change", "Communication", "Communities", "Connections", "Creativity", "Culture", "Development", "Form", "Global interactions",
    "Identity", "Logic", "Perspective", "Relationships", "Systems", "Time, place and space",
  ]
  public static let globalContexts = [
    "Identities and relationships", "Orientation in space and time", "Personal and cultural expression", "Scientific and technical innovation",
    "Globalization and sustainability", "Fairness and development",
  ]
  public static let tok = ["Mathematics", "Natural sciences", "Human sciences", "History", "The arts", "Knowledge and the knower", "Knowledge and technology", "Knowledge and language"]

  // 고정 목록의 값으로 맞춘다 (대소문자, 띄어쓰기를 가리지 않는다). 없으면 nil.
  public static func canonical(_ value: String, in list: [String]) -> String? {
    let k = LabelMatch.key(value)
    return list.first { LabelMatch.key($0) == k }
  }
}

public struct ConceptFacets: Sendable, Equatable {
  public var concept: String
  // 이 관점을 붙일 때의 concept.yaml 해시 (바뀌면 다시 붙인다)
  public var from: String
  public var item: String?
  public var level: String?
  public var commandTerms: [String]
  public var keyConcepts: [String]
  public var relatedConcepts: [String]
  public var globalContexts: [String]
  public var nos: [String]
  public var tok: [String]
  // 한 장 요약과 공식으로 고른 주장 (단위 id.주장 id, DECISIONS.md 34). nil 이면 아직 고르지 않았다 (스키마 1 의 관점)
  public var summary: [String]?
  public var formulas: [String]?
  public var provenance: YAMLMap

  public init(
    concept: String, from: String, item: String?, level: String?, commandTerms: [String], keyConcepts: [String], relatedConcepts: [String],
    globalContexts: [String], nos: [String], tok: [String], summary: [String]? = nil, formulas: [String]? = nil, provenance: YAMLMap
  ) {
    self.concept = concept
    self.from = from
    self.item = item
    self.level = level
    self.commandTerms = commandTerms
    self.keyConcepts = keyConcepts
    self.relatedConcepts = relatedConcepts
    self.globalContexts = globalContexts
    self.nos = nos
    self.tok = tok
    self.summary = summary
    self.formulas = formulas
    self.provenance = provenance
  }

  public var yaml: YAMLMap {
    var m: YAMLMap = [
      "kind": "facets", "v": 2, "concept": .string(concept), "from": .string(from), "item": item.map(YAMLValue.string) ?? .null,
      "level": level.map(YAMLValue.string) ?? .null, "command_terms": .array(commandTerms.map(YAMLValue.string)),
      "key_concepts": .array(keyConcepts.map(YAMLValue.string)), "related_concepts": .array(relatedConcepts.map(YAMLValue.string)),
      "global_contexts": .array(globalContexts.map(YAMLValue.string)), "nos": .array(nos.map(YAMLValue.string)), "tok": .array(tok.map(YAMLValue.string)),
    ]
    if let summary { m["summary"] = .array(summary.map(YAMLValue.string)) }
    if let formulas { m["formulas"] = .array(formulas.map(YAMLValue.string)) }
    m["provenance"] = .map(provenance)
    return m
  }

  public static func file(_ folder: ConceptFolder) -> URL { folder.url.appending(path: "facets.yaml") }

  public static func load(_ folder: ConceptFolder) -> ConceptFacets? {
    guard let v = try? YAML.read(file(folder)), v["kind"]?.string == "facets", let c = v["concept"]?.string else { return nil }
    return ConceptFacets(
      concept: c, from: v["from"]?.string ?? "", item: v["item"]?.string, level: v["level"]?.string, commandTerms: v["command_terms"]?.strings ?? [],
      keyConcepts: v["key_concepts"]?.strings ?? [], relatedConcepts: v["related_concepts"]?.strings ?? [],
      globalContexts: v["global_contexts"]?.strings ?? [], nos: v["nos"]?.strings ?? [], tok: v["tok"]?.strings ?? [], summary: v["summary"]?.strings,
      formulas: v["formulas"]?.strings, provenance: v["provenance"]?.map ?? YAMLMap([]))
  }

  public func write(_ folder: ConceptFolder) throws {
    try FileOps.writeAtomic(YAML.stringify(yaml), to: Self.file(folder))
  }
}

// 과목별 열린 어휘 (library/facets.yaml): 관련 개념과 NOS 값. 새 값은 있는 값과 표기만 다르면 그 값으로 맞춘다.
public struct FacetVocab: Sendable, Equatable {
  public var related: [String: [String]]
  public var nos: [String: [String]]

  public static func load(_ data: DataFolder) -> FacetVocab {
    guard let v = try? YAML.read(data.library.appending(path: "facets.yaml")), v["kind"]?.string == "facet-vocab" else { return FacetVocab(related: [:], nos: [:]) }
    var related: [String: [String]] = [:]
    var nos: [String: [String]] = [:]
    for e in v["related_concepts"]?.map?.entries ?? [] { related[e.key] = e.value.strings }
    for e in v["nos"]?.map?.entries ?? [] { nos[e.key] = e.value.strings }
    return FacetVocab(related: related, nos: nos)
  }

  public func write(_ data: DataFolder) throws {
    func map(_ d: [String: [String]]) -> YAMLValue { .map(YAMLMap(d.keys.sorted().map { ($0, .array(d[$0]!.map(YAMLValue.string))) }, style: .block)) }
    let m: YAMLMap = ["kind": "facet-vocab", "v": 1, "related_concepts": map(related), "nos": map(nos)]
    try FileOps.writeAtomic(YAML.stringify(m), to: data.library.appending(path: "facets.yaml"))
  }

  // 값을 어휘에 맞추고, 없던 값은 더한다
  public mutating func merge(_ values: [String], subject: String, nos isNOS: Bool) -> [String] {
    var list = (isNOS ? nos : related)[subject] ?? []
    let out = values.map { v -> String in
      if let hit = list.first(where: { LabelMatch.key($0) == LabelMatch.key(v) }) { return hit }
      list.append(v)
      return v
    }
    if isNOS { nos[subject] = list } else { related[subject] = list }
    return out
  }
}

// 레퍼런스 (library/references.yaml): 개념마다 대표 공개 자료 셋까지. 찾았는데 없으면 빈 목록으로 두고 다시 찾지 않는다.
public struct Reference: Sendable, Equatable {
  public let url: String
  public let title: String
  public let kind: String
  public let why: String
}

public struct References: Sendable, Equatable {
  public var concepts: [String: (job: String, items: [Reference])]

  public static func == (a: References, b: References) -> Bool { a.concepts.keys.sorted() == b.concepts.keys.sorted() }

  public static func file(_ data: DataFolder) -> URL { data.library.appending(path: "references.yaml") }

  public static func load(_ data: DataFolder) -> References {
    guard let v = try? YAML.read(file(data)), v["kind"]?.string == "references" else { return References(concepts: [:]) }
    var out: [String: (job: String, items: [Reference])] = [:]
    // 옮긴 개념은 지금 id 로 읽는다 (moves.jsonl)
    let moves = Moves.all(data)
    for e in v["concepts"]?.map?.entries ?? [] {
      let items = (e.value["items"]?.array ?? []).compactMap { i -> Reference? in
        guard let url = i["url"]?.string else { return nil }
        return Reference(url: url, title: i["title"]?.string ?? url, kind: i["kind"]?.string ?? "", why: i["why"]?.string ?? "")
      }
      out[Moves.resolve(e.key, moves: moves)] = (e.value["searched"]?.string ?? "", items)
    }
    return References(concepts: out)
  }

  public func write(_ data: DataFolder) throws {
    var concepts = YAMLMap([], style: .block)
    for id in self.concepts.keys.sorted() {
      let c = self.concepts[id]!
      concepts[id] = .map(
        YAMLMap(
          [
            ("searched", .string(c.job)),
            (
              "items",
              .array(c.items.map { .map(["url": .string($0.url), "title": .string($0.title), "kind": .string($0.kind), "why": .string($0.why)]) })
            ),
          ], style: .block))
    }
    let m: YAMLMap = ["kind": "references", "v": 1, "concepts": .map(concepts)]
    try FileOps.writeAtomic(YAML.stringify(m), to: Self.file(data))
  }
}
