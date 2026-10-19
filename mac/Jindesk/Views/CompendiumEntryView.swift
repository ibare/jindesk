import JindeskKit
import SwiftUI

// 모아 보기에서 고른 항목 (PAGES.md 의 모아 보기, DECISIONS.md 34): 용어, 기호, command term, 공식, 실수, 레퍼런스, IB 맥락의 값, 연결, 확인 문제
struct CompendiumEntryView: View {
  @Environment(AppModel.self) private var model
  let id: String

  var body: some View {
    let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if parts.count == 2 {
          switch parts[0] {
          case "term": term(parts[1])
          case "symbol": symbol(parts[1])
          case "command": command(parts[1])
          case "formula": claimEntry(parts[1], formula: true)
          case "mistake": mistake(parts[1])
          case "reference": reference(parts[1])
          case "ib": ib(parts[1])
          case "link": link(parts[1])
          case "check": check(parts[1])
          default: EmptyView()
          }
        }
      }
      .padding(.horizontal, 44)
      .padding(.vertical, 32)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - 부품

  func field(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(label).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
      content().frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  func conceptChips(_ concepts: [Concept]) -> some View {
    FlowLayout(spacing: 6) {
      ForEach(concepts, id: \.id) { c in
        Button(TitleParts(c.title).head) { model.selection = .concept(c.id) }
          .buttonStyle(.plain)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Color.accentColor)
          .padding(.horizontal, 9)
          .padding(.vertical, 3)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
      }
    }
  }

  // 그 말이 쓰인 첫 주장 (글, 개념, 근거 쪽)
  func usage(_ concepts: [Concept], _ word: String, symbol: Bool = false) -> some View {
    let found = concepts.lazy.compactMap { c in
      c.claimRefs.first { symbol ? $0.claim.text.contains(word) : UnitDigest.mentions($0.claim.text, word) }.map { (c, $0.claim) }
    }.first
    return Group {
      if let (c, claim) = found {
        field("쓰인 문장") {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            (Text(TexText.display(claim.text)) + Text("  · \(TitleParts(c.title).head)").foregroundColor(.secondary))
              .font(.system(size: 13.5)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            PageChip(src: claim.src)
          }
        }
      }
    }
  }

  var concepts: [Concept] { model.allConcepts }

  // MARK: - 용어

  @ViewBuilder func term(_ en: String) -> some View {
    if let data = model.data, let t = Glossary.load(data).terms.first(where: { $0.en == en }) {
      let mentioned = model.inLearningOrder(
        concepts.filter { c in (t.subjects.isEmpty || t.subjects.contains(c.subject)) && t.names.contains { UnitDigest.mentions(([c.title] + c.units.map(\.text)).joined(separator: "\n"), $0) } })
      let symbols = mentioned.flatMap(\.symbols).filter { $0.meaning.localizedCaseInsensitiveContains(t.en) }
      VStack(alignment: .leading, spacing: 4) {
        Text(t.en).font(.system(size: 28, weight: .bold)).textSelection(.enabled)
        Text(t.ko).font(.system(size: 18)).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if !t.aliases.isEmpty { field("다른 표기") { Text(t.aliases.joined(separator: ", ")).font(.system(size: 13.5)) } }
      if let s = symbols.first { field("기호") { Text(TexText.display(s.symbol)).font(.system(size: 17, design: .serif)).italic() } }
      if !mentioned.isEmpty { field("나온 개념") { conceptChips(mentioned) } }
      usage(mentioned, t.en)
      SourceHits(query: t.en)
    }
  }

  // MARK: - 기호

  @ViewBuilder func symbol(_ raw: String) -> some View {
    let owners = model.inLearningOrder(concepts.filter { $0.symbols.contains { $0.symbol == raw } })
    let def = owners.first?.symbols.first { $0.symbol == raw }
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(TexText.display(raw)).font(.system(size: 40, design: .serif)).italic()
      if let def { Text(TexText.display(def.meaning)).font(.system(size: 18)).foregroundStyle(.secondary) }
    }
    if let unit = def?.unit { field("단위") { Text(TexText.display(unit)).font(.system(size: 13.5)) } }
    if !owners.isEmpty { field("나온 개념") { conceptChips(owners) } }
    usage(owners, raw, symbol: true)
  }

  // MARK: - command term

