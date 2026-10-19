import Foundation
import Testing
@testable import JindeskKit

// 단원 개요 (DECISIONS.md 34): 고른 주장, 상자, 풀이, 용어, 기호, 레퍼런스, 관점을 모은다. 지어낸 Statistics 단원.
@Suite struct UnitDigestTests {
  func claim(_ id: String, _ text: String, _ page: Int) -> UnitClaim { UnitClaim(id: id, text: text, src: ["20261018-61ab06a5#p\(page)"]) }

  func place() throws -> (TempPlace, [Concept]) {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    var quartiles = Concept(
      cid: ConceptID("math/unplaced/quartiles")!, title: "Quartiles", itemProposed: "Statistics", occurrences: [],
      symbols: [SymbolDef(symbol: "\\(Q_1\\)", meaning: "the lower quartile (LQ)")], nextID: 3,
      units: [
        ConceptUnit(
          id: "u1", text: "Quartiles divide an ordered data set into 4 even quarters. The lower quartile is the middle of the lower half.", conditions: [],
          claims: [claim("c1", "Quartiles divide an ordered data set into 4 even quarters.", 28)]),
        ConceptUnit(id: "u2", text: "Q1.", conditions: [], claims: [claim("c1", "\\(Q_1\\) is the lower quartile (LQ).", 33), claim("c2", "\\(Q_2\\) is the median.", 32)]),
      ], provenance: YAMLMap([]))
    quartiles.prerequisites = []
    let spread = Concept(
      cid: ConceptID("math/unplaced/measures-of-spread")!, title: "Measures of spread", itemProposed: "Statistics", occurrences: [],
      symbols: [SymbolDef(symbol: "\\(Q_1\\)", meaning: "the lower quartile"), SymbolDef(symbol: "IQR", meaning: "the interquartile range")], nextID: 2,
      units: [
        ConceptUnit(
          id: "u1", text: "The interquartile range is the gap between the LQ and the UQ.", conditions: [],
          claims: [claim("c1", "The interquartile range is the gap between the LQ and the UQ.", 45)])
      ], provenance: YAMLMap([]))
    for c in [quartiles, spread] { try c.write(t.data) }
    let qf = ConceptFolder(quartiles.cid, in: t.data)
    try ConceptFacets(
      concept: quartiles.id, from: "", item: nil, level: nil, commandTerms: ["State", "Compare"], keyConcepts: ["Relationships"],
      relatedConcepts: ["Representation"], globalContexts: [], nos: [], tok: ["Mathematics"], summary: ["u1.c1", "u2.c1", "u9.c9"], formulas: [],
      provenance: YAMLMap([])
    ).write(qf)
    try ConceptFacets(
      concept: spread.id, from: "", item: nil, level: nil, commandTerms: ["Calculate", "Compare"], keyConcepts: ["Relationships"], relatedConcepts: [],
      globalContexts: [], nos: [], tok: ["Mathematics"], summary: ["u1.c1"], formulas: ["u1.c1"], provenance: YAMLMap([])
    ).write(ConceptFolder(spread.cid, in: t.data))
    try Page(
      concept: quartiles.id, titleKo: "사분위수", nextID: 5,
      units: [
        PageUnit(id: "p1", rev: 1, kind: .para, from: "u1@x", prov: "source", text: "Quartiles divide…"),
        PageUnit(id: "n2", rev: 1, kind: .note, from: "u1@x", prov: "source", text: "With an odd number of values, do not put the median into either half.", note: .misconception),
        PageUnit(id: "b3", rev: 1, kind: .block, from: "u1@x", prov: "source", block: YAMLMap([("type", .string("derivation")), ("title", .string("Quartiles of 12 ordered values"))])),
        PageUnit(id: "q4", rev: 1, kind: .check, from: "u1@x", prov: "added", text: "Find the quartiles."),
      ], provenance: YAMLMap([])
    ).write(qf)
    try Page(
      concept: spread.id, titleKo: "산포도", nextID: 2,
      units: [
        PageUnit(id: "n1", rev: 1, kind: .note, from: "u1@x", prov: "source", text: "\"Calculate\" asks for a numerical answer with the working shown.", note: .commandTerm)
      ], provenance: YAMLMap([])
    ).write(ConceptFolder(spread.cid, in: t.data))
    try Glossary(terms: [
      GlossaryTerm(en: "lower quartile", ko: "하위 사분위수", subjects: ["math"]), GlossaryTerm(en: "interquartile range", ko: "사분위수 범위", subjects: ["math"]),
      GlossaryTerm(en: "mode", ko: "최빈값", subjects: ["math"]), GlossaryTerm(en: "velocity", ko: "속도", subjects: ["physics"]),
    ]).write(t.data)
    var refs = References(concepts: [:])
    refs.concepts[quartiles.id] = ("job", [Reference(url: "https://example.com/q", title: "Quartiles (Math is Fun)", kind: "article", why: "Shows quartiles.")])
    try refs.write(t.data)
    return (t, [quartiles, spread])
  }

  @Test func 고른_주장을_글_그대로_모으고_없는_id_는_건너뛴다() throws {
    let (t, concepts) = try place()
    let d = UnitDigest.make(t.data, concepts: concepts)
    #expect(d.concepts.map(\.titleKo) == ["사분위수", "산포도"])
    #expect(d.concepts[0].lines.map(\.text) == ["Quartiles divide an ordered data set into 4 even quarters.", "\\(Q_1\\) is the lower quartile (LQ)."])
    #expect(d.concepts[0].lines[1].src == ["20261018-61ab06a5#p33"])
    #expect(d.concepts[0].checks == 1 && d.unpicked == 0)
    #expect(d.formulas.map(\.line.text) == ["The interquartile range is the gap between the LQ and the UQ."])
  }

  @Test func 상자와_풀이_용어_기호_레퍼런스_관점을_모은다() throws {
    let (t, concepts) = try place()
    let d = UnitDigest.make(t.data, concepts: concepts)
    #expect(d.mistakes.map(\.text) == ["With an odd number of values, do not put the median into either half."])
    #expect(d.workings.map(\.title) == ["Quartiles of 12 ordered values"])
    // 글에 나오는 이 과목의 용어만 (mode 는 글에 없고 velocity 는 다른 과목)
    #expect(d.terms.map(\.en) == ["interquartile range", "lower quartile"])
    #expect(d.symbols.map(\.symbol) == ["\\(Q_1\\)", "IQR"])
    #expect(d.symbols[0].concepts.count == 2)
    #expect(d.references.map(\.reference.title) == ["Quartiles (Math is Fun)"])
    #expect(d.keyConcepts == [UnitDigest.Tag(value: "Relationships", count: 2)])
    #expect(d.commandTerms.map(\.term) == ["Compare", "Calculate", "State"])
    #expect(d.commandTerms[1].notes.count == 1 && d.commandTerms[1].definition?.term == "Calculate")
  }

  @Test func 출처를_자료와_쪽으로_나눈다() {
    let p = UnitDigest.pages(["s1#p33", "s1#p35", "s2#p4", "s1#p33"])
    #expect(p.map(\.source) == ["s1", "s2"])
    #expect(p.map(\.pages) == [[33, 35], [4]])
  }
}
