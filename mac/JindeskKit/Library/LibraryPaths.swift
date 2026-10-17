// 엔트리와 정리층의 경로 (DATA.md 의 데이터 폴더 배치).
// 경로의 <항목>은 강의 계획 코드를 소문자로 쓰고 공백을 - 로 바꾼 것이다. 목차에 없는 것은 unplaced 다.
import Foundation

public enum ItemPath {
  public static let unplaced = "unplaced"

  public static func dir(_ code: String?) -> String {
    guard let code = code?.nilIfBlank else { return unplaced }
    return code.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
  }
}

// 개념 id: <과목 id>/<항목>/<slug>. 목차 밖 개념은 <과목 id>/unplaced/<slug> 이고 library/unplaced/<과목 id>/<slug>/ 에 둔다.
public struct ConceptID: Sendable, Equatable, Hashable {
  public let subject: String
  public let item: String
  public let slug: String

  public init(subject: String, item: String, slug: String) {
    self.subject = subject
    self.item = item
    self.slug = slug
  }

  public init?(_ id: String) {
    let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
    self.init(subject: parts[0], item: parts[1], slug: parts[2])
  }

  public var text: String { "\(subject)/\(item)/\(slug)" }
  public var isUnplaced: Bool { item == ItemPath.unplaced }
}

extension DataFolder {
  public var entriesRoot: URL { library.appending(path: "entries") }
  public var conceptsRoot: URL { library.appending(path: "concepts") }
  public var unplacedRoot: URL { library.appending(path: "unplaced") }
  public var glossaryFile: URL { library.appending(path: "glossary.yaml") }

  public func entriesDir(_ subject: String) -> URL { entriesRoot.appending(path: subject) }

  // 엔트리 id 는 entries/ 아래 경로에서 .md 를 뗀 것이다
  public func entryFile(_ id: String) -> URL { entriesRoot.appending(path: id + ".md") }

  public func conceptDir(_ id: ConceptID) -> URL {
    id.isUnplaced
      ? unplacedRoot.appending(path: id.subject).appending(path: id.slug)
      : conceptsRoot.appending(path: id.subject).appending(path: id.item).appending(path: id.slug)
  }

  public func syllabusFile(_ subject: String) -> URL { syllabus.appending(path: "\(subject).yaml") }
}

// 개념 폴더 하나의 파일들
public struct ConceptFolder: Sendable, Equatable {
  public let id: ConceptID
  public let url: URL

  public init(_ id: ConceptID, in data: DataFolder) {
    self.id = id
    url = data.conceptDir(id)
  }

  public var concept: URL { url.appending(path: "concept.yaml") }
  public var page: URL { url.appending(path: "page.yaml") }
  public var layers: URL { url.appending(path: "layers.yaml") }
  public var history: URL { url.appending(path: "history.jsonl") }
}

// 뜻을 해시한다 (DATA.md 의 해시): 정해진 필드만 정규화(NFC, LF, 줄 끝 공백 제거, 앞뒤 빈 줄 제거, 키 정렬)한 JSON 의 sha256 앞 16자
public enum MeaningHash {
  public static func of(_ value: JSONValue) -> String {
    Hash.short(Data(JSONText.line(normalize(value)).utf8))
  }

  static func normalize(_ value: JSONValue) -> JSONValue {
    switch value {
    case .string(let s): .string(normalize(s))
    case .array(let a): .array(a.map(normalize))
    case .object(let o): .object(o.mapValues(normalize))
    default: value
    }
  }

  public static func normalize(_ s: String) -> String {
    let lines = s.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
    let trimmed = lines.map { line -> Substring in
      var l = line
      while let last = l.last, last == " " || last == "\t" { l.removeLast() }
      return l
    }
    return trimmed.joined(separator: "\n").trimmingCharacters(in: .newlines)
  }
}
