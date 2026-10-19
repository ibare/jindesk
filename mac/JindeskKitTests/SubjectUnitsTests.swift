import Foundation
import Testing
@testable import JindeskKit

// 과목 목록의 단원과 하루 안에 정리된 개념 (DECISIONS.md 39)
@Suite struct SubjectUnitsTests {
  func concept(_ id: String, proposed: String? = nil, job: String? = nil) -> Concept {
    Concept(
      cid: ConceptID(id)!, title: "T", itemProposed: proposed, occurrences: [], symbols: [], nextID: 1, units: [],
      provenance: job.map { YAMLMap([("job", .string($0))]) } ?? YAMLMap([]))
  }

  @Test func 단원은_이름의_알파벳순이고_단원_제안이_없으면_목차_밖이다() {
    let concepts = [
      concept("math/unplaced/log-form", proposed: "Logarithms"),
      concept("math/unplaced/growth", proposed: "Exponential growth and decay"),
      concept("math/unplaced/evaluate", proposed: "Command terms"),
      concept("math/unplaced/change-of-base", proposed: "Logarithms"),
      concept("math/unplaced/loose"),
    ]
    let units = SubjectUnits.make(concepts, syllabus: nil)
    #expect(units.map(\.name) == ["Command terms", "Exponential growth and decay", "Logarithms", "목차 밖"])
    #expect(units.map(\.key) == ["proposed:Command terms", "proposed:Exponential growth and decay", "proposed:Logarithms", "proposed:목차 밖"])
    #expect(units[2].concepts.map(\.id) == ["math/unplaced/log-form", "math/unplaced/change-of-base"])
    #expect(SubjectUnits.key(concepts[3], syllabus: nil) == "proposed:Logarithms")
    #expect(SubjectUnits.key(concepts[4], syllabus: nil) == "proposed:목차 밖")
  }

  @Test func 목차가_있으면_개념이_있는_항목만_단원이고_목차_밖_단원에는_앞말을_붙인다() {
    let syllabus = Syllabus(
      subject: "math", programme: "MYP", sources: [],
      tree: [SyllabusItem(code: "B.1", title: "Statistics"), SyllabusItem(code: "A.2", title: "Logarithms"), SyllabusItem(code: "C.1", title: "Vectors")])
    let concepts = [
      concept("math/b.1/quartiles"),
      concept("math/a.2/laws"),
      concept("math/unplaced/surds", proposed: "Surds"),
    ]
    let units = SubjectUnits.make(concepts, syllabus: syllabus)
    #expect(units.map(\.name) == ["A.2 Logarithms", "B.1 Statistics", "목차 밖 · Surds"])
    #expect(units.map(\.key) == ["item:A.2", "item:B.1", "proposed:Surds"])
    #expect(SubjectUnits.key(concepts[0], syllabus: syllabus) == "item:B.1")
  }

  @Test func 정리한_작업이_24시간_안이면_새_개념이다() throws {
    let now = try #require(JobID.date("20261019-1200-now"))
    #expect(JobID.stamp(now) == "20261019-1200")
    #expect(concept("math/unplaced/a", job: "20261019-0930-curate-x").isNew(now: now))
    #expect(concept("math/unplaced/b", job: "20261018-1201-curate-x").isNew(now: now))
    #expect(!concept("math/unplaced/c", job: "20261018-1200-curate-x").isNew(now: now))
    #expect(!concept("math/unplaced/d").isNew(now: now))
    #expect(JobID.date("curate-x") == nil)
  }
}