  @ViewBuilder func command(_ term: String) -> some View {
    let tagged = model.inLearningOrder(concepts.filter { model.compendiumFacets($0)?.commandTerms.contains(term) == true })
    let taggedIDs = Set(tagged.map(\.id))
    let checks = model.allChecks().filter { UnitDigest.mentions($0.question, term) && taggedIDs.contains($0.concept.id) }
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(term).font(.system(size: 28, weight: .bold))
      if let ko = CommandTerms.lookup(term)?.ko { Text(ko).font(.system(size: 17)).foregroundStyle(.secondary) }
    }
    if let d = CommandTerms.lookup(term) {
      VStack(alignment: .leading, spacing: 4) {
        Text("IB 정의").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
        Text(d.definition).font(.system(size: 14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .card()
    }
    if !tagged.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("이 말이 붙은 개념 \(tagged.count)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
        conceptChips(tagged)
      }
    }
    if !checks.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("이 말로 묻는 확인 문제 \(checks.count)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
        ForEach(checks.prefix(6), id: \.id) { q in
          Button {
            model.selection = .entry("check:\(q.id)")
          } label: {
            (Text(TexText.display(q.question)) + Text("  · \(TitleParts(q.concept.title).head)").foregroundColor(.secondary))
              .font(.system(size: 13.5)).lineSpacing(2).lineLimit(3).multilineTextAlignment(.leading)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  // MARK: - 공식

  @ViewBuilder func claimEntry(_ key: String, formula: Bool) -> some View {
    let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
    if parts.count == 2, let c = model.concept(parts[0]), let claim = c.claim(parts[1]) {
      Text(TexText.display(claim.text)).font(.system(size: 26, design: .serif)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      field("개념") { conceptChips([c]) }
      field("근거 쪽") { PageChip(src: claim.src) }
      let workings = (model.data.flatMap { Page.load(ConceptFolder(c.cid, in: $0)) }?.units ?? [])
        .filter { $0.kind == .block && $0.block?["type"]?.string == "derivation" }.compactMap { $0.block?["title"]?.string }
      if !workings.isEmpty {
        field("풀이") {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(workings, id: \.self) { w in Button(w) { model.selection = .concept(c.id) }.buttonStyle(.link) }
          }
        }
      }
    }
  }

  // MARK: - 실수

  @ViewBuilder func mistake(_ key: String) -> some View {
    let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
    if parts.count == 2, let c = model.concept(parts[0]),
      let unit = model.data.flatMap({ Page.load(ConceptFolder(c.cid, in: $0)) })?.units.first(where: { $0.id == parts[1] })
    {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(Color.ribbon)
        Text(TexText.display(unit.text ?? "")).font(.system(size: 15)).lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 12).fill(Color.ribbon.opacity(0.12)))
      field("개념") { conceptChips([c]) }
    }
  }

  // MARK: - 레퍼런스

  @ViewBuilder func reference(_ key: String) -> some View {
    let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
    if parts.count == 2, let c = model.concept(parts[0]), let data = model.data, let i = Int(parts[1]),
      let items = References.load(data).concepts[c.id]?.items, i < items.count
    {
      let r = items[i]
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(UnitDigestBody.kindLabel(r.kind)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
          .padding(.horizontal, 8).padding(.vertical, 2)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
        Text(r.title).font(.system(size: 24, weight: .bold)).fixedSize(horizontal: false, vertical: true)
      }
      Text(r.why).font(.system(size: 15)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
      Text(r.url).font(.system(size: 12.5)).foregroundStyle(.secondary).textSelection(.enabled)
      if let url = URL(string: r.url) { Link("브라우저에서 열기", destination: url).buttonStyle(.borderedProminent) }
      field("개념") { conceptChips([c]) }
    }
  }

  // MARK: - IB 맥락

  @ViewBuilder func ib(_ key: String) -> some View {
    let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
    if parts.count == 2 {
      let tagged = model.inLearningOrder(
        concepts.filter { c in model.compendiumFacets(c).map { AppModel.ibKinds($0).contains { $0.0 == parts[0] && $0.1.contains(parts[1]) } } ?? false })
      VStack(alignment: .leading, spacing: 4) {
        Text(parts[0]).font(.system(size: 12)).foregroundStyle(.secondary)
        Text(parts[1]).font(.system(size: 28, weight: .bold))
      }
      let subjects = Set(tagged.map(\.subject))
      VStack(alignment: .leading, spacing: 8) {
        Text("이 값으로 묶인 개념 \(tagged.count) · 과목 \(subjects.count)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
        conceptChips(tagged)
      }
    }
  }

  // MARK: - 과목 사이 연결

  @ViewBuilder func link(_ key: String) -> some View {
    if let l = model.crossLinks().first(where: { $0.id == key }) {
      Text("과목 사이 연결").font(.system(size: 12)).foregroundStyle(.secondary)
      HStack(spacing: 12) {
        conceptChips([l.from])
        Image(systemName: "arrow.left.and.right").foregroundStyle(.tertiary)
        conceptChips([l.to])
      }
      Text(l.note).font(.system(size: 15)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - 확인 문제

  @ViewBuilder func check(_ key: String) -> some View {
    if let q = model.allChecks().first(where: { $0.id == key }) {
      let number = (model.allChecks().filter { $0.concept.id == q.concept.id }.firstIndex { $0.id == q.id } ?? 0) + 1
      Text("\(TitleParts(q.concept.title).head) · 확인 문제 \(number)").font(.system(size: 12)).foregroundStyle(.secondary)
      Text(TexText.display(q.question)).font(.system(size: 17)).lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      if let answer = q.answer {
        AnswerReveal(answer: answer).id(q.id)
      }
      Button("학습 페이지에서 보기") { model.selection = .concept(q.concept.id) }.buttonStyle(.link)
    }
  }
}

// 답은 눌러야 보인다
struct AnswerReveal: View {
  let answer: String
  @State private var open = false

  var body: some View {
    if open {
      VStack(alignment: .leading, spacing: 3) {
        Text("답").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
        Text(TexText.display(answer)).font(.system(size: 14)).lineSpacing(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.1)))
    } else {
      Button("답 보기") { open = true }.buttonStyle(.bordered)
    }
  }
}

// 원래 자료의 쪽 글자층에서 찾은 곳 (찾기 색인)
struct SourceHits: View {
  @Environment(AppModel.self) private var model
  let query: String

  var body: some View {
    let hits = model.sourcePageHits(query)
    if !hits.isEmpty {
      let bySource = Dictionary(grouping: hits, by: \.source)
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        Text("원래 자료").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(bySource.keys.sorted(), id: \.self) { id in
            let pages = bySource[id]!.map(\.page).sorted()
            VStack(alignment: .leading, spacing: 4) {
              Text(model.library.source(id).map(SourceRow.title) ?? id).font(.system(size: 13.5))
              FlowLayout(spacing: 5) {
                ForEach(pages, id: \.self) { p in
                  Button("\(p)") { model.peek = SourcePeek(source: id, page: p) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor.opacity(0.4)))
                }
              }
            }
          }
        }
      }
    }
  }
}
