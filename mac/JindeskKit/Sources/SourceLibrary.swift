// 데이터 폴더의 자료 목록. 과목 목록은 따로 없고 자료들의 꼬리표에서 모은다 (DECISIONS.md 21).
// 색인(SQLite)이 생기기 전까지는 sources/ 를 읽어 만든다.
import Foundation

public struct SourceSummary: Sendable, Equatable, Identifiable {
  public let folder: SourceFolder
  public let meta: SourceMeta
  public let labels: SourceLabelsFile
  public var id: String { folder.id }
}

public struct SubjectSummary: Sendable, Equatable, Identifiable {
  public let id: String
  // 과목 꼬리표의 값 (가장 최근 자료의 철자)
  public let name: String
  public let sources: [SourceSummary]
  // 이 과목 자료들에 붙은 학년과 수준
  public let grades: [String]
  public let levels: [String]
}

public struct SourceLibrary: Sendable, Equatable {
  // 받은 때가 늦은 것부터
  public let sources: [SourceSummary]
  // 읽지 못한 자료 폴더와 까닭
  public let problems: [String]

  public init(sources: [SourceSummary], problems: [String] = []) {
    self.sources = sources
    self.problems = problems
  }

  public static func load(_ data: DataFolder) -> SourceLibrary {
    var sources: [SourceSummary] = []
    var problems: [String] = []
    for id in FileOps.list(data.sources).sorted() where SourceID.isValid(id) {
      let folder = SourceFolder(id: id, in: data)
      do {
        let meta = try SourceMeta.read(folder)
        let labels = (try? SourceLabelsFile.read(folder)) ?? SourceLabelsFile(source: id, labels: SourceLabels(), memo: nil, syllabusBasis: false)
        sources.append(SourceSummary(folder: folder, meta: meta, labels: labels))
      } catch {
        problems.append("\(id): \(error.localizedDescription)")
      }
    }
    sources.sort { ($0.meta.received, $0.id) > ($1.meta.received, $1.id) }
    return SourceLibrary(sources: sources, problems: problems)
  }

  public func source(_ id: String) -> SourceSummary? { sources.first { $0.id == id } }

  // 원본 해시 → 자료 id (같은 파일을 다시 넣었는지 볼 때). 수업마다 쪼갠 자료는 원래 파일의 해시로도 찾는다.
  public var hashes: [String: String] {
    let split = sources.compactMap { s in s.meta.splitFrom.map { ($0.sha256, s.id) } }
    return Dictionary(sources.map { ($0.meta.original.sha256, $0.id) } + split, uniquingKeysWith: { a, _ in a })
  }

  // 그 꼬리표에 쓴 값들. 최근에 쓴 것부터이고, 대소문자만 다른 값은 하나만 둔다.
  public func usedValues(_ name: String) -> [String] {
    var out: [String] = []
    for s in sources {
      guard let v = s.labels.labels[name], !out.contains(where: { LabelMatch.key($0) == LabelMatch.key(v) }) else { continue }
      out.append(v)
    }
    return out
  }

  // 마지막으로 넣은 자료의 꼬리표 (자료 넣기의 기본값)
  public var lastLabels: SourceLabels { sources.first?.labels.labels ?? SourceLabels() }

  // 과목마다 묶는다. 과목 꼬리표가 없는 자료는 빠진다 (unlabeled 로 따로 본다).
  public var subjects: [SubjectSummary] {
    var order: [String] = []
    var groups: [String: [SourceSummary]] = [:]
    for s in sources {
      guard let id = s.labels.labels.subjectID else { continue }
      if groups[id] == nil { order.append(id) }
      groups[id, default: []].append(s)
    }
    return order.map { id in
      let list = groups[id]!
      func values(_ name: String) -> [String] {
        var out: [String] = []
        for s in list { if let v = s.labels.labels[name], !out.contains(v) { out.append(v) } }
        return out
      }
      return SubjectSummary(
        id: id, name: list.first?.labels.labels.subject ?? id, sources: list, grades: values(SourceLabels.grade), levels: values(SourceLabels.level))
    }
  }

  public var unlabeled: [SourceSummary] { sources.filter { $0.labels.labels.subject == nil } }
}
