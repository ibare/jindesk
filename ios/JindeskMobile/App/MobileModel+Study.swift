// 폰의 찾기, 사전, 단원 요약 (MOBILE.md 의 하는 일, DECISIONS.md 34). 맥과 같은 데이터(용어집, 개념의 기호, 관점)에서 읽기만 한다.
import Foundation
import JindeskKit

// 시트로 보일 용어나 기호
enum Lookup: Identifiable, Equatable {
  case term(String)
  case symbol(String)

  var id: String {
    switch self {
    case .term(let en): "term:\(en)"
    case .symbol(let s): "symbol:\(s)"
    }
  }
}

extension MobileModel {
  // 사전 줄의 선택 값 (과목 목록의 선택)
  static let termsSelection = "dict:terms"
  static let symbolsSelection = "dict:symbols"

  // 단원 요약의 선택 값 ("unit:<과목 id>|<단원 키>", 단원 키는 "item:<목차 코드>" 또는 "proposed:<단원 제안>")
  static func unitSelection(_ subject: String, _ key: String) -> String { "unit:\(subject)|\(key)" }

  static func unitKey(_ selection: String?) -> (subject: String, key: String)? {
    guard let selection, selection.hasPrefix("unit:") else { return nil }
    let parts = selection.dropFirst(5).split(separator: "|", maxSplits: 1).map(String.init)
    return parts.count == 2 ? (parts[0], parts[1]) : nil
  }

  // 배우는 순서 (과목이 섞이면 과목끼리)
  func inLearningOrder(_ list: [Concept]) -> [Concept] {
    var ranks: [String: [String: Int]] = [:]
    for s in Set(list.map(\.subject)) {
      ranks[s] = Dictionary(conceptMap(s, showOthers: false).learningOrder().enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }
    return list.sorted { a, b in
      a.subject != b.subject ? a.subject < b.subject : (ranks[a.subject]?[a.id] ?? .max, a.id) < (ranks[b.subject]?[b.id] ?? .max, b.id)
    }
  }

  func unit(_ subject: String, _ key: String) -> (title: String, concepts: [Concept], inquiry: String?) {
    let all = concepts[subject] ?? []
    if key.hasPrefix("item:") {
      let code = String(key.dropFirst(5))
      let item = syllabi[subject]?.item(code)
      return (item.map { "\($0.code) \($0.title)" } ?? code, inLearningOrder(all.filter { $0.item.map(ItemPath.dir) == ItemPath.dir(code) }), item?.myp?.statementOfInquiry)
    }
    let name = String(key.dropFirst(9))
    return (name, inLearningOrder(all.filter { $0.item == nil && ($0.itemProposed ?? "목차 밖") == name }), nil)
  }

  var glossary: Glossary { data.map(Glossary.load) ?? Glossary() }

  // 개념의 기호 (기호마다 처음 정의와 나온 개념)
  var symbols: [(symbol: String, meaning: String, concepts: [Concept])] {
    var order: [String] = []
    var by: [String: (String, [Concept])] = [:]
    for c in inLearningOrder(allConcepts) {
      for s in c.symbols {
        if by[s.symbol] == nil {
          order.append(s.symbol)
          by[s.symbol] = (s.meaning, [])
        }
        by[s.symbol]!.1.append(c)
      }
    }
    return order.map { ($0, by[$0]!.0, by[$0]!.1) }
  }

  // 찾기: 개념(영어·한국어 이름), 용어(영어·한국어), 기호(기호와 뜻)
  func searchConcepts(_ q: String) -> [Concept] {
    guard let data, !q.isEmpty else { return [] }
    return inLearningOrder(
      allConcepts.filter { c in
        c.title.localizedCaseInsensitiveContains(q) || (Page.load(ConceptFolder(c.cid, in: data))?.titleKo?.localizedCaseInsensitiveContains(q) ?? false)
      })
  }

  func searchTerms(_ q: String) -> [GlossaryTerm] {
    guard !q.isEmpty else { return [] }
    return glossary.terms.filter { t in (t.names + [t.ko]).contains { $0.localizedCaseInsensitiveContains(q) } }
      .sorted { $0.en.localizedCaseInsensitiveCompare($1.en) == .orderedAscending }
  }

  func searchSymbols(_ q: String) -> [(symbol: String, meaning: String, concepts: [Concept])] {
    guard !q.isEmpty else { return [] }
    return symbols.filter { TexText.display($0.symbol).localizedCaseInsensitiveContains(q) || $0.meaning.localizedCaseInsensitiveContains(q) }
  }

  // 그 말이 글에 나오는 개념 (용어 시트)
  func conceptsMentioning(_ term: GlossaryTerm) -> [Concept] {
    inLearningOrder(
      allConcepts.filter { c in
        (term.subjects.isEmpty || term.subjects.contains(c.subject))
          && term.names.contains { UnitDigest.mentions(([c.title] + c.units.map(\.text)).joined(separator: "\n"), $0) }
      })
  }
}
