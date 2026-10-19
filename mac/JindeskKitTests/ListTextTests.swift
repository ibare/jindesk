import Foundation
import Testing
@testable import JindeskKit

// 목록 칸에 보일 글과 차례 (DECISIONS.md 32)
@Suite struct ListTextTests {
  @Test func 이름은_콜론_앞과_뒤로_나눈다() {
    #expect(TitleParts("Measures of central tendency: mean, median and mode") == TitleParts(head: "Measures of central tendency", tail: "mean, median and mode"))
    #expect(TitleParts("대푯값: 평균, 중앙값, 최빈값").head == "대푯값")
    #expect(TitleParts("Quartiles") == TitleParts(head: "Quartiles", tail: nil))
    // 콜론이 맨 앞이나 맨 끝이면 나누지 않는다
    #expect(TitleParts("Ratio 3:2").tail == "2")
    #expect(TitleParts("Note:") == TitleParts(head: "Note:", tail: nil))
  }

  @Test func 목록의_수식은_첨자를_글자로_바꾼다() {
    #expect(TexText.display(#"Class A has \(Q_1 = 52\) and \(Q_{3} = 70\)."#) == "Class A has Q₁ = 52 and Q₃ = 70.")
    #expect(TexText.display(#"\(x^2 + 10^{-3}\)"#) == "x² + 10⁻³")
    #expect(TexText.display(#"\(\text{LQ} = 7.5\)"#) == "LQ = 7.5")
    // 찾기 색인의 글은 그대로다
    #expect(TexText.plain(#"\(Q_1\)"#) == "Q_1")
  }

  @Test func 쪽은_처음과_끝으로_보이고_자료가_여럿이면_수를_보인다() {
    let a = Occurrence(entry: "e1", source: "s1", pages: [14, 12, 13, 24])
    let b = Occurrence(entry: "e2", source: "s2", pages: [7])
    #expect(Occurrence.pagesLabel([a]) == "12–24쪽")
    #expect(Occurrence.pagesLabel([b]) == "7쪽")
    #expect(Occurrence.pagesLabel([a, b]) == "자료 2개")
    #expect(Occurrence.pagesLabel([a, b], source: "s2") == "7쪽")
    #expect(Occurrence.pagesLabel([]) == nil)
  }

  @Test func 배우는_순서는_선수_개념이_먼저다() {
    func concept(_ id: String, pre: [String] = []) -> Concept {
      var c = Concept(cid: ConceptID(id)!, title: id, itemProposed: nil, occurrences: [], symbols: [], nextID: 1, units: [], provenance: YAMLMap([]))
      c.prerequisites = pre
      return c
    }
    // 목록에 놓인 차례(가나다)와 상관없이 선수 개념부터
    let concepts = [
      concept("math/unplaced/central", pre: ["math/unplaced/types"]),
      concept("math/unplaced/spread", pre: ["math/unplaced/central", "math/unplaced/quartiles"]),
      concept("math/unplaced/quartiles", pre: ["math/unplaced/central"]),
      concept("math/unplaced/types"),
    ]
    let map = ConceptMap(subject: "math", concepts: concepts, all: concepts)
    #expect(map.learningOrder() == ["math/unplaced/types", "math/unplaced/central", "math/unplaced/quartiles", "math/unplaced/spread"])
  }
}

// 모아 보기의 A–Z (DECISIONS.md 34)
@Suite struct AlphaIndexTests {
  @Test func 첫_글자로_묶고_숫자와_그_밖은_따로_둔다() {
    #expect(AlphaIndex.letter("interquartile range") == "I")
    #expect(AlphaIndex.letter("\\(Q_1\\)") == "Q")
    #expect(AlphaIndex.letter("\\(\\sigma\\)") == "•")
    #expect(AlphaIndex.letter("σ") == "•")
    #expect(AlphaIndex.letter("1. Measures of Central Tendency") == "#")
    #expect(AlphaIndex.letter("사분위수") == "•")
    let s = AlphaIndex.sections(["mode", "Mean", "IQR", "median", "1. Slides", "σ"]) { $0 }
    #expect(s.map(\.letter) == ["I", "M", "#", "•"])
    #expect(s[1].items == ["Mean", "median", "mode"])
  }
}
