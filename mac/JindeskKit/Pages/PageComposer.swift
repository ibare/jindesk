// 화면에 넘길 학습 페이지 조합 (PAGES.md 의 렌더러: 조합). 페이지 + 곁 층 + 용어 + 출처 이름을 JSON 하나로 만든다.
// 렌더러(renderer/page.js)의 window.jindesk.render 가 받는다.
import Foundation

public enum PageComposer {
  public struct Input: Sendable {
    public let concept: Concept
    public let page: Page?
    public let layers: Layers?
    public let glossary: Glossary
    public let library: SourceLibrary
    public let subjectName: String?

    public init(concept: Concept, page: Page?, layers: Layers?, glossary: Glossary, library: SourceLibrary, subjectName: String?) {
      self.concept = concept
      self.page = page
      self.layers = layers
      self.glossary = glossary
      self.library = library
      self.subjectName = subjectName
    }
  }

  public static func load(_ data: DataFolder, concept: Concept, library: SourceLibrary) -> Input {
    let folder = ConceptFolder(concept.cid, in: data)
    let name = library.subjects.first { $0.id == concept.subject }?.name
    return Input(
      concept: concept, page: Page.load(folder), layers: Layers.load(folder), glossary: Glossary.load(data), library: library, subjectName: name)
  }

  // 출처 칩의 이름: 원본 파일 이름(확장자 뗌)을 줄인 것 · 쪽
  static func sourceTitle(_ id: String, library: SourceLibrary) -> String {
    guard let s = library.source(id) else { return id }
    let name = (s.meta.original.name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
    return name
  }

  static func shortTitle(_ title: String) -> String {
    let words = title.split(separator: " ")
    let short = words.prefix(3).joined(separator: " ")
    return words.count > 3 ? short + "…" : short
  }

  public static func json(_ input: Input) -> JSONValue {
    let c = input.concept
    var crumb = [input.subjectName ?? c.subject]
    if let item = c.item { crumb.append(item) } else if let proposed = c.itemProposed { crumb.append(proposed) }
    var chips: [String] = []
    if c.item == nil { chips.append("목차 밖") }
    let sourceCount = c.sources.count
    if sourceCount > 0 { chips.append("자료 \(sourceCount)개에서 정리") }

    var units: [JSONValue] = []
    let unitByID = Dictionary(c.units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for u in input.page?.units ?? [] {
      var o: [String: JSONValue] = ["id": .string(u.id), "kind": .string(u.kind.rawValue), "prov": .string(u.prov)]
      if let text = u.text { o["text"] = .string(text) }
      if let note = u.note { o["note"] = .string(note.rawValue) }
      if let tex = u.block?["tex"]?.string { o["tex"] = .string(tex) }
      if u.isFigure, let code = u.block?["code"]?.string {
        o["figure"] = .object([
          "src": .string(figureURL(concept: c.id, code: code)), "title": .string(u.block?["title"]?.string ?? ""),
        ])
      }
      if let caption = u.caption { o["caption"] = .string(caption) }
      if let ko = input.layers?.ko[u.id] {
        o["ko"] = .string(ko.text)
        if !ko.isCurrent(for: u) { o["koStale"] = .bool(true) }
      }
      // 문단은 제 주장의 출처를, 자료에서 온 강조 상자는 그 원문 단위의 출처를 단다
      var refs: [String] = []
      let claims = u.kind == .para ? u.claims : (u.kind == .note && u.prov == "source" ? unitByID[u.fromUnit]?.claims ?? [] : [])
      for claim in claims { for r in claim.src where !refs.contains(r) { refs.append(r) } }
      o["src"] = .array(chipList(refs, library: input.library))
      units.append(.object(o))
    }

    var sources: [JSONValue] = []
    for id in c.sources {
      let runs = input.library.source(id)?.meta.buildUps ?? []
      let pages = Array(Set(c.occurrences.filter { $0.source == id }.flatMap(\.pages).map { p in runs.first { $0.contains(p) }?.last ?? p })).sorted()
      sources.append(.object(["id": .string(id), "title": .string(sourceTitle(id, library: input.library)), "pages": .array(pages.map { .number(Double($0)) })]))
    }

    let terms: [JSONValue] = input.glossary.terms.filter { $0.subjects.isEmpty || $0.subjects.contains(c.subject) }.map { t in
      .object(["en": .string(t.en), "ko": .string(t.ko), "names": .array(t.names.map(JSONValue.string))])
    }

    var page: [String: JSONValue] = [
      "concept": .string(c.id), "title": .string(c.title), "crumb": .string(crumb.joined(separator: " › ")),
      "chips": .array(chips.map(JSONValue.string)), "units": .array(units), "sources": .array(sources), "terms": .array(terms),
    ]
    if let ko = input.page?.titleKo { page["titleKo"] = .string(ko) }
    return .object(page)
  }

  // 그림 블록의 iframe 주소: jindesk-page://figure/<코드 경로>?c=<개념 id>. 앱이 개념 폴더의 코드를 블록 틀에 넣어 돌려준다.
  public static func figureURL(concept: String, code: String) -> String {
    var c = URLComponents()
    c.scheme = FigureFrame.pageScheme
    c.host = "figure"
    c.path = "/" + code
    c.queryItems = [URLQueryItem(name: "c", value: concept)]
    return c.string ?? ""
  }

  // 같은 자료의 쪽은 칩 하나로 모은다: "Exponent rules · 4, 5". 이어 채운 쪽 묶음은 마지막 쪽 하나로 센다.
  static func chipList(_ refs: [String], library: SourceLibrary) -> [JSONValue] {
    var order: [String] = []
    var pages: [String: [Int]] = [:]
    for r in refs {
      guard let (source, raw) = SourceRef.parse(r) else { continue }
      let page = library.source(source)?.meta.buildUps.first { $0.contains(raw) }?.last ?? raw
      if pages[source] == nil { order.append(source) }
      if !(pages[source]?.contains(page) ?? false) { pages[source, default: []].append(page) }
    }
    return order.flatMap { source -> [JSONValue] in
      let title = sourceTitle(source, library: library)
      let list = pages[source]!.sorted()
      return [
        .object([
          "source": .string(source), "page": .number(Double(list[0])), "label": .string("\(shortTitle(title)) · \(list.map(String.init).joined(separator: ", "))"),
          "title": .string(title),
        ])
      ]
    }
  }
}
