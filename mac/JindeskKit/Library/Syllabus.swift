// 강의 계획 목차 (syllabus/<과목 id>.yaml). 목차 만들기가 쓴다. 여기서는 항목 코드와 제목만 읽는다.
import Foundation

public struct SyllabusItem: Sendable, Equatable {
  public let code: String
  public let title: String
  public let level: String?
}

public struct Syllabus: Sendable, Equatable {
  public let subject: String
  // 나무를 앞에서부터 편 차례
  public let items: [SyllabusItem]

  public static func load(_ data: DataFolder, subject: String) -> Syllabus? {
    guard let v = try? YAML.read(data.syllabusFile(subject)), v["kind"]?.string == "syllabus" else { return nil }
    var items: [SyllabusItem] = []
    func walk(_ list: [YAMLValue]) {
      for node in list {
        if let code = node["code"]?.string {
          items.append(SyllabusItem(code: code, title: node["title"]?.string ?? code, level: node["level"]?.string))
        }
        walk(node["children"]?.array ?? [])
      }
    }
    walk(v["items"]?.array ?? [])
    return Syllabus(subject: subject, items: items)
  }

  // 대소문자와 공백을 가리지 않고 찾는다
  public func item(_ code: String?) -> SyllabusItem? {
    guard let code = code?.nilIfBlank else { return nil }
    let key = ItemPath.dir(code)
    return items.first { ItemPath.dir($0.code) == key }
  }
}
