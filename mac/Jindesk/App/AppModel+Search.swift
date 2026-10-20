import Foundation
import JindeskKit

// 학습 페이지 안 찾기의 상태 (DECISIONS.md 48). 찾기 막대의 찾을 말, 렌더러에 보낸 요청, 렌더러가 알려 온 수
struct PageFind: Equatable {
  // 이 개념의 학습 페이지에서 찾는다. 다른 개념을 열면 막대가 닫힌다
  let concept: String
  var query: String
  var request: FindRequest
  // 모두 몇 곳, 지금 몇 번째 (렌더러가 알린다. 없으면 0)
  var total = 0
  var index = 0
  // 막대의 찾을 말 칸에 커서를 둔다 (⌘F). 오를 때마다 칸이 받는다
  var focus = 0
}

// 렌더러의 window.jindesk.find 에 보낼 요청. 같은 요청을 두 번 보내지 않게 seq 가 오른다
struct FindRequest: Equatable {
  var seq: Int
  var query: String
  // 처음 내려갈 단위 (찾기 결과에서 연 개념)
  var unit: String?
  // 0 처음, 1 다음, -1 이전
  var step: Int
}

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
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    pageFind = PageFind(concept: match.concept, query: query, request: nextFind(query: query, unit: match.firstUnit, step: 0))
  }

  // ⌘F: 학습 페이지가 열려 있으면 페이지 안 찾기 막대를, 아니면 사이드바의 찾기 칸을 연다
  func showFind() {
    guard case .concept(let id)? = selection else {
      focusSearchField += 1
      return
    }
    if pageFind?.concept != id {
      pageFind = PageFind(concept: id, query: "", request: nextFind(query: "", unit: nil, step: 0))
    }
    pageFind?.focus += 1
  }

  func setPageFindQuery(_ query: String) {
    guard var find = pageFind, find.query != query else { return }
    find.query = query
    find.request = nextFind(query: query, unit: nil, step: 0)
    pageFind = find
  }

  // ⌘G, ⇧⌘G
  func stepPageFind(_ step: Int) {
    guard var find = pageFind, !find.query.isEmpty else { return }
    find.request = nextFind(query: find.query, unit: nil, step: step)
    pageFind = find
  }

  func closePageFind() { pageFind = nil }

  // 렌더러가 알린 수 (그 개념의 막대에만 적는다)
  func pageFindReport(concept: String, total: Int, index: Int) {
    guard pageFind?.concept == concept else { return }
    pageFind?.total = total
    pageFind?.index = index
  }

  private func nextFind(query: String, unit: String?, step: Int) -> FindRequest {
    findSeq += 1
    return FindRequest(seq: findSeq, query: query, unit: unit, step: step)
  }
}
