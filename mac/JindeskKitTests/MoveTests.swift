import Foundation
import Testing
@testable import JindeskKit

@Suite struct MoveTests {
  func concept(_ data: DataFolder, _ id: String, prerequisites: [String] = []) throws -> Concept {
    var c = Concept(
      cid: ConceptID(id)!, title: "T", itemProposed: "Logs", occurrences: [Occurrence(entry: "math/unplaced/e1", source: "20261017-aaaabbbb", pages: [1])],
      symbols: [], nextID: 2, units: [ConceptUnit(id: "u1", text: "x", conditions: [], claims: [])], provenance: YAMLMap([]))
    c.prerequisites = prerequisites
    try c.write(data)
    try Page(concept: id, titleKo: "로그", nextID: 2, units: [], provenance: YAMLMap([])).write(ConceptFolder(c.cid, in: data))
    return c
  }

  @Test func 개념을_옮기면_안의_id_와_가리키는_선수_개념이_바뀌고_옮긴_기록이_남는다() throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    _ = try concept(t.data, "math/unplaced/logs")
    _ = try concept(t.data, "math/unplaced/laws", prerequisites: ["math/unplaced/logs"])
    try References(concepts: ["math/unplaced/logs": (job: "j", items: [Reference(url: "https://example.org/logs", title: "Logs", kind: "article", why: "x")])]).write(t.data)
    try ConceptMove.move(t.data, from: ConceptID("math/unplaced/logs")!, to: ConceptID("math/u2/logs")!, why: "목차 U2")
    #expect(References.load(t.data).concepts["math/u2/logs"]?.items.first?.url == "https://example.org/logs")
    #expect(References.load(t.data).concepts["math/unplaced/logs"] == nil)
    let moved = try Concept.read(ConceptFolder(ConceptID("math/u2/logs")!, in: t.data).concept)
    #expect(moved.id == "math/u2/logs" && moved.item == "u2" && moved.itemProposed == nil)
    #expect(Page.load(ConceptFolder(moved.cid, in: t.data))?.concept == "math/u2/logs")
    #expect(!FileOps.exists(t.data.unplacedRoot.appending(path: "math/logs")))
    #expect(ConceptStore.load(t.data, id: ConceptID("math/unplaced/laws")!)?.prerequisites == ["math/u2/logs"])
    #expect(Moves.resolve("math/unplaced/logs", moves: Moves.all(t.data)) == "math/u2/logs")
  }

  @Test func 단위를_옮긴_줄을_따라_코멘트와_요구가_옮겨_간_문단을_찾는다() throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    _ = try concept(t.data, "math/unplaced/old")
    let target = try concept(t.data, "math/unplaced/new")
    // 받는 개념의 페이지: 원문 단위 u7 의 문단이 p3 이다
    try Page(
      concept: target.id, titleKo: "새", nextID: 4,
      units: [PageUnit(id: "p1", rev: 1, kind: .para, from: "u1@a", prov: "source"), PageUnit(id: "p3", rev: 1, kind: .para, from: "u7@b", prov: "source")],
      provenance: YAMLMap([])
    ).write(ConceptFolder(target.cid, in: t.data))
    // 없앤 개념 old: p2(원문 u2)는 new 의 u7 로 옮겼고, p1 은 뺐다
    try Moves.appendUnit(t.data, from: ("math/unplaced/old", "p2"), to: ("math/unplaced/new", "u7"), why: "다시 정리")
    try Moves.appendUnit(t.data, from: ("math/unplaced/old", "p1"), to: ("math/unplaced/new", nil), why: "다시 정리")
    try Moves.append(t.data, kind: "concept", from: "math/unplaced/old", to: "math/unplaced/new", why: "다시 정리로 없앰")
    let moves = Moves.all(t.data)
    #expect(Moves.resolve(concept: "math/unplaced/old", unit: "p2", moves: moves) == ("math/unplaced/new", "u7", true))
    #expect(Moves.resolve(concept: "math/unplaced/old", unit: "p1", moves: moves) == ("math/unplaced/new", "", true))
    #expect(Moves.resolve(concept: "math/unplaced/new", unit: "p1", moves: moves) == ("math/unplaced/new", "p1", false))
    var resolver = AnchorResolver(t.data, moves: moves)
    #expect(resolver.resolve(concept: "math/unplaced/old", unit: "p2") == ("math/unplaced/new", "p3", true))

    // 코멘트는 옮겨 간 문단에 "이전 판"으로 붙고, 뺀 단위의 코멘트는 어느 문단에도 붙지 않는다
    let moved = Comment(
      id: "cm-1", at: "t", by: "learner", kind: .memo, anchor: CommentAnchor(concept: "math/unplaced/old", unit: "p2", rev: 3, quote: "q"), text: "옮겨 간 문단")
    let dropped = Comment(
      id: "cm-2", at: "t", by: "learner", kind: .memo, anchor: CommentAnchor(concept: "math/unplaced/old", unit: "p1", rev: 1, quote: "q"), text: "뺀 문단")
    try CommentStore.append(t.data, moved)
    try CommentStore.append(t.data, dropped)
    let loaded = CommentStore.load(t.data)
    #expect(loaded[0].anchor == CommentAnchor(concept: "math/unplaced/new", unit: "p3", rev: 0, quote: "q"))
    #expect(loaded[1].anchor?.concept == "math/unplaced/new" && loaded[1].anchor?.unit == "")

    // 요구도 따라간다. 옮기지 않은 요구는 대상 단위가 페이지에 없어도 기다리지 않는다 (돌아서 "단위를 찾지 못했습니다"로 끝난다)
    _ = try DirectiveStore.request(t.data, op: .easy, target: DirectiveTarget(concept: "math/unplaced/old", unit: "p2", rev: 1), note: nil, fromComment: nil)
    _ = try DirectiveStore.request(t.data, op: .easy, target: DirectiveTarget(concept: "math/unplaced/old", unit: "p1", rev: 1), note: nil, fromComment: nil)
    _ = try DirectiveStore.request(t.data, op: .easy, target: DirectiveTarget(concept: "math/unplaced/new", unit: "p9", rev: 1), note: nil, fromComment: nil)
    #expect(DirectiveStore.load(t.data).map(\.target.unit) == ["p3", "", "p9"])
    #expect(DirectiveStore.load(t.data).map(\.moved) == [true, true, false])
    #expect(Regen.pending(t.data).map(\.target.unit) == ["p3", "", "p9"])

    // 다시 옮기면 끝까지 따라간다. 옮겨 간 개념의 페이지에 그 문단이 생길 때까지 그 요구는 기다린다
    try Moves.appendUnit(t.data, from: ("math/unplaced/new", "u7"), to: ("math/unplaced/third", "u2"), why: "다시 정리")
    #expect(Moves.resolve(concept: "math/unplaced/old", unit: "p2", moves: Moves.all(t.data)) == ("math/unplaced/third", "u2", true))
    #expect(Regen.pending(t.data).map(\.target.unit) == ["", "p9"])
  }

  @Test func 과목_이름을_바꾸면_꼬리표와_엔트리와_개념이_새_과목으로_간다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let pdf = t.root.appending(path: "in/a.pdf")
    SampleFiles.pdf(pdf, [.text("Some page text that is long enough for the text layer to be kept here")])
    let m = await JobManager(data: t.data, folders: t.folders)
    let request = IntakeRequest(files: [pdf], labels: SourceLabels(grade: "MYP 5", subject: "Extended Math", level: nil))
    let id = try await m.submit(config: testConfig) { try SourceIntake.prepare(request, $0) }
    _ = await m.waitForEnd(id)
    let sid = try #require(SourceLibrary.load(t.data).sources.first?.id)
    let entry = Entry(
      id: "extended-math/unplaced/logs", subject: "extended-math", item: nil, itemProposed: "Logs", title: "Logs", sources: [EntrySource(source: sid, pages: [1])],
      claims: [], symbols: [], examples: [], misconceptions: [], body: "b", recorded: "", provenance: YAMLMap([]))
    try FileOps.writeNew(entry.markdown, to: t.data.entryFile(entry.id))
    var c = try concept(t.data, "extended-math/unplaced/logs")
    c.occurrences = [Occurrence(entry: entry.id, source: entry.source, pages: [1])]
    try c.write(t.data)
    let r = try SubjectRename.run(t.data, from: "extended-math", toName: "Mathematics")
    #expect(r.sources == 1 && r.entries == 1 && r.concepts == 1)
    #expect(SourceLibrary.load(t.data).subjects.map(\.id) == ["mathematics"])
    #expect(EntryStore.all(t.data, subject: "mathematics").map(\.id) == ["mathematics/unplaced/logs"])
    let moved = ConceptStore.all(t.data, subject: "mathematics")
    #expect(moved.map(\.id) == ["mathematics/unplaced/logs"])
    #expect(moved.first?.occurrences.first?.entry == "mathematics/unplaced/logs")
    #expect(ConceptStore.all(t.data, subject: "extended-math").isEmpty)
    // 개념 정리가 이 엔트리를 다시 고르지 않는다
    let bundle = try #require(BundleStore.bundle(of: sid, in: t.data))
    #expect(ConceptCuration.pending(t.data, bundle: bundle).isEmpty)
  }

  @Test func 과목_이름을_바꿀_때_옮기거나_없앤_개념의_옛_id_는_다시_쓰지_않는다() throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    _ = try concept(t.data, "extended-math/unplaced/logs")
    // mathematics/unplaced/logs 는 예전에 다른 자리로 옮긴 개념의 id 다
    try Moves.append(t.data, kind: "concept", from: "mathematics/unplaced/logs", to: "mathematics/u1/logs", why: "목차 U1")
    _ = try SubjectRename.run(t.data, from: "extended-math", toName: "Mathematics")
    #expect(ConceptStore.all(t.data, subject: "mathematics").map(\.id) == ["mathematics/unplaced/logs-2"])
  }
}

