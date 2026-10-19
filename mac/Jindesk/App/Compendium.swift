import Foundation
import JindeskKit

// 모아 보기의 항목 (PAGES.md 의 모아 보기, DECISIONS.md 34). 범주마다 지금 데이터에서 모은다. 새 글을 만들지 않는다.
struct CompendiumItem: Identifiable {
  let id: String
  let title: String
  let sub: String
  var count: Int?
  // A–Z 로 묶을 이름 (용어·기호·command terms·IB 맥락은 그 말, 나머지는 개념 이름)
  let index: String
  // 고르면 내용 칸에 열 것
  let open: SubjectSelection
  // 기호는 세리프 기울임으로 보인다
  var symbol = false
}

extension AppModel {
  // 과목으로 거른 개념 (배우는 순서)
  func compendiumConcepts(_ subject: String?) -> [Concept] {
    inLearningOrder(allConcepts.filter { subject == nil || $0.subject == subject })
  }

  func compendium(_ tab: CollectionsTab, subject: String?) -> [CompendiumItem] {
    guard let data else { return [] }
    let concepts = compendiumConcepts(subject)
    let head = { (c: Concept) in TitleParts(c.title).head }
    func facets() -> [(Concept, ConceptFacets)] { concepts.compactMap { c in ConceptFacets.load(ConceptFolder(c.cid, in: data)).map { (c, $0) } } }
    switch tab {
    case .terms:
      return Glossary.load(data).terms.filter { subject == nil || $0.subjects.isEmpty || $0.subjects.contains(subject!) }.map { t in
        CompendiumItem(id: "term:\(t.en)", title: t.en, sub: t.ko, index: t.en, open: .entry("term:\(t.en)"))
      }
    case .symbols:
      var order: [String] = []
      var by: [String: (meaning: String, concepts: [Concept])] = [:]
      for c in concepts {
        for s in c.symbols {
          if by[s.symbol] == nil {
            order.append(s.symbol)
            by[s.symbol] = (s.meaning, [])
          }
          by[s.symbol]!.concepts.append(c)
        }
      }
      return order.map { s in
        CompendiumItem(id: "symbol:\(s)", title: TexText.display(s), sub: TexText.display(by[s]!.meaning), index: s, open: .entry("symbol:\(s)"), symbol: true)
      }
    case .commandTerms:
      var counts: [String: Int] = [:]
      for (_, f) in facets() { for t in f.commandTerms { counts[t, default: 0] += 1 } }
      return counts.map { t, n in
        CompendiumItem(id: "command:\(t)", title: t, sub: CommandTerms.lookup(t)?.ko ?? "", count: n, index: t, open: .entry("command:\(t)"))
      }
    case .formulas:
      return facets().flatMap { c, f in
        (f.formulas ?? []).compactMap { ref in
          c.claim(ref).map {
            CompendiumItem(
              id: "formula:\(c.id)#\(ref)", title: TexText.display($0.text), sub: head(c), index: c.title, open: .entry("formula:\(c.id)#\(ref)"))
          }
        }
      }
    case .mistakes:
      return concepts.flatMap { c in
        (Page.load(ConceptFolder(c.cid, in: data))?.units ?? []).filter { $0.kind == .note && $0.note == .misconception }.map { u in
          CompendiumItem(
            id: "mistake:\(c.id)#\(u.id)", title: TexText.display(u.text ?? ""), sub: head(c), index: c.title, open: .entry("mistake:\(c.id)#\(u.id)"))
        }
      }
    case .references:
      let refs = References.load(data)
      return concepts.flatMap { c in
        (refs.concepts[c.id]?.items ?? []).enumerated().map { i, r in
          CompendiumItem(
            id: "reference:\(c.id)#\(i)", title: r.title, sub: "\(UnitDigestBody.kindLabel(r.kind)) · \(head(c))", index: c.title,
            open: .entry("reference:\(c.id)#\(i)"))
        }
      }
    case .ib:
      var by: [String: Int] = [:]
      for (_, f) in facets() {
        for (kind, values) in Self.ibKinds(f) { for v in values { by["\(kind)|\(v)", default: 0] += 1 } }
      }
      return by.map { key, n in
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        return CompendiumItem(id: "ib:\(key)", title: parts[1], sub: parts[0], count: n, index: parts[1], open: .entry("ib:\(key)"))
      }
    case .links:
      return crossLinks().filter { subject == nil || $0.from.subject == subject || $0.to.subject == subject }.map { l in
        CompendiumItem(id: "link:\(l.id)", title: "\(head(l.from)) ↔ \(head(l.to))", sub: l.note, index: l.from.title, open: .entry("link:\(l.id)"))
      }
    case .checks:
      return allChecks().filter { subject == nil || $0.concept.subject == subject }.map { q in
        CompendiumItem(id: "check:\(q.id)", title: TexText.display(q.question), sub: head(q.concept), index: q.concept.title, open: .entry("check:\(q.id)"))
      }
    case .memos:
      return allComments().compactMap { c -> CompendiumItem? in
        guard let concept = c.anchor.flatMap({ self.concept($0.concept) }), subject == nil || concept.subject == subject else { return nil }
        let kind = c.kind == .memo ? nil : c.kind.label
        return CompendiumItem(
          id: "memo:\(c.id)", title: TexText.display(c.text ?? ""), sub: [kind, head(concept), String(c.at.prefix(10))].compactMap { $0 }.joined(separator: " · "),
          index: concept.title, open: .concept(concept.id))
      }
    case .sources:
      return library.sources.filter { s in subject == nil || library.subjects.first { $0.id == subject }?.sources.contains { $0.id == s.id } == true }.map { s in
        CompendiumItem(
          id: "source:\(s.id)", title: SourceRow.title(s), sub: [subjectName(s), SourceRow.date(s.meta.received), "\(s.meta.pages)쪽"].compactMap { $0 }.joined(separator: " · "),
          index: SourceRow.title(s), open: .source(s.id))
      }
    }
  }

  static func ibKinds(_ f: ConceptFacets) -> [(String, [String])] {
    [("Key concept", f.keyConcepts), ("Related concept", f.relatedConcepts), ("Global context", f.globalContexts), ("TOK", f.tok), ("NOS", f.nos)]
  }

  // 모아 보기의 항목을 키로 찾는다
  func compendiumFacets(_ concept: Concept) -> ConceptFacets? {
    data.flatMap { ConceptFacets.load(ConceptFolder(concept.cid, in: $0)) }
  }
}
