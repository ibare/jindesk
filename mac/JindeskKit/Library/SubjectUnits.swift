// 과목의 단원: 개념이 있는 목차 항목과, 목차 밖 개념의 단원 제안. 과목 목록의 단원 단계가 쓴다 (DECISIONS.md 39).
// 맥과 폰이 같이 쓴다. 단원 안의 개념을 배우는 순서로 놓는 것은 부르는 쪽이 한다.
import Foundation

public struct SubjectUnit: Sendable, Identifiable {
  // "item:<목차 코드>" 또는 "proposed:<단원 제안>" (단원 개요의 키, DECISIONS.md 34)
  public let key: String
  public let name: String
  public let concepts: [Concept]

  public var id: String { key }
  public var hasNew: Bool { concepts.contains { $0.isNew() } }
}

public enum SubjectUnits {
  // 목차 밖 개념에 단원 제안도 없을 때의 이름
  public static let unplacedName = "목차 밖"

  // 단원을 이름의 알파벳순으로 놓는다. 단원 사이의 배우는 순서는 데이터로 정할 수 없다 (DECISIONS.md 39).
  public static func make(_ concepts: [Concept], syllabus: Syllabus?) -> [SubjectUnit] {
    var out: [SubjectUnit] = []
    if let syllabus {
      for entry in syllabus.flat {
        let inItem = concepts.filter { $0.item.map(ItemPath.dir) == ItemPath.dir(entry.item.code) }
        if !inItem.isEmpty { out.append(SubjectUnit(key: "item:\(entry.item.code)", name: "\(entry.item.code) \(entry.item.title)", concepts: inItem)) }
      }
    }
    var order: [String] = []
    var byName: [String: [Concept]] = [:]
    for c in concepts where c.item == nil {
      let name = c.itemProposed ?? unplacedName
      if byName[name] == nil { order.append(name) }
      byName[name, default: []].append(c)
    }
    for name in order {
      out.append(SubjectUnit(key: "proposed:\(name)", name: (syllabus == nil ? "" : "목차 밖 · ") + name, concepts: byName[name]!))
    }
    // 지역 설정과 상관없이 같은 차례: 대소문자를 가리지 않고 수는 크기로 견준다. 한글 이름(목차 밖)은 영어 이름 뒤에 온다.
    return out.sorted { $0.name.compare($1.name, options: [.caseInsensitive, .numeric]) == .orderedAscending }
  }

  // 개념이 든 단원의 키. 목차 항목이면 목차의 코드를 쓴다.
  public static func key(_ concept: Concept, syllabus: Syllabus?) -> String {
    if let item = concept.item { return "item:\(syllabus?.item(item)?.code ?? item)" }
    return "proposed:\(concept.itemProposed ?? unplacedName)"
  }
}
