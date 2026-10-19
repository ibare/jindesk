// 강의 계획 목차 (syllabus/<과목 id>.yaml). 목차 만들기가 근거 문서(과목 가이드, MYP 단원 안내)에서 만든다.
// 처음 만든 목차는 확인 전(confirmed: null)이고, 화면에서 확인한다.
import Foundation

// MYP 단원 안내에서 뽑는 것
public struct MYPUnit: Sendable, Equatable {
  public var keyConcept: String?
  public var relatedConcepts: [String]
  public var globalContext: String?
  public var statementOfInquiry: String?

  public init(keyConcept: String? = nil, relatedConcepts: [String] = [], globalContext: String? = nil, statementOfInquiry: String? = nil) {
    self.keyConcept = keyConcept
    self.relatedConcepts = relatedConcepts
    self.globalContext = globalContext
    self.statementOfInquiry = statementOfInquiry
  }

  var yaml: YAMLValue {
    var m = YAMLMap([])
    m["key_concept"] = keyConcept.map(YAMLValue.string) ?? .null
    m["related_concepts"] = .array(relatedConcepts.map(YAMLValue.string))
    m["global_context"] = globalContext.map(YAMLValue.string) ?? .null
    m["statement_of_inquiry"] = statementOfInquiry.map(YAMLValue.string) ?? .null
    return .map(m.with(style: .block))
  }

  init?(yaml: YAMLValue?) {
    guard let y = yaml, y.map != nil else { return nil }
    self.init(
      keyConcept: y["key_concept"]?.string, relatedConcepts: y["related_concepts"]?.strings ?? [], globalContext: y["global_context"]?.string,
      statementOfInquiry: y["statement_of_inquiry"]?.string)
  }
}

public struct SyllabusItem: Sendable, Equatable {
  public let code: String
  public var title: String
  public var level: String?
  public var src: [String]
  public var myp: MYPUnit?
  public var children: [SyllabusItem]
  // 이름이 바뀐 옛 코드
  public var renamedFrom: String?

  public init(
    code: String, title: String, level: String? = nil, src: [String] = [], myp: MYPUnit? = nil, children: [SyllabusItem] = [], renamedFrom: String? = nil
  ) {
    self.code = code
    self.title = title
    self.level = level
    self.src = src
    self.myp = myp
    self.children = children
    self.renamedFrom = renamedFrom
  }

  var yaml: YAMLValue {
    var m: YAMLMap = ["code": .string(code), "title": .string(title)]
    if let level { m["level"] = .string(level) }
    if !src.isEmpty { m["src"] = .array(src.map(YAMLValue.string)) }
    if let renamedFrom { m["renamed_from"] = .string(renamedFrom) }
    if let myp { m["myp"] = myp.yaml }
    if !children.isEmpty { m["children"] = .array(children.map(\.yaml)) }
    return .map(m)
  }

  init?(yaml: YAMLValue) {
    guard let code = yaml["code"]?.string else { return nil }
    self.init(
      code: code, title: yaml["title"]?.string ?? code, level: yaml["level"]?.string, src: yaml["src"]?.strings ?? [], myp: MYPUnit(yaml: yaml["myp"]),
      children: (yaml["children"]?.array ?? []).compactMap(SyllabusItem.init(yaml:)), renamedFrom: yaml["renamed_from"]?.string)
  }
}

public struct Syllabus: Sendable, Equatable {
  public let subject: String
  // MYP, DP 또는 모름
  public var programme: String?
  public var sources: [(id: String, title: String)]
  public var tree: [SyllabusItem]
  public var confirmed: (by: String, at: String)?
  public var provenance: YAMLMap

  public static func == (a: Syllabus, b: Syllabus) -> Bool {
    a.subject == b.subject && a.programme == b.programme && a.tree == b.tree && a.sources.map(\.id) == b.sources.map(\.id)
      && a.confirmed?.at == b.confirmed?.at
  }

  public init(
    subject: String, programme: String?, sources: [(id: String, title: String)], tree: [SyllabusItem], confirmed: (by: String, at: String)? = nil,
    provenance: YAMLMap = YAMLMap([])
  ) {
    self.subject = subject
    self.programme = programme
    self.sources = sources
    self.tree = tree
    self.confirmed = confirmed
    self.provenance = provenance
  }

  // 나무를 앞에서부터 편 차례 (깊이와 함께)
  public var items: [SyllabusItem] { flat.map(\.item) }

  public var flat: [(item: SyllabusItem, depth: Int)] {
    var out: [(SyllabusItem, Int)] = []
    func walk(_ list: [SyllabusItem], _ depth: Int) {
      for i in list {
        out.append((i, depth))
        walk(i.children, depth + 1)
      }
    }
    walk(tree, 0)
    return out
  }

  public static func load(_ data: DataFolder, subject: String) -> Syllabus? {
    guard let v = try? YAML.read(data.syllabusFile(subject)), v["kind"]?.string == "syllabus" else { return nil }
    let confirmed = v["confirmed"]?.map.map { (by: $0["by"]?.string ?? "", at: $0["at"]?.string ?? "") }
    return Syllabus(
      subject: subject, programme: v["programme"]?.string,
      sources: (v["sources"]?.array ?? []).compactMap { s in s["id"]?.string.map { ($0, s["title"]?.string ?? $0) } },
      tree: (v["items"]?.array ?? []).compactMap(SyllabusItem.init(yaml:)), confirmed: confirmed, provenance: v["provenance"]?.map ?? YAMLMap([]))
  }

  public var yaml: YAMLMap {
    [
      "kind": "syllabus",
      "v": 1,
      "subject": .string(subject),
      "programme": programme.map(YAMLValue.string) ?? .null,
      "sources": .array(sources.map { .map(["id": .string($0.id), "title": .string($0.title)]) }),
      "items": .array(tree.map(\.yaml)),
      "confirmed": confirmed.map { .map(["by": .string($0.by), "at": .string($0.at)]) } ?? .null,
      "provenance": .map(provenance),
    ]
  }

  public func write(_ data: DataFolder) throws {
    try FileOps.writeAtomic(YAML.stringify(yaml), to: data.syllabusFile(subject))
  }

  // 대소문자와 공백을 가리지 않고 찾는다
  public func item(_ code: String?) -> SyllabusItem? {
    guard let code = code?.nilIfBlank else { return nil }
    let key = ItemPath.dir(code)
    return items.first { ItemPath.dir($0.code) == key }
  }
}
