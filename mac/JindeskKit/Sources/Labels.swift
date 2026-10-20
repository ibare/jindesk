// 자료의 꼬리표 (DECISIONS.md 21). 학년·과목·수준을 미리 등록하지 않고, 자료를 넣을 때 그 자료에 붙인다.
// 꼬리표는 열린 이름-값이다. grade(학년), subject(과목), level(수준)은 처음 제안하는 이름일 뿐이다.
import Foundation

public struct SourceLabels: Sendable, Equatable, Codable {
  public struct Label: Sendable, Equatable, Codable {
    public let name: String
    public var value: String

    public init(name: String, value: String) {
      self.name = name
      self.value = value
    }
  }

  public static let grade = "grade"
  public static let subject = "subject"
  public static let level = "level"
  // 화면에 보이는 차례
  public static let standardNames = [grade, subject, level]

  public private(set) var entries: [Label]

  public init(_ entries: [Label] = []) {
    self.entries = []
    for e in entries { self[e.name] = e.value }
  }

  public init(grade: String?, subject: String?, level: String?) {
    self.init()
    self[Self.grade] = grade
    self[Self.subject] = subject
    self[Self.level] = level
  }

  // 빈 값은 넣지 않는다 (nil 이나 공백만 있는 값을 넣으면 지운다)
  public subscript(name: String) -> String? {
    get { entries.first { $0.name == name }?.value }
    set {
      let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      if let i = entries.firstIndex(where: { $0.name == name }) {
        if let value { entries[i].value = value } else { entries.remove(at: i) }
      } else if let value {
        entries.append(Label(name: name, value: value))
      }
    }
  }

  public var grade: String? { self[Self.grade] }
  public var subject: String? { self[Self.subject] }
  public var level: String? { self[Self.level] }

  // 과목 id (과목 꼬리표가 없으면 nil)
  public var subjectID: String? { subject.map(SubjectID.make) }

  public static func displayName(_ name: String) -> String {
    switch name {
    case grade: "학년"
    case subject: "과목"
    case level: "수준"
    default: name
    }
  }

  // 화면과 리포트용 한 줄 (예: "DP1 · Physics · HL")
  public var summary: String {
    entries.map(\.value).joined(separator: " · ")
  }

  public var yaml: YAMLMap {
    YAMLMap(entries.map { ($0.name, .string($0.value)) })
  }

  public init(yaml: YAMLMap?) {
    self.init((yaml?.entries ?? []).compactMap { e in e.value.string.map { Label(name: e.key, value: $0) } })
  }
}

// 과목 id: 과목 꼬리표에서 만든다. 영어 소문자, 숫자, - 이고 수준을 넣지 않는다 (DATA.md 의 id).
public enum SubjectID {
  public static func make(_ subject: String) -> String {
    let slug = JobID.slugify(subject, maxLength: 60)
    if !slug.isEmpty { return slug }
    // 영어가 아닌 이름(예: 한국어 과목)은 이름의 해시로 만든다
    return "subject-" + String(Hash.sha256(Data(LabelMatch.key(subject).utf8)).prefix(8))
  }
}

// 언어 습득 과목 (DECISIONS.md 44). 과목 꼬리표의 이름으로 알아본다. 작업들은 요청에 적힌 이 판단을 함께 쓴다.
// 영어와 한국어는 목록에 없다(언어와 문학으로 본다). "English B" 처럼 언어 습득 표시가 있으면 언어 습득 과목이다.
public enum LanguageAcquisition {
  static let names = [
    "spanish": "Spanish", "español": "Spanish", "espanol": "Spanish", "french": "French", "français": "French", "francais": "French",
    "german": "German", "deutsch": "German", "italian": "Italian", "portuguese": "Portuguese", "mandarin": "Mandarin", "chinese": "Chinese",
    "japanese": "Japanese", "arabic": "Arabic", "russian": "Russian", "hindi": "Hindi", "dutch": "Dutch",
  ]
  // 과목 이름에 언어가 없을 때(Language Acquisition, Language B)의 목표 언어
  public static let unnamed = "the target language"

  // 목표 언어 (예: Spanish). 언어 습득 과목이 아니면 nil. 과목 꼬리표 값과 과목 id 를 모두 받는다.
  public static func target(of subject: String) -> String? {
    let words = LabelMatch.key(subject).split { !$0.isLetter }.map(String.init)
    let pairs = zip(words, words.dropFirst()).map { "\($0) \($1)" }
    if words.contains("literature") || pairs.contains("language a") { return nil }
    if let named = words.lazy.compactMap({ names[$0] }).first { return named }
    guard pairs.contains("language acquisition") || pairs.contains("ab initio") || words.last == "b" else { return nil }
    if let first = words.first, first != "language" { return first.capitalized }
    return unnamed
  }

  // 작업 요청(request.md)에 넣는 줄. 지침의 "언어 습득 과목" 절이 이 줄을 보고 적용된다.
  public static func requestLine(_ target: String) -> String {
    let language = target == unnamed ? "과목 이름에 없다. 자료로 알아본다" : target
    return "- 과목 갈래: 언어 습득 (목표 언어: \(language)). 지침의 \"언어 습득 과목\" 절을 따른다"
  }
}

// 적은 값을 이미 있는 값에 맞춘다. 대소문자와 띄어쓰기만 다르면 같은 값으로 본다.
public enum LabelMatch {
  public static func key(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  // existing 가운데 같은 값이 있으면 그 철자를, 없으면 공백을 정리한 값을 돌려준다
  public static func canonical(_ value: String, among existing: [String]) -> String {
    let k = key(value)
    if let hit = existing.first(where: { key($0) == k }) { return hit }
    return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  public static func canonical(_ labels: SourceLabels, using used: (String) -> [String]) -> SourceLabels {
    var out = SourceLabels()
    for e in labels.entries { out[e.name] = canonical(e.value, among: used(e.name)) }
    return out
  }
}

// 미리 준비한 값. 이전에 쓴 값 뒤에 제안으로 보인다. 목록에 없는 값은 그냥 적으면 된다.
public enum LabelSuggestions {
  public static let grades = ["MYP 1", "MYP 2", "MYP 3", "MYP 4", "MYP 5", "DP1", "DP2"]
  public static let levels = ["SL", "HL", "Standard", "Extended"]
  public static let subjects = [
    // DP
    "Language A: Literature", "Language A: Language and Literature", "Language B", "Economics", "Business Management", "Geography",
    "History", "Psychology", "Global Politics", "Biology", "Chemistry", "Physics", "Computer Science", "Design Technology",
    "Environmental Systems and Societies", "Mathematics: Analysis and Approaches", "Mathematics: Applications and Interpretation",
    "Visual Arts", "Music", "Theatre", "Theory of Knowledge",
    // MYP
    "Language and Literature", "Language Acquisition", "Individuals and Societies", "Sciences", "Mathematics", "Extended Mathematics", "Arts",
    "Design", "Physical and Health Education",
  ]

  public static func values(for name: String) -> [String] {
    switch name {
    case SourceLabels.grade: grades
    case SourceLabels.level: levels
    case SourceLabels.subject: subjects
    default: []
    }
  }

  // 이전에 쓴 값(최근 것부터) 뒤에 미리 준비한 값을 잇는다. 대소문자만 다른 값은 하나만 둔다.
  public static func merged(used: [String], name: String) -> [String] {
    var out: [String] = []
    for v in used + values(for: name) where !out.contains(where: { LabelMatch.key($0) == LabelMatch.key(v) }) { out.append(v) }
    return out
  }
}
