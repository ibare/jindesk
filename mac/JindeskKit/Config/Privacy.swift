import Foundation

// 웹 금지어: 학생·학교·선생님 이름 (meta/privacy.yaml). 데이터 폴더에만 있고 리포와 릴리즈에는 들어가지 않는다.
// 외부 호출 검사 훅이 검색어와 주소에서 이 말을 찾으면 막고, 작업의 공통 검사가 산출물에서 찾는다.
public struct PrivacyTerms: Sendable, Equatable {
  public var terms: [String]

  public init(terms: [String]) {
    self.terms = Self.clean(terms)
  }

  // 앞뒤 공백을 떼고, 빈 것과 겹치는 것을 뺀다. 한국어 이름은 두 글자일 수 있어 한 글자만 뺀다.
  static func clean(_ terms: [String]) -> [String] {
    var out: [String] = []
    for term in terms.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping })
    where term.count >= 2 && !out.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
      out.append(term)
    }
    return out
  }

  public static func load(_ folder: DataFolder) throws -> PrivacyTerms {
    guard FileOps.exists(folder.privacyFile) else { return PrivacyTerms(terms: []) }
    let value = try YAML.read(folder.privacyFile)
    guard value["kind"]?.string == "privacy" else { throw ToolError("\(folder.privacyFile.path) 의 kind 가 privacy 가 아닙니다") }
    return PrivacyTerms(terms: value["terms"]?.strings ?? [])
  }

  public func save(_ folder: DataFolder) throws {
    let map: YAMLMap = ["kind": "privacy", "v": 1, "terms": .array(terms.map(YAMLValue.string))]
    try FileOps.writeAtomic(YAML.stringify(map), to: folder.privacyFile)
  }
}
