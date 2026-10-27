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

// 스택의 단계 (DECISIONS.md 39, 43). iPad 왼쪽 칸의 스택에는 목록 단계(과목, 단원, 사전)만 쌓이고,
// iPhone 의 한 스택에는 그 위에 고른 것이 올라간다.
enum Route: Hashable {
  // 과목의 단원 목록
  case subject(String)
  // 단원의 개념 목록 (과목 id, 단원 키). 단원 키는 "item:<목차 코드>" 또는 "proposed:<단원 제안>"
  case unit(String, String)
  // 사전: 용어 또는 기호
  case dictionary(symbols: Bool)
  // 고른 것 (iPhone 의 스택에서만)
  case page(PageRoute)
}

// 오른쪽 칸(iPhone 은 목록 위)에 여는 것
enum PageRoute: Hashable {
  case concept(String)
  // 단원 요약 (과목 id, 단원 키)
  case summary(String, String)
  // 과목 개념 지도 (과목 id)
  case map(String)
}

extension MobileModel {
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

  // 찾기: 개념(영어·한국어 이름), 용어(영어·한국어), 기호(기호와 뜻). 맥과 같은 낱말 규칙이다 (SearchQuery, DECISIONS.md 48):
  // 모든 낱말이 들어야 맞고, 대소문자와 악센트를 가리지 않는다. 본문 찾기는 다음 단계다.
  func searchConcepts(_ text: String) -> [Concept] {
    let q = SearchQuery(text)
    guard let data, !q.isEmpty else { return [] }
    return inLearningOrder(
      allConcepts.filter { c in
        q.matches(c.title) || (Page.load(ConceptFolder(c.cid, in: data))?.titleKo.map(q.matches) ?? false)
      })
  }

  func searchTerms(_ text: String) -> [GlossaryTerm] {
    let q = SearchQuery(text)
    guard !q.isEmpty else { return [] }
    return glossary.terms.filter { q.matches($0.names + [$0.ko]) }
      .sorted { $0.en.localizedCaseInsensitiveCompare($1.en) == .orderedAscending }
  }

  func searchSymbols(_ text: String) -> [(symbol: String, meaning: String, concepts: [Concept])] {
    let q = SearchQuery(text)
    guard !q.isEmpty else { return [] }
    return symbols.filter { q.matches([TexText.display($0.symbol), $0.meaning]) }
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
