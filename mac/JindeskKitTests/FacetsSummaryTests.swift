import Foundation
import Testing
@testable import JindeskKit

// 한 장 요약과 공식 고르기 (DECISIONS.md 34): 새 문장 없이 개념 원문의 주장 id 만 고른다
@Suite struct FacetsSummaryTests {
  func concept() -> Concept {
    let c = { (id: String, text: String, page: Int) in UnitClaim(id: id, text: text, src: ["20261018-61ab06a5#p\(page)"]) }
    return Concept(
      cid: ConceptID("math/unplaced/quartiles")!, title: "Quartiles", itemProposed: "Statistics", occurrences: [], symbols: [], nextID: 4,
      units: [
        ConceptUnit(id: "u1", text: "Quartiles divide an ordered data set into 4 even quarters.", conditions: [], claims: [c("c1", "Quartiles divide an ordered data set into 4 even quarters.", 28)]),
        ConceptUnit(
          id: "u2", text: "Three values make the cuts.", conditions: [],
          claims: [c("c1", "\\(Q_1\\) is the lower quartile (LQ).", 33), c("c2", "\\(Q_2\\) is the median.", 32), c("c3", "\\(Q_3\\) is the upper quartile (UQ).", 34)]),
        ConceptUnit(id: "u3", text: "Again.", conditions: [], claims: [c("c1", "Quartiles divide an ordered data set into 4 even quarters.", 35)]),
      ], provenance: YAMLMap([]))
  }

  func facets(_ t: TempPlace, _ body: String) throws -> FacetsCheck {
    try t.write("out/facets.json", body)
    let checked = Facets.check(out: t.data.url.appending(path: "out"), keys: ["k01"], concepts: ["k01": concept()])
    return FacetsCheck(values: checked.values["k01"], problems: checked.problems)
  }

  struct FacetsCheck {
    let values: Facets.Values?
    let problems: [String]
  }

  let base = #""command_terms": ["State"], "key_concepts": [], "related_concepts": [], "global_contexts": [], "nos": [], "tok": []"#

  @Test func 그_개념의_주장_id_를_고르면_받는다() throws {
    let r = try facets(TempPlace(), #"{"concepts": {"k01": {"# + base + #", "summary": ["u1.c1", "u2.c1", "u2.c2", "u2.c3"], "formulas": ["u2.c1"]}}}"#)
    #expect(r.problems.isEmpty)
    #expect(r.values?.summary == ["u1.c1", "u2.c1", "u2.c2", "u2.c3"])
    #expect(r.values?.formulas == ["u2.c1"])
    #expect(concept().claim("u2.c3")?.src == ["20261018-61ab06a5#p34"])
  }

  @Test func 없는_주장이나_같은_글을_두_번_고르면_고쳐_쓰게_한다() throws {
    let r = try facets(TempPlace(), #"{"concepts": {"k01": {"# + base + #", "summary": ["u1.c1", "u3.c1", "u9.c1"], "formulas": []}}}"#)
    #expect(r.problems.contains { $0.contains("u9.c1") && $0.contains("그 개념의 주장이 아닙니다") })
    #expect(r.problems.contains { $0.contains("같은 주장을 두 번") })
    #expect(r.values?.summary == ["u1.c1"])
  }

  @Test func 요약은_3개에서_6개다() throws {
    let r = try facets(TempPlace(), #"{"concepts": {"k01": {"# + base + #", "summary": ["u1.c1"], "formulas": []}}}"#)
    #expect(r.problems.contains { $0.contains("summary: 3~6개") })
  }

  @Test func 요약을_고르지_않은_관점은_다시_붙인다() throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    try concept().write(t.data)
    let folder = ConceptFolder(concept().cid, in: t.data)
    let hash = ConceptStore.fileHash(t.data, id: concept().cid) ?? ""
    var f = ConceptFacets(
      concept: concept().id, from: hash, item: nil, level: nil, commandTerms: [], keyConcepts: [], relatedConcepts: [], globalContexts: [], nos: [], tok: [],
      provenance: YAMLMap([]))
    try f.write(folder)
    #expect(Facets.pendingFacets(t.data, subject: "math").map(\.id) == [concept().id])
    f.summary = ["u1.c1", "u2.c1", "u2.c2"]
    f.formulas = []
    try f.write(folder)
    #expect(ConceptFacets.load(folder)?.summary == ["u1.c1", "u2.c1", "u2.c2"])
    #expect(Facets.pendingFacets(t.data, subject: "math").isEmpty)
  }

  @Test func 스키마_1_의_관점을_판_2_로_올린다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    try SchemaFile(schema: 1, created: "2026-10-01T00:00:00+04:00", lastOpenedBy: testApp, history: []).write(to: t.data)
    try t.write(
      "library/unplaced/math/quartiles/facets.yaml",
      "kind: \"facets\"\nv: 1\nconcept: \"math/unplaced/quartiles\"\nfrom: \"abc\"\nitem: null\nlevel: null\ncommand_terms: []\nkey_concepts: []\nrelated_concepts: []\nglobal_contexts: []\nnos: []\ntok: []\nprovenance: {}\n"
    )
    try t.write("library/facets.yaml", "kind: \"facet-vocab\"\nv: 1\nrelated_concepts: {}\nnos: {}\n")
    let report = try await Migrator(data: t.data, folders: t.folders, app: testApp).migrate()
    #expect(report.from == 1 && report.to == 2)
    #expect(report.checks == ["검증 통과"])
    let v = try YAML.read(t.data.library.appending(path: "unplaced/math/quartiles/facets.yaml"))
    #expect(v["v"]?.int == 2)
    #expect(v["summary"] == nil)
    #expect(try YAML.read(t.data.library.appending(path: "facets.yaml"))["v"]?.int == 1)
  }

  @Test func 명령어_목록의_말은_모두_정의가_있다() {
    #expect(FacetVocabulary.commandTerms.allSatisfy { CommandTerms.lookup($0) != nil })
    #expect(CommandTerms.lookup("compare")?.definition.hasPrefix("Give an account of the similarities") == true)
  }
}