@Suite struct SyllabusCheckTests {
  func out(_ value: Any) throws -> URL {
    let out = TempPlace().root.appending(path: "out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value).write(to: out.appending(path: "syllabus.json"))
    return out
  }

  @Test func 코드가_겹치거나_쓰인_코드가_사라지거나_없는_쪽을_달면_틀린다() throws {
    let o = try out([
      "programme": "DP",
      "items": [
        ["code": "A", "title": "Space, time and motion", "src": ["20261017-aaaabbbb#p1"], "children": [["code": "A.1", "title": "Kinematics", "level": "SL+HL", "src": ["20261017-aaaabbbb#p9"]]]],
        ["code": "A", "title": "Again", "src": ["20261017-aaaabbbb#p1"], "level": "Higher"],
      ],
      "placements": [["concept": "physics/unplaced/x", "item": "B.1"]],
    ])
    let c = SyllabusBuild.check(out: o, pages: ["20261017-aaaabbbb": 3], usedCodes: ["A.2"], unplaced: ["physics/unplaced/x"])
    #expect(c.draft == nil)
    #expect(c.problems.contains { $0.contains("겹칩니다") })
    #expect(c.problems.contains { $0.contains("#p9") })
    #expect(c.problems.contains { $0.contains("Higher") })
    #expect(c.problems.contains { $0.contains("A.2") })
    #expect(c.problems.contains { $0.contains("B.1") })
  }

  @Test func 맞는_목차를_쓰고_다시_읽는다() throws {
    let o = try out([
      "programme": "MYP",
      "items": [["code": "U2", "title": "Logarithms", "level": "Extended", "src": ["20261017-aaaabbbb#p1"], "myp": ["key_concept": "Form", "related_concepts": ["Equivalence"], "statement_of_inquiry": "Equivalent forms help."]]],
      "placements": [["concept": "math/unplaced/logs", "item": "u2"]],
    ])
    let c = SyllabusBuild.check(out: o, pages: ["20261017-aaaabbbb": 3], usedCodes: [], unplaced: ["math/unplaced/logs"])
    #expect(c.problems.isEmpty, "\(c.problems)")
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let draft = try #require(c.draft)
    try Syllabus(subject: "math", programme: draft.programme, sources: [("20261017-aaaabbbb", "Unit plan")], tree: draft.tree).write(t.data)
    let s = try #require(Syllabus.load(t.data, subject: "math"))
    #expect(s.items.map(\.code) == ["U2"])
    #expect(s.item("u2")?.myp?.keyConcept == "Form")
    #expect(s.confirmed == nil)
  }
}

@Test func plainText() {
  #expect(TexText.plain(#"The **quotient law**: \(\log\left(\frac{a}{b}\right) = \log a - \log b\)"#) == "The quotient law: log(a/b) = log a - log b")
  #expect(TexText.plain(#"\(2^{5} \times 2^3\)"#) == "2^5 × 2^3")
}

@MainActor @Test func readableSourceRefs() async throws {
  let t = TempPlace()
  try t.data.initialize(app: testApp)
  let pdf = t.root.appending(path: "inbox/Laws_of_indices.pdf")
  SampleFiles.pdf(pdf, [.text("Only a page with enough words to be text layer okay")])
  var config = testConfig
  config.claudeToken = ""
  let m = JobManager(data: t.data, folders: t.folders)
  let request = IntakeRequest(files: [pdf], labels: SourceLabels(grade: nil, subject: "Math", level: nil))
  _ = try await m.submit(config: config) { try SourceIntake.prepare(request, $0) }
  await m.waitUntilIdle()
  let library = SourceLibrary.load(t.data)
  let id = try #require(library.sources.first?.id)
  #expect(PageComposer.readableRefs("근거는 `\(id)#p1` 이다. \(id) 전체.", library: library) == "근거는 「Laws of indices」 1쪽 이다. 「Laws of indices」 전체.")
  #expect(PageComposer.readableRefs("20990101-deadbeef#p2", library: library) == "20990101-deadbeef#p2")
}

@Test func searchExcerpt() {
  let long = String(repeating: "word ", count: 40) + "\u{1}key\u{2}" + String(repeating: " tail", count: 60)
  let e = SearchMark.excerpt(long)
  #expect(e.hasPrefix("…") && e.hasSuffix("…") && e.contains("\u{1}key\u{2}"))
  #expect(e.count <= 182)
  #expect(SearchMark.excerpt("short \u{1}hit\u{2} text") == "short \u{1}hit\u{2} text")
}

@Test func asciiMathInProse() {
  #expect(!TexText.asciiMath("The value is 7^(-1) = 1/7, so log_7(1/7) = -1.", field: "caption").isEmpty)
  #expect(!TexText.asciiMath("so log_8 of the root is a half", field: "caption").isEmpty)
  #expect(TexText.asciiMath(#"The value is \(7^{-1} = \frac{1}{7}\), so \(\log_7 \frac{1}{7} = -1\)."#, field: "caption").isEmpty)
  #expect(TexText.asciiMath("Press the `x^2` key, then the ^ key.", field: "text").isEmpty)
}

@Suite struct SchemaTests {
  let set = SchemaSet(repoRoot.appending(path: "schemas/\(CurrentSchema.version)"))

