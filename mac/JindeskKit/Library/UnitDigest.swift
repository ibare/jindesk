// 단원 개요 (PAGES.md 의 단원 개요, DECISIONS.md 34). 단원의 개념들(배우는 순서)에서 한 장 요약, 공식과 풀이, 용어와 기호,
// 자주 하는 실수, 더 볼 자료, IB 맥락을 모은다. 새 글을 만들지 않는다. 요약과 공식은 관점 붙이기가 고른 주장(facets.yaml 의 summary,
// formulas)을 개념 원문에서 글자 그대로 가져온다. 개념이 바뀌어 없어진 id 는 건너뛴다(관점 붙이기가 다시 고른다).
// 맥과 폰이 함께 쓴다.
import Foundation

public struct UnitDigest: Sendable {
  // 고른 주장 한 줄: 글과 출처 ("<자료 id>#p<쪽>")
  public struct Line: Sendable, Equatable {
    public let ref: String
    public let text: String
    public let src: [String]
  }

  public struct ConceptSummary: Sendable {
    public let concept: Concept
    public let titleKo: String?
    public let lines: [Line]
    // 학습 페이지의 핵심 생각 상자
    public let keyIdeas: [String]
    // 관점 붙이기가 요약을 골랐는지 (스키마 1 의 관점이면 아직이다)
    public let picked: Bool
    public let checks: Int
  }

  public struct Formula: Sendable {
    public let line: Line
    public let concept: Concept
  }

  // 학습 페이지의 풀이 블록 (제목)
  public struct Working: Sendable {
    public let title: String
    public let concept: Concept
  }

  public struct Mistake: Sendable {
    public let text: String
    public let concept: Concept
  }

  public struct Symbol: Sendable {
    public let symbol: String
    public let meaning: String
    public let concepts: [Concept]
  }

  public struct Ref: Sendable {
    public let reference: Reference
    public let concept: Concept
  }

  // 관점 값과 그 값이 붙은 개념 수
  public struct Tag: Sendable, Equatable {
    public let value: String
    public let count: Int
  }

  public struct TermUse: Sendable {
    public let term: String
    public let count: Int
    public let definition: CommandTerm?
    // 학습 페이지의 command term 상자 가운데 이 말을 다루는 것
    public let notes: [Mistake]
  }

  public let concepts: [ConceptSummary]
  public let formulas: [Formula]
  public let workings: [Working]
  public let terms: [GlossaryTerm]
  public let symbols: [Symbol]
  public let mistakes: [Mistake]
  public let references: [Ref]
  public let keyConcepts: [Tag]
  public let relatedConcepts: [Tag]
  public let globalContexts: [Tag]
  public let tok: [Tag]
  public let nos: [Tag]
  public let commandTerms: [TermUse]
  // 목차의 MYP 탐구 진술 (목차 항목일 때)
  public let inquiry: String?

  // 요약을 아직 고르지 않은 개념 수
  public var unpicked: Int { concepts.filter { !$0.picked }.count }

