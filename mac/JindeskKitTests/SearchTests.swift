import Foundation
import SQLite3
import Testing
@testable import JindeskKit

// 찾기 (DECISIONS.md 48): 질의 나누기, 색인, 순위, 비슷한 말 제안, 원래 자료의 쪽
@Suite struct SearchQueryTests {
  @Test func 따옴표는_구절이고_나머지는_빈칸으로_나눈다() {
    #expect(SearchQuery("  logarithm   laws ").terms == ["logarithm", "laws"])
    #expect(SearchQuery("\"laws of\" log").terms == ["laws of", "log"])
    #expect(SearchQuery("“laws of” log").terms == ["laws of", "log"])
    // 같은 낱말은 한 번 (대소문자, 악센트 무시)
    #expect(SearchQuery("Laws laws LÁWS").terms == ["Laws"])
    #expect(SearchQuery("   ").isEmpty)
  }

  @Test func 모든_낱말이_들어야_맞고_대소문자와_악센트를_가리지_않는다() {
    let q = SearchQuery("profesion CUAL")
    #expect(q.matches("¿Cuál es tu profesión?"))
    #expect(!q.matches("¿Cuál es tu trabajo?"))
    // 여러 칸에 나뉘어 들어도 된다 (용어의 영어 이름과 한국어)
    #expect(SearchQuery("resistance 저항").matches(["resistance", "전기 저항"]))
  }

  @Test func 찾은_말을_모두_표시하고_겹치면_합친다() {
    let marked = SearchQuery("log logarithm").mark("Logarithms use log.")
    #expect(marked == "\u{1}Logarithm\u{2}s use \u{1}log\u{2}.")
    #expect(SearchMark.plain(marked) == "Logarithms use log.")
  }

  @Test func 낱말_첫머리를_가린다() {
    #expect(SearchQuery.startsWord("Using logs", "log"))
    #expect(!SearchQuery.startsWord("Using logs", "sin"))
    #expect(SearchQuery.startsWord("로그의 성질", "로그"))
    #expect(!SearchQuery.startsWord("블로그", "로그"))
    // 숫자 뒤는 첫머리다 (2x 의 x)
    #expect(SearchQuery.startsWord("2x + 1", "x"))
  }
}

@Suite struct SearchIndexTests {
  // 개념 하나와 학습 페이지, 한국어 층을 쓴다. units: (페이지 단위 id, 영어, 한국어)
  func concept(_ t: TempPlace, _ id: String, title: String, titleKo: String? = nil, units: [(String, String, String?)]) throws {
    let cid = ConceptID(id)!
    try Concept(
      cid: cid, title: title, itemProposed: nil, occurrences: [], symbols: [], nextID: units.count + 1,
      units: units.enumerated().map { ConceptUnit(id: "u\($0.offset + 1)", text: $0.element.1, conditions: [], claims: []) }, provenance: YAMLMap([])
    ).write(t.data)
    let pageUnits = units.enumerated().map { PageUnit(id: $0.element.0, rev: 1, kind: .para, from: "u\($0.offset + 1)@x", prov: "source", text: $0.element.1) }
    let folder = ConceptFolder(cid, in: t.data)
    try Page(concept: id, titleKo: titleKo, nextID: units.count + 1, units: pageUnits, provenance: YAMLMap([])).write(folder)
    var ko: [String: LayerText] = [:]
    for (u, unit) in zip(units, pageUnits) where u.2 != nil { ko[u.0] = LayerText(from: "\(u.0)@r1", unitHash: unit.hash, text: u.2!, prov: YAMLMap([])) }
    if !ko.isEmpty { try Layers(concept: id, ko: ko).write(folder, order: pageUnits.map(\.id)) }
  }

  func place() throws -> TempPlace {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    return t
  }