  @Test func 틀린_모양을_잡는다() throws {
    #expect(set.kinds.contains("page") && set.kinds.contains("syllabus"))
    let bad = try YAML.parse(
      """
      kind: "page"
      v: 1
      concept: "m/unplaced/x"
      title_ko: null
      next_id: 0
      units:
        - { id: "x1", rev: 1, kind: "poem", from: "u1@a", prov: "source" }
      provenance: {}
      extra: 1
      """)
    let issues = set.validate(bad, label: "page.yaml")
    #expect(issues.contains { $0.contains("next_id") })
    #expect(issues.contains { $0.contains("units[0].id") })
    #expect(issues.contains { $0.contains("units[0].kind") })
    #expect(issues.contains { $0.contains("extra") })
    #expect(set.validate(try YAML.parse("kind: \"poem\"\nv: 1\n"), label: "x").first?.contains("스키마가 없습니다") == true)
    // 목차의 재귀 항목
    let syllabus = try YAML.parse(
      """
      kind: "syllabus"
      v: 1
      subject: "physics"
      programme: "DP"
      sources: []
      items:
        - { code: "A", title: "Space", children: [{ code: "A.1", title: "Kinematics", children: [{ code: 3 }] }] }
      confirmed: null
      provenance: {}
      """)
    #expect(set.validate(syllabus, label: "s").count == 2)
  }
}
