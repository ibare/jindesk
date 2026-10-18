import Foundation
import Testing
@testable import JindeskKit

@Suite struct ConceptMapTests {
  func concept(_ id: String, _ title: String = "T", pre: [String] = [], job: String? = nil, proposed: String? = nil) -> Concept {
    var c = Concept(
      cid: ConceptID(id)!, title: title, itemProposed: proposed, occurrences: [], symbols: [], nextID: 1, units: [],
      provenance: job.map { YAMLMap([("job", .string($0))]) } ?? YAMLMap([]))
    c.prerequisites = pre
    return c
  }

  // 지어낸 Physics 개념: 변위 → 가속도 → 등가속도 → 투사체, 힘 → 제2법칙, 다른 과목 벡터와 아직 없는 삼각비
  var physics: [Concept] {
    [
      concept("physics/a.1/displacement", "Displacement", job: "20261018-0900-curate-physics"),
      concept("physics/a.1/acceleration", "Acceleration", pre: ["physics/a.1/displacement"]),
      concept("physics/a.1/suvat", "SUVAT", pre: ["physics/a.1/acceleration"]),
      concept("physics/a.1/projectile", "Projectile motion", pre: ["physics/a.1/suvat", "missing:Trigonometric ratios"]),
      concept("physics/a.2/forces", "Forces", pre: ["math/ahl-3.10/vectors"]),
      concept("physics/a.2/second-law", "Second law", pre: ["physics/a.1/acceleration", "physics/a.2/forces"]),
    ]
  }
  let math = [ConceptMapTestsSupport.vectors]

  @Test func 선수_개념이_간선이고_다음_개념은_거꾸로_찾는다() {
    let map = ConceptMap(subject: "physics", concepts: physics, all: physics + math)
    #expect(map.conceptCount == 6)
    #expect(map.prerequisites(of: "physics/a.2/second-law") == ["physics/a.1/acceleration", "physics/a.2/forces"])
    #expect(Set(map.next(of: "physics/a.1/acceleration")) == ["physics/a.1/suvat", "physics/a.2/second-law"])
    #expect(map.node("missing:Trigonometric ratios")?.kind == .missing)
    #expect(map.node("missing:Trigonometric ratios")?.title == "Trigonometric ratios")
    #expect(map.node("math/ahl-3.10/vectors")?.kind == .other(subject: "math"))
    #expect(map.node("math/ahl-3.10/vectors")?.title == "Vectors")
    #expect(map.missingCount == 1)
    #expect(map.linkCount == 7)
    #expect(map.node("physics/a.1/displacement")?.curatedOn == "20261018")
    #expect(map.node("physics/a.1/acceleration")?.curatedOn == nil)
  }

  @Test func 다른_과목_개념을_끄면_노드는_빠지고_연결_수는_그대로다() {
    let map = ConceptMap(subject: "physics", concepts: physics, all: physics + math, showOthers: false)
    #expect(map.node("math/ahl-3.10/vectors") == nil)
    #expect(map.hiddenLinks == 1)
    #expect(map.linkCount == 7)
    #expect(map.prerequisites(of: "physics/a.2/forces").isEmpty)
  }

  @Test func 찾지_못한_개념_id_는_아직_없는_개념이다() {
    let cs = [concept("physics/a.1/x", pre: ["physics/a.1/deleted", "physics/a.1/x"])]
    let map = ConceptMap(subject: "physics", concepts: cs, all: cs)
    #expect(map.node("physics/a.1/deleted")?.kind == .missing)
    // 자기 자신은 선수 개념으로 치지 않는다
    #expect(map.edges == [ConceptMap.Edge(from: "physics/a.1/deleted", to: "physics/a.1/x")])
  }