  @Test func 영어와_한국어를_함께_찾고_바뀐_것이_없으면_다시_만들지_않는다() throws {
    let t = try place()
    try concept(t, "math/unplaced/laws", title: "Laws of logarithms", titleKo: "로그의 성질", units: [("p1", "The product law adds logarithms.", "곱의 법칙은 로그를 더한다.")])
    let index = SearchIndex(t.folders)
    #expect(index.update(t.data))
    #expect(!index.update(t.data))
    let found = index.search("product law").concepts
    #expect(found.map(\.concept) == ["math/unplaced/laws"])
    #expect(found.first?.firstUnit == "p1" && found.first?.count == 1)
    #expect(found.first?.snippets.first?.text.contains("\u{1}product\u{2} \u{1}law\u{2}") == true)
    #expect(index.search("곱의 법칙").concepts.first?.concept == "math/unplaced/laws")
    // 두 글자 한국어: 이름(한국어)과 단위 모두에서 맞는다
    let short = try #require(index.search("로그").concepts.first)
    #expect(short.inTitle && short.snippets.first?.text.contains("\u{1}로그\u{2}") == true)
    #expect(index.search("nothing like this") == .empty)
  }

  @Test func 낱말_차례가_달라도_찾고_따옴표는_구절로_찾는다() throws {
    let t = try place()
    try concept(t, "math/unplaced/laws", title: "Laws of logarithms", units: [("p1", "The laws of logarithms combine several logarithms into one.", nil)])
    let index = SearchIndex(t.folders)
    index.update(t.data)
    #expect(index.search("logarithm laws").concepts.count == 1)
    #expect(index.search("combine laws one").concepts.first?.firstUnit == "p1")
    #expect(index.search("\"logarithm laws\"").concepts.isEmpty)
    #expect(index.search("\"laws of\" combine").concepts.count == 1)
    // 한 단위 안에 모두 들어야 한다 (이름 줄과 단위는 따로다)
    #expect(index.search("several laws").concepts.first?.inTitle == false)
  }

  @Test func 악센트와_대소문자를_가리지_않는다() throws {
    let t = try place()
    try concept(t, "spanish/unplaced/jobs", title: "Talking about jobs", units: [("p1", "¿Cuál es tu PROFESIÓN? Soy bombero y estudio español.", nil)])
    let index = SearchIndex(t.folders)
    index.update(t.data)
    #expect(index.search("profesion").concepts.count == 1)
    #expect(index.search("espanol cual").concepts.count == 1)
    #expect(index.search("BOMBERO").concepts.first?.snippets.first?.text.contains("\u{1}bombero\u{2}") == true)
    // 두 글자 이하의 짧은 낱말은 글 전체에서 찾는다
    #expect(index.search("es bombero").concepts.count == 1)
  }

  @Test func 이름의_첫머리_친_말_그대로_첫머리로_맞은_단위_수_차례로_놓는다() throws {
    let t = try place()
    try concept(t, "science/unplaced/circuits", title: "Series circuits", units: (1...4).map { ("p\($0)", "Each resistance adds to the total resistance.", nil) })
    try concept(t, "science/unplaced/resistance", title: "Electrical resistance", units: [("p1", "Resistance opposes current.", nil)])
    try concept(t, "english/unplaced/poem", title: "Nonresistance in poems", units: (1...6).map { ("p\($0)", "The poem praises nonresistance.", nil) })
    try concept(t, "science/unplaced/total", title: "Totals", units: [("p1", "The total resistance of the circuit.", nil), ("p2", "Resistance totals add.", nil)])
    let index = SearchIndex(t.folders)
    index.update(t.data)
    let order = index.search("resistance").concepts.map(\.concept)
    // 이름의 첫머리 → 첫머리로 맞은 단위가 많은 것 → 낱말 가운데에만 걸린 것 (맞은 단위가 더 많아도 뒤)
    #expect(order == ["science/unplaced/resistance", "science/unplaced/circuits", "science/unplaced/total", "english/unplaced/poem"])
    // 친 말이 그대로 든 개념이 낱말만 따로 든 개념보다 앞선다
    #expect(index.search("total resistance").concepts.map(\.concept).prefix(2) == ["science/unplaced/circuits", "science/unplaced/total"])
    // 친 말 그대로는 차례까지 본다 ("Resistance totals" 의 첫머리)
    #expect(index.search("resistance total").concepts.first?.concept == "science/unplaced/total")
  }