  public static func make(_ data: DataFolder, concepts: [Concept], inquiry: String? = nil) -> UnitDigest {
    let references = References.load(data)
    var summaries: [ConceptSummary] = []
    var formulas: [Formula] = []
    var workings: [Working] = []
    var mistakes: [Mistake] = []
    var termNotes: [Mistake] = []
    var symbols: [Symbol] = []
    var refs: [Ref] = []
    var tags = (key: [String: Int](), related: [String: Int](), global: [String: Int](), tok: [String: Int](), nos: [String: Int](), terms: [String: Int]())
    for c in concepts {
      let folder = ConceptFolder(c.cid, in: data)
      let page = Page.load(folder)
      let facets = ConceptFacets.load(folder)
      let line = { (ref: String) in c.claim(ref).map { Line(ref: ref, text: $0.text, src: $0.src) } }
      let notes = (page?.units ?? []).filter { $0.kind == .note }
      summaries.append(
        ConceptSummary(
          concept: c, titleKo: page?.titleKo, lines: (facets?.summary ?? []).compactMap(line),
          keyIdeas: notes.filter { $0.note == .keyIdea }.compactMap(\.text), picked: facets?.summary != nil,
          checks: (page?.units ?? []).filter { $0.kind == .check }.count))
      formulas += (facets?.formulas ?? []).compactMap(line).map { Formula(line: $0, concept: c) }
      workings += (page?.units ?? []).filter { $0.kind == .block && $0.block?["type"]?.string == "derivation" }.compactMap { u in
        u.block?["title"]?.string.map { Working(title: $0, concept: c) }
      }
      mistakes += notes.filter { $0.note == .misconception }.compactMap { u in u.text.map { Mistake(text: $0, concept: c) } }
      termNotes += notes.filter { $0.note == .commandTerm }.compactMap { u in u.text.map { Mistake(text: $0, concept: c) } }
      for s in c.symbols {
        if let i = symbols.firstIndex(where: { $0.symbol == s.symbol }) {
          symbols[i] = Symbol(symbol: s.symbol, meaning: symbols[i].meaning, concepts: symbols[i].concepts + [c])
        } else {
          symbols.append(Symbol(symbol: s.symbol, meaning: s.meaning, concepts: [c]))
        }
      }
      refs += (references.concepts[c.id]?.items ?? []).map { Ref(reference: $0, concept: c) }
      for v in facets?.keyConcepts ?? [] { tags.key[v, default: 0] += 1 }
      for v in facets?.relatedConcepts ?? [] { tags.related[v, default: 0] += 1 }
      for v in facets?.globalContexts ?? [] { tags.global[v, default: 0] += 1 }
      for v in facets?.tok ?? [] { tags.tok[v, default: 0] += 1 }
      for v in facets?.nos ?? [] { tags.nos[v, default: 0] += 1 }
      for v in facets?.commandTerms ?? [] { tags.terms[v, default: 0] += 1 }
    }
    let sorted = { (m: [String: Int]) in m.map { Tag(value: $0.key, count: $0.value) }.sorted { ($1.count, $0.value) < ($0.count, $1.value) } }
    let commandTerms = sorted(tags.terms).map { t in
      TermUse(
        term: t.value, count: t.count, definition: CommandTerms.lookup(t.value),
        notes: termNotes.filter { $0.text.range(of: "\"\(t.value)\"", options: .caseInsensitive) != nil })
    }
    return UnitDigest(
      concepts: summaries, formulas: formulas, workings: workings, terms: unitTerms(Glossary.load(data), concepts: concepts), symbols: symbols,
      mistakes: mistakes, references: refs, keyConcepts: sorted(tags.key), relatedConcepts: sorted(tags.related), globalContexts: sorted(tags.global),
      tok: sorted(tags.tok), nos: sorted(tags.nos), commandTerms: commandTerms, inquiry: inquiry)
  }

  // 단원 개념의 글(제목, 원문 단위)에 나오는 용어집의 용어. 단어 경계로 찾고, 대소문자를 가리지 않는다.
  static func unitTerms(_ glossary: Glossary, concepts: [Concept]) -> [GlossaryTerm] {
    let subjects = Set(concepts.map(\.subject))
    let corpus = concepts.flatMap { [$0.title] + $0.units.map(\.text) }.joined(separator: "\n")
    return glossary.terms.filter { term in
      (term.subjects.isEmpty || !subjects.isDisjoint(with: term.subjects)) && term.names.contains { Self.mentions(corpus, $0) }
    }
    .sorted { $0.en.localizedCaseInsensitiveCompare($1.en) == .orderedAscending }
  }

  public static func mentions(_ text: String, _ term: String) -> Bool {
    let pattern = "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: term) + "(?![A-Za-z])"
    return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  // 출처의 쪽 ("<자료 id>#p33") → 자료마다 쪽 번호
  public static func pages(_ src: [String]) -> [(source: String, pages: [Int])] {
    var out: [(source: String, pages: [Int])] = []
    for s in src {
      let parts = s.split(separator: "#")
      guard parts.count == 2, parts[1].hasPrefix("p"), let n = Int(parts[1].dropFirst()) else { continue }
      let source = String(parts[0])
      if let i = out.firstIndex(where: { $0.source == source }) { out[i].pages.append(n) } else { out.append((source, [n])) }
    }
    return out.map { ($0.source, Array(Set($0.pages)).sorted()) }
  }
}
