// 용어 어휘 (library/glossary.yaml): 영어 용어 → 한국어. 같은 영어 용어는 늘 같은 한국어로 옮긴다 (PAGES.md 의 언어).
// 번역이 제안한 새 용어는 다른 표기와 맞춰 본다. 대소문자, 띄어쓰기, 줄표를 가리지 않는다.
import Foundation

public struct GlossaryTerm: Sendable, Equatable {
  public let en: String
  public let ko: String
  public var aliases: [String]
  public var subjects: [String]

  public init(en: String, ko: String, aliases: [String] = [], subjects: [String] = []) {
    self.en = en
    self.ko = ko
    self.aliases = aliases
    self.subjects = subjects
  }

  public var names: [String] { [en] + aliases }

  var yaml: YAMLValue {
    var m: YAMLMap = ["en": .string(en), "ko": .string(ko)]
    if !aliases.isEmpty { m["aliases"] = .array(aliases.map(YAMLValue.string)) }
    if !subjects.isEmpty { m["subjects"] = .array(subjects.map(YAMLValue.string)) }
    return .map(m)
  }

  init?(yaml: YAMLValue) {
    guard let en = yaml["en"]?.string, let ko = yaml["ko"]?.string else { return nil }
    self.init(en: en, ko: ko, aliases: yaml["aliases"]?.strings ?? [], subjects: yaml["subjects"]?.strings ?? [])
  }
}

public struct Glossary: Sendable, Equatable {
  public var terms: [GlossaryTerm]

  public init(terms: [GlossaryTerm] = []) {
    self.terms = terms
  }

  // 그 과목의 용어와 과목이 적히지 않은 용어. 학습 페이지가 밑줄로 보이는 용어이고, 번역 검사도 이것만 본다.
  public func of(subject: String) -> Glossary {
    Glossary(terms: terms.filter { $0.subjects.isEmpty || $0.subjects.contains(subject) })
  }

  // 함께 도는 번역이 어휘를 덮어쓰지 않도록, 읽고 합치고 쓰는 동안 잠근다
  static let lock = NSLock()

  // 맞춰 볼 때 쓰는 열쇠: 소문자, 공백·줄표·밑줄을 뗀다
  public static func key(_ s: String) -> String {
    String(s.precomposedStringWithCanonicalMapping.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" && $0 != "‐" && $0 != "–" })
  }

  public func term(_ name: String) -> GlossaryTerm? {
    let k = Self.key(name)
    return terms.first { $0.names.contains { Self.key($0) == k } }
  }

  public static func load(_ data: DataFolder) -> Glossary {
    guard let v = try? YAML.read(data.glossaryFile), v["kind"]?.string == "glossary" else { return Glossary() }
    return Glossary(terms: (v["terms"]?.array ?? []).compactMap(GlossaryTerm.init(yaml:)))
  }

  public func write(_ data: DataFolder) throws {
    let map: YAMLMap = ["kind": "glossary", "v": 1, "terms": .array(terms.map(\.yaml))]
    try FileOps.writeAtomic(YAML.stringify(map), to: data.glossaryFile)
  }

  public struct MergeResult: Sendable, Equatable {
    public var added: [String] = []
    public var aliased: [String] = []
    // 이미 다른 한국어로 정해진 용어 (어휘의 한국어를 지킨다)
    public var conflicts: [String] = []
  }

  // 새 용어를 더한다. 이미 있는 용어와 표기만 다르면 그 용어의 다른 이름으로 넣는다.
  public mutating func merge(_ proposed: [(en: String, ko: String)], subject: String) -> MergeResult {
    var result = MergeResult()
    for p in proposed {
      let en = p.en.trimmingCharacters(in: .whitespacesAndNewlines)
      let ko = p.ko.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !en.isEmpty, !ko.isEmpty else { continue }
      let k = Self.key(en)
      if let i = terms.firstIndex(where: { $0.names.contains { Self.key($0) == k } }) {
        if !terms[i].subjects.isEmpty && !terms[i].subjects.contains(subject) { terms[i].subjects.append(subject) }
        if !terms[i].names.contains(en) {
          terms[i].aliases.append(en)
          result.aliased.append(en)
        }
        if Self.key(terms[i].ko) != Self.key(ko) { result.conflicts.append("\(en): 어휘는 \(terms[i].ko), 제안은 \(ko)") }
      } else {
        terms.append(GlossaryTerm(en: en, ko: ko, subjects: [subject]))
        result.added.append(en)
      }
    }
    return result
  }
}
