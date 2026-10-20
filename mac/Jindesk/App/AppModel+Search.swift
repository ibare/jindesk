import Foundation
import JindeskKit

extension AppModel {
  func runSearch() {
    let q = searchText
    let index = searchIndex
    Task.detached { [weak self] in
      let results = index.search(q)
      let pages = index.sourcePages(q)
      await MainActor.run { [weak self] in
        guard let self, self.searchText == q else { return }
        self.searchResults = results
        self.searchPageHits = pages
      }
    }
  }

  // 원래 자료의 쪽에서 그 용어가 쓰인 곳 (모아 보기의 용어). 용어는 구절로 찾는다
  func sourcePageHits(_ term: String) -> [PageHit] { searchIndex.sourcePages("\"\(term)\"") }

  // 찾기의 용어: 모든 낱말이 영어 이름이나 한국어에 든 용어집의 용어
  func searchTerms(_ query: String) -> [GlossaryTerm] {
    let q = SearchQuery(query)
    guard let data, !q.isEmpty else { return [] }
    return Glossary.load(data).terms.filter { q.matches($0.names + [$0.ko]) }
      .sorted { $0.en.localizedCaseInsensitiveCompare($1.en) == .orderedAscending }
  }

  // 찾기의 기호: 모든 낱말이 기호나 뜻에 든 개념의 기호. 과목 거르기를 위해 그 기호를 쓰는 과목을 함께 든다
  func searchSymbols(_ query: String) -> [(symbol: String, meaning: String, subjects: Set<String>)] {
    let q = SearchQuery(query)
    guard !q.isEmpty else { return [] }
    var order: [String] = []
    var found: [String: (meaning: String, subjects: Set<String>)] = [:]
    for c in allConcepts {
      for s in c.symbols where q.matches([TexText.display(s.symbol), s.meaning]) {
        if found[s.symbol] == nil {
          order.append(s.symbol)
          found[s.symbol] = (s.meaning, [])
        }
        found[s.symbol]!.subjects.insert(c.subject)
      }
    }
    return order.map { ($0, found[$0]!.meaning, found[$0]!.subjects) }
  }

  // 찾기 결과에서 개념을 연다: 첫 맞은 단위까지 내려 열고 찾기 막대를 찾은 말로 연다
  func openSearchResult(_ match: ConceptMatch) {
    selection = .concept(match.concept)
    revealInList = match.concept
    pageFind = PageFind(concept: match.concept, query: searchText, unit: match.firstUnit)
  }

  // ⌘F: 학습 페이지가 열려 있으면 페이지 안 찾기 막대를, 아니면 사이드바의 찾기 칸을 연다
  func showFind() {
    guard case .concept(let id)? = selection else {
      focusSearchField += 1
      return
    }
    if pageFind?.concept != id { pageFind = PageFind(concept: id) }
    pageFind?.focus += 1
  }

  func setPageFindQuery(_ query: String) { pageFind?.setQuery(query) }

  // ⌘G, ⇧⌘G
  func stepPageFind(_ step: Int) { pageFind?.step(step) }

  func closePageFind() { pageFind = nil }

  // 렌더러가 알린 수 (그 개념의 막대에만 적는다)
  func pageFindReport(concept: String, total: Int, index: Int) {
    guard pageFind?.concept == concept else { return }
    pageFind?.total = total
    pageFind?.index = index
  }
}