  @Test func 거슬러_올라가는_개념과_이어지는_개념과_단계() {
    let map = ConceptMap(subject: "physics", concepts: physics, all: physics + math)
    #expect(
      map.ancestors(of: "physics/a.1/projectile") == ["physics/a.1/suvat", "physics/a.1/acceleration", "physics/a.1/displacement", "missing:Trigonometric ratios"])
    #expect(map.descendants(of: "physics/a.1/acceleration") == ["physics/a.1/suvat", "physics/a.1/projectile", "physics/a.2/second-law"])
    #expect(map.depth(of: "physics/a.1/projectile") == 3)
    #expect(map.depth(of: "physics/a.1/displacement") == 0)
  }

  @Test func 칸은_선수_개념의_겹수이고_밖의_개념은_다음_개념_바로_앞이다() {
    let map = ConceptMap(subject: "physics", concepts: physics, all: physics + math)
    let L = map.layers()
    #expect(L["physics/a.1/displacement"] == 0)
    #expect(L["physics/a.1/acceleration"] == 1)
    #expect(L["physics/a.2/second-law"] == 2)
    #expect(L["physics/a.1/projectile"] == 3)
    // 힘은 다음 개념(제2법칙) 바로 앞으로 당겨지고, 벡터(다른 과목)는 그 앞에 선다
    #expect(L["physics/a.2/forces"] == 1)
    #expect(L["math/ahl-3.10/vectors"] == 0)
    #expect(L["missing:Trigonometric ratios"] == 2)
  }

  @Test func 선수_개념이_없는_개념은_가장_이른_다음_개념_바로_앞으로_당긴다() {
    let cs = [
      concept("p/a.1/a"), concept("p/a.1/b", pre: ["p/a.1/a"]), concept("p/a.1/c", pre: ["p/a.1/b"]),
      concept("p/a.1/late"), concept("p/a.1/d", pre: ["p/a.1/c", "p/a.1/late"]),
    ]
    let L = ConceptMap(subject: "p", concepts: cs, all: cs).layers()
    #expect(L["p/a.1/late"] == 2)
    #expect(L["p/a.1/d"] == 3)
  }

  @Test func 밖의_개념이_0칸_앞에_서야_하면_모두_한_칸씩_민다() {
    let cs = [concept("physics/a.2/forces", pre: ["math/ahl-3.10/vectors"]), concept("physics/a.2/laws", pre: ["physics/a.2/forces"])]
    let L = ConceptMap(subject: "physics", concepts: cs, all: cs + math).layers()
    #expect(L == ["math/ahl-3.10/vectors": 0, "physics/a.2/forces": 1, "physics/a.2/laws": 2])
  }

  @Test func 배우는_순서에서는_한_칸_안의_노드가_겹치지_않는다() {
    let map = ConceptMap(subject: "physics", concepts: physics, all: physics + math)
    let layout = map.layout(.learning)
    #expect(layout.places.count == map.nodes.count)
    #expect(layout.columns == 4)
    for col in 0..<layout.columns {
      let rows = layout.places.values.filter { $0.column == col }.map(\.row).sorted()
      for (a, b) in zip(rows, rows.dropFirst()) { #expect(b - a >= 1 - 1e-9) }
    }
    #expect(layout.places.values.map(\.row).min() == 0)
    // 선수 개념이 하나뿐이면 그 높이에 놓인다
    #expect(layout.places["physics/a.1/acceleration"]?.row == layout.places["physics/a.1/displacement"]?.row)
  }

  @Test func 목차대로는_목차_차례의_칸이고_밖의_개념은_맨_앞_목차_밖은_맨_뒤다() {
    let cs = physics + [concept("physics/unplaced/energy", "Energy", proposed: "Energy")]
    let syllabus = Syllabus(
      subject: "physics", programme: nil, sources: [],
      tree: [SyllabusItem(code: "A", title: "Space", children: [SyllabusItem(code: "A.2", title: "Forces"), SyllabusItem(code: "A.1", title: "Kinematics")])])
    let layout = ConceptMap(subject: "physics", concepts: cs, all: cs + math).layout(.syllabus, syllabus: syllabus)
    #expect(layout.headers == [.outside, .item("a.2"), .item("a.1"), .unplaced("Energy")])
    #expect(layout.places["math/ahl-3.10/vectors"]?.column == 0)
    #expect(layout.places["physics/a.2/forces"] == .init(column: 1, row: 0))
    #expect(layout.places["physics/a.2/second-law"] == .init(column: 1, row: 1))
    #expect(layout.places["physics/a.1/displacement"] == .init(column: 2, row: 0))
    #expect(layout.places["physics/a.1/projectile"] == .init(column: 2, row: 3))
    #expect(layout.places["physics/unplaced/energy"]?.column == 3)
    #expect(layout.rows == 4)
  }

  @Test func 선수_관계가_돌아_이어져도_멈추지_않고_배치한다() {
    let cs = [concept("p/a.1/a", pre: ["p/a.1/c"]), concept("p/a.1/b", pre: ["p/a.1/a"]), concept("p/a.1/c", pre: ["p/a.1/b"])]
    let map = ConceptMap(subject: "p", concepts: cs, all: cs)
    let layout = map.layout(.learning)
    #expect(layout.places.count == 3)
    #expect(map.ancestors(of: "p/a.1/a") == ["p/a.1/b", "p/a.1/c"])
    #expect(map.depth(of: "p/a.1/a") >= 2)
    #expect(map.layout(.syllabus).places.count == 3)
  }

  @Test func 앞뒤_개념은_바로_앞과_바로_다음만이고_너머의_수를_센다() {
    let all = physics + math
    let a = ConceptMap.neighborhood(of: physics[1], all: all)
    #expect(a.before.map(\.node.id) == ["physics/a.1/displacement"])
    #expect(a.before.map(\.beyond) == [0])
    #expect(a.after.map(\.node.id) == ["physics/a.1/suvat", "physics/a.2/second-law"])
    // 등가속도 다음에는 투사체가 더 이어진다
    #expect(a.after.map(\.beyond) == [1, 0])
    // 아직 없는 개념은 누를 수 없는 노드이고 너머가 없다
    let p = ConceptMap.neighborhood(of: physics[3], all: all)
    #expect(p.before.map(\.node.kind) == [.concept, .missing])
    #expect(p.before.map(\.node.title) == ["SUVAT", "Trigonometric ratios"])
    #expect(p.before.map(\.beyond) == [1, 0])
    #expect(p.after.isEmpty)
  }

  @Test func 앞뒤_개념에는_다른_과목도_앞뒤_모두_들고_이_과목_개념이_먼저다() {
    let components = concept("math/ahl-3.10/components", pre: ["math/ahl-3.10/vectors"])
    let all = physics + math + [components]
    let f = ConceptMap.neighborhood(of: physics[4], all: all)
    #expect(f.before.map(\.node.kind) == [.other(subject: "math")])
    #expect(f.before.map(\.node.title) == ["Vectors"])
    // 벡터에서 보면 물리의 힘이 다음 개념이다. 수학 개념이 앞에 선다
    let v = ConceptMap.neighborhood(of: ConceptMapTestsSupport.vectors, all: all)
    #expect(v.before.isEmpty)
    #expect(v.after.map(\.node.id) == ["math/ahl-3.10/components", "physics/a.2/forces"])
    #expect(v.after.map(\.node.kind) == [.concept, .other(subject: "physics")])
    #expect(v.after.map(\.beyond) == [0, 1])
  }

  @Test func 앞뒤_개념에서_겹친_선수_개념과_자기_자신은_한_번도_세지_않는다() {
    let cs = [concept("p/a.1/a"), concept("p/a.1/b", pre: ["p/a.1/a", "p/a.1/a", "p/a.1/b"])]
    let b = ConceptMap.neighborhood(of: cs[1], all: cs)
    #expect(b.before.map(\.node.id) == ["p/a.1/a"])
    #expect(b.after.isEmpty)
    #expect(ConceptMap.neighborhood(of: cs[0], all: cs).after.map(\.node.id) == ["p/a.1/b"])
  }

  @Test func 페이지_조합에_앞뒤_개념이_들고_아직_없는_개념은_누를_id_가_없다() {
    let all = physics + math
    func page(_ c: Concept) -> JSONValue {
      PageComposer.json(
        PageComposer.Input(concept: c, page: nil, layers: nil, glossary: Glossary(), library: SourceLibrary(sources: []), subjectName: "Physics", all: all))
    }
    let p = page(physics[3])
    #expect(p["code"]?.stringValue == "A.1")
    let before = p["before"]?.arrayValue ?? []
    #expect(before.map { $0["kind"]?.stringValue } == ["concept", "missing"])
    #expect(before[0]["id"]?.stringValue == "physics/a.1/suvat")
    #expect(before[0]["code"]?.stringValue == "A.1")
    #expect(before[0]["beyond"]?.numberValue == 1)
    #expect(before[0]["hasPage"]?.boolValue == false)
    #expect(before[1]["id"] == nil)
    #expect(before[1]["missing"]?.boolValue == true)
    #expect(p["after"]?.arrayValue?.isEmpty == true)
    // 다른 과목 개념은 과목 이름을 단다 (과목 목록에 없으면 과목 id)
    let f = page(physics[4])
    #expect(f["before"]?.arrayValue?.first?["kind"]?.stringValue == "other")
    #expect(f["before"]?.arrayValue?.first?["subject"]?.stringValue == "math")
    #expect(f["after"]?.arrayValue?.map { $0["id"]?.stringValue } == ["physics/a.2/second-law"])
  }

  @Test func 개념이_없으면_빈_지도다() {
    let map = ConceptMap(subject: "p", concepts: [], all: [])
    let layout = map.layout(.learning)
    #expect(map.nodes.isEmpty && layout.columns == 0 && layout.rows == 0)
    #expect(map.layout(.syllabus).headers.isEmpty)
  }
}

enum ConceptMapTestsSupport {
  static var vectors: Concept {
    Concept(
      cid: ConceptID("math/ahl-3.10/vectors")!, title: "Vectors", itemProposed: nil, occurrences: [], symbols: [], nextID: 1, units: [],
      provenance: YAMLMap([]))
  }
}