  @Test func 상한은_개념_수이고_개념마다_앞뒤_글을_셋까지_든다() throws {
    let t = try place()
    try concept(t, "physics/unplaced/forces", title: "Forces", units: (1...60).map { ("p\($0)", "A force number \($0).", nil) })
    try concept(t, "physics/unplaced/friction", title: "Friction", units: [("p1", "Friction is a force.", nil)])
    try concept(t, "english/unplaced/voice", title: "Voice", units: [("p1", "The force of the poem.", nil)])
    let index = SearchIndex(t.folders)
    index.update(t.data)
    let found = index.search("force").concepts
    // 단위 40개 상한이었다면 앞 개념의 단위가 다른 개념을 밀어냈다
    #expect(found.count == 3)
    #expect(found[0].concept == "physics/unplaced/forces" && found[0].count == 60 && found[0].snippets.count == 3)
    #expect(found[0].snippets.map(\.unit) == ["p1", "p2", "p3"])
    #expect(index.search("force", limit: 2).concepts.count == 2)
  }

  @Test func 찾은_것이_없으면_비슷한_말을_제안한다() throws {
    let t = try place()
    try concept(t, "math/unplaced/logs", title: "Logarithms", units: [("p1", "A logarithm is an exponent. Logarithms have laws.", nil)])
    try concept(t, "physics/unplaced/motion", title: "Acceleration", units: [("p1", "Acceleration is the rate of change of velocity.", nil)])
    let index = SearchIndex(t.folders)
    index.update(t.data)
    #expect(index.search("logarithim").suggestions.first == "logarithm")
    #expect(index.search("acceleraton change").suggestions == ["acceleration change"])
    // 찾은 것이 있으면 하지 않는다. 가까운 낱말이 없으면 없다
    #expect(index.search("logarithm").suggestions.isEmpty)
    #expect(index.search("photosynthsis").suggestions.isEmpty)
    // 한국어나 짧은 낱말은 제안하지 않는다
    #expect(index.search("로그흐").suggestions.isEmpty)
  }

  @Test func 원래_자료의_쪽도_같은_낱말_규칙으로_찾는다() throws {
    let t = try place()
    let meta = SourceMeta(
      id: "20261021-aaaa0000", original: .init(name: "Logs.pdf", bytes: 1, sha256: "s"), received: "r", converted: nil, pages: 2,
      textLayer: .init(by: "pdfkit", pagesWithText: 2, ocrPages: []), buildUps: [])
    let folder = SourceFolder(id: meta.id, in: t.data)
    try meta.write(to: folder)
    try SourceLabelsFile(source: meta.id, labels: SourceLabels(grade: "MYP 5", subject: "Math", level: nil), memo: nil, syllabusBasis: false).write(to: folder)
    try FileOps.writeAtomic("Laws of logarithms\nproduct rule", to: folder.pageText(1))
    try FileOps.writeAtomic("Indices and powers", to: folder.pageText(2))
    let index = SearchIndex(t.folders)
    index.update(t.data)
    #expect(index.sourcePages("logarithm laws").map(\.page) == [1])
    #expect(index.sourcePages("\"laws of\"").first?.snippet.contains("\u{1}Laws of\u{2}") == true)
    // 세 글자 이상인 낱말이 하나는 있어야 찾는다
    #expect(index.sourcePages("of").isEmpty)
    #expect(index.sourcePages("powers of").isEmpty)
  }

  @Test func 색인_판이_바뀌면_지우고_다시_만든다() throws {
    let t = try place()
    try concept(t, "math/unplaced/laws", title: "Laws of logarithms", units: [("p1", "Product law.", nil)])
    let url = t.folders.cache.appending(path: "index.sqlite")
    do {
      let index = SearchIndex(url: url)
      #expect(index.update(t.data))
    }
    // 옛 판(3)의 색인이 남아 있다고 치면 다시 만든다
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    sqlite3_exec(db, "PRAGMA user_version = 3", nil, nil, nil)
    sqlite3_close(db)
    let index = SearchIndex(url: url)
    #expect(index.update(t.data))
    #expect(index.search("product").concepts.count == 1)
  }
}
