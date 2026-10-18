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
    // 모든 과목의 개념 (선수 개념과 과목 사이 연결의 이름)
    public var all: [Concept] = []
    // 이 개념의 코멘트와 답글, 요구
    public var comments: [Comment] = []
    public var directives: [Directive] = []
    public var data: DataFolder?
    public var facets: ConceptFacets?
    public var references: [Reference] = []
    // 개념이 놓인 목차 항목 (빵 부스러기에 코드와 제목을 보인다)
    public var syllabusItem: SyllabusItem?

    public init(concept: Concept, page: Page?, layers: Layers?, glossary: Glossary, library: SourceLibrary, subjectName: String?, all: [Concept] = []) {
      self.concept = concept
      self.page = page
      self.layers = layers
      self.glossary = glossary
      self.library = library
      self.subjectName = subjectName
      self.all = all
    }
  }

  public static func load(_ data: DataFolder, concept: Concept, library: SourceLibrary, all: [Concept]? = nil) -> Input {
    let folder = ConceptFolder(concept.cid, in: data)
    let name = library.subjects.first { $0.id == concept.subject }?.name
    var input = Input(
      concept: concept, page: Page.load(folder), layers: Layers.load(folder), glossary: Glossary.load(data), library: library, subjectName: name,
      all: all ?? ConceptStore.everything(data))
    input.comments = CommentStore.thread(CommentStore.load(data), concept: concept.id)
    input.directives = DirectiveStore.forConcept(DirectiveStore.load(data), concept: concept.id)
    input.data = data
    input.facets = ConceptFacets.load(folder)
    input.references = References.load(data).concepts[concept.id]?.items ?? []
    input.syllabusItem = Syllabus.load(data, subject: concept.subject)?.item(concept.item)
    return input
  }

  // 출처 칩의 이름: 원본 파일 이름(확장자 뗌)을 줄인 것 · 쪽
  static func sourceTitle(_ id: String, library: SourceLibrary) -> String {
    guard let s = library.source(id) else { return id }
    let name = (s.meta.original.name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
    return name
  }

  // 학생이 읽는 글 속의 자료 id 를 자료 이름으로 바꾼다 (`<id>#p3` → 「이름」 3쪽)
  public static func readableRefs(_ text: String, library: SourceLibrary) -> String {
    let regex = try! NSRegularExpression(pattern: #"`?(\d{8}-[0-9a-f]{8})(?:#p(\d+))?`?"#)
    var out = text
    for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
      guard let whole = Range(m.range, in: text), let idRange = Range(m.range(at: 1), in: text) else { continue }
      let id = String(text[idRange])
      guard library.source(id) != nil else { continue }
      let page = Range(m.range(at: 2), in: text).map { " \(text[$0])쪽" } ?? ""
      out.replaceSubrange(whole, with: "「\(sourceTitle(id, library: library))」\(page)")
    }
    return out
  }

  static func shortTitle(_ title: String) -> String {
    let words = title.split(separator: " ")
    let short = words.prefix(3).joined(separator: " ")
    return words.count > 3 ? short + "…" : short
  }

  public static func json(_ input: Input) -> JSONValue {
    let c = input.concept
    var crumb = [input.subjectName ?? c.subject]
    if let item = input.syllabusItem { crumb.append("\(item.code) \(item.title)") } else if let item = c.item { crumb.append(item) } else if let proposed = c.itemProposed {
      crumb.append(proposed)
    }
    var chips: [String] = []
    if c.item == nil { chips.append("목차 밖") }
    let sourceCount = c.sources.count
    if sourceCount > 0 { chips.append("자료 \(sourceCount)개에서 정리") }

    var units: [JSONValue] = []
    let unitByID = Dictionary(c.units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for u in input.page?.units ?? [] {
      var o: [String: JSONValue] = ["id": .string(u.id), "rev": .number(Double(u.rev)), "kind": .string(u.kind.rawValue), "prov": .string(u.prov)]
      if let text = u.text { o["text"] = .string(text) }
      if let note = u.note { o["note"] = .string(note.rawValue) }
      if let tex = u.block?["tex"]?.string { o["tex"] = .string(tex) }
      if u.isFigure, let code = u.block?["code"]?.string {
        o["figure"] = .object([
          "src": .string(figureURL(concept: c.id, code: code)), "title": .string(u.block?["title"]?.string ?? ""),
        ])
      }
      if let caption = u.caption { o["caption"] = .string(caption) }
      if u.isDerivation { o["derivation"] = .object(["title": .string(u.block?["title"]?.string ?? "")]) }
      if u.kind == .step {
        if let tex = u.block?["tex"]?.string { o["tex"] = .string(tex) }
        if let parent = u.parent { o["parent"] = .string(parent) }
      }
      if u.kind == .check {
        if let answer = u.block?["answer"]?.string { o["answer"] = .string(answer) }
        if let solution = u.block?["solution"]?.string { o["solution"] = .string(solution) }
      }
      if let e = input.layers?.easy[u.id] {
        o["easy"] = .object(["en": .string(e.en), "ko": .string(e.ko), "stale": .bool(!e.isCurrent(for: u)), "checks": .array(e.checks.map(JSONValue.string))])
      }
      if let d = input.layers?.detail[u.id] {
        o["detail"] = .object(["en": .string(d.en), "ko": .string(d.ko), "stale": .bool(!d.isCurrent(for: u)), "checks": .array(d.checks.map(JSONValue.string))])
      }
      o["directives"] = .array(directiveList(input, unit: u))
      o["regen"] = .array(DirectiveOp.allCases.filter { ops(for: u).contains($0) }.map { .object(["op": .string($0.rawValue), "label": .string($0.label)]) })
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
    if let code = input.syllabusItem?.code ?? c.item?.uppercased() ?? c.itemProposed { page["code"] = .string(code) }
    // 앞뒤 개념: 머리의 작은 지도와 아래의 "이어서 배울 것" (DECISIONS.md 27)
    let around = ConceptMap.neighborhood(of: c, all: input.all)
    let subjects = Set((around.before + around.after).compactMap { $0.node.item == nil ? nil : ConceptID($0.node.id)?.subject })
    let syllabi = Dictionary(uniqueKeysWithValues: subjects.compactMap { s in input.data.flatMap { Syllabus.load($0, subject: s) }.map { (s, $0) } })
    page["before"] = .array(around.before.map { neighbor($0, input, syllabi: syllabi) })
    page["after"] = .array(around.after.map { neighbor($0, input, syllabi: syllabi) })
    // 과목 사이 연결 (이 개념을 가리키는 다른 과목의 연결도 함께)
    let byID = Dictionary(input.all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var links: [JSONValue] = c.links.map { l in
      .object(["id": .string(l.concept), "title": .string(byID[l.concept]?.title ?? l.concept), "subject": .string(byID[l.concept]?.subject ?? ""), "note": .string(l.note)])
    }
    for other in input.all where other.id != c.id {
      for l in other.links where l.concept == c.id && !c.links.contains(where: { $0.concept == other.id }) {
        links.append(.object(["id": .string(other.id), "title": .string(other.title), "subject": .string(other.subject), "note": .string(l.note)]))
      }
    }
    page["links"] = .array(links)
    page["comments"] = comments(input)
    if let f = input.facets {
      var groups: [JSONValue] = []
      for (label, values) in [
        ("Command terms", f.commandTerms), ("Key concept", f.keyConcepts), ("Related concepts", f.relatedConcepts), ("Global context", f.globalContexts),
        ("Nature of science", f.nos), ("TOK", f.tok),
      ] where !values.isEmpty {
        groups.append(.object(["label": .string(label), "values": .array(values.map(JSONValue.string))]))
      }
      page["facets"] = .array(groups)
    }
    page["references"] = .array(
      input.references.map { .object(["url": .string($0.url), "title": .string($0.title), "kind": .string($0.kind), "why": .string($0.why)]) })
    return .object(page)
  }

  // 앞뒤 개념의 노드: 과목 지도의 노드와 같은 것(목차 코드, 한국어 이름, 학습 페이지가 있는지)과 너머로 더 이어지는 수.
  // 아직 없는 개념은 id 없이 이름만 (누를 수 없다)
  static func neighbor(_ n: ConceptMap.Neighbor, _ input: Input, syllabi: [String: Syllabus]) -> JSONValue {
    var o: [String: JSONValue] = ["title": .string(n.node.title), "beyond": .number(Double(n.beyond))]
    switch n.node.kind {
    case .missing:
      o["kind"] = .string("missing")
      o["missing"] = .bool(true)
      return .object(o)
    case .concept:
      o["kind"] = .string("concept")
    case .other(let s):
      o["kind"] = .string("other")
      o["subject"] = .string(input.library.subjects.first { $0.id == s }?.name ?? s)
    }
    o["id"] = .string(n.node.id)
    let cid = ConceptID(n.node.id)
    let syllabus = cid.flatMap { syllabi[$0.subject] }
    if let code = n.node.item.map({ syllabus?.item($0)?.code ?? $0.uppercased() }) ?? n.node.itemProposed { o["code"] = .string(code) }
    let page = input.data.flatMap { data in cid.flatMap { Page.load(ConceptFolder($0, in: data)) } }
    o["hasPage"] = .bool(page != nil)
    if let ko = page?.titleKo { o["titleKo"] = .string(ko) }
    return .object(o)
  }

  // 단위에서 고를 수 있는 다시 만들기 방식 (REGENERATION.md)
  static func ops(for u: PageUnit) -> [DirectiveOp] {
    if u.isFigure { return [.redraw, .easy, .fix] }
    if u.isDerivation { return [.steps, .easy, .fix] }
    switch u.kind {
    case .para: return [.easy, .detail, .example, .visual, .fix]
    case .note, .check, .step: return [.easy, .fix]
    case .block: return [.easy, .fix]
    }
  }

  // 이 단위의 요구와 상태. 후보가 있으면 견줄 내용을 함께 넣는다.
  static func directiveList(_ input: Input, unit: PageUnit) -> [JSONValue] {
    input.directives.filter { $0.target.unit == unit.id && $0.status != .kept }.suffix(4).map { d in
      var o: [String: JSONValue] = [
        "id": .string(d.id), "op": .string(d.op.rawValue), "label": .string(d.op.label), "status": .string(d.status.rawValue),
        "statusLabel": .string(d.status.label), "note": .string(d.note ?? ""),
      ]
      if d.status == .candidate, let job = d.job, let data = input.data {
        let record = data.record(JobKind.regen.rawValue, job)
        if let cand = Regen.Candidate.read(record.appending(path: "candidate.json")) {
          o["candidate"] = .array(cand.units.map { u in
            var c: [String: JSONValue] = ["kind": .string(u.kind.rawValue)]
            if let t = u.english { c["text"] = .string(t) }
            if u.isFigure, let file = cand.figures.first { c["figure"] = .string(candidateURL(job: job, file: file)) }
            if u.isDerivation { c["title"] = .string(u.block?["title"]?.string ?? "") }
            if u.kind == .step, let tex = u.block?["tex"]?.string { c["tex"] = .string(tex) }
            return .object(c)
          })
        }
        if let checks = try? JSONValue.parse(Data(contentsOf: record.appending(path: "checks.json"))) { o["checks"] = checks["checks"] ?? .array([]) }
      }
      return .object(o)
    }
  }

  // 그림 후보의 iframe 주소: jindesk-page://candidate/<작업 id>/<파일> (기록의 figures/ 에 있다)
  public static func candidateURL(job: String, file: String) -> String {
    "\(FigureFrame.pageScheme)://candidate/\(job)/\(file)"
  }

  // 단위마다 코멘트 스레드. 단위가 새 판이 되면 "이전 판에 단 코멘트"로 보인다 (old).
  static func comments(_ input: Input) -> JSONValue {
    let revs = Dictionary((input.page?.units ?? []).map { ($0.id, $0.rev) }, uniquingKeysWith: { a, _ in a })
    let replies = Dictionary(grouping: input.comments.filter { $0.kind == .answer }, by: { $0.replyTo ?? "" })
    var out: [String: [JSONValue]] = [:]
    for c in input.comments where c.kind != .answer {
      guard let a = c.anchor else { continue }
      let rs: [JSONValue] = (replies[c.id] ?? []).map { r in
        .object([
          "id": .string(r.id), "en": .string(r.textEn ?? r.text ?? ""), "ko": .string(r.textKo ?? ""), "at": .string(r.at),
          "supplementary": .bool(r.supplementary), "src": .array(chipList(r.src, library: input.library)),
        ])
      }
      out[a.unit, default: []].append(
        .object([
          "id": .string(c.id), "kind": .string(c.kind.rawValue), "label": .string(c.kind.label), "text": .string(c.text ?? ""), "at": .string(c.at),
          "rev": .number(Double(a.rev)), "quote": .string(a.quote), "old": .bool(a.rev < (revs[a.unit] ?? a.rev)),
          "waiting": .bool(c.kind == .ask && rs.isEmpty), "replies": .array(rs),
        ]))
    }
    return .object(out.mapValues { .array($0) })
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
