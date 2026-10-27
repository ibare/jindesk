// 폰의 찾기 결과, 사전(용어, 기호), 용어·기호 시트, 단원 요약 (MOBILE.md 의 하는 일, DECISIONS.md 34). 읽기만 한다.
import JindeskKit
import SwiftUI

// 찾기 결과: 개념, 용어, 기호
struct SearchResults: View {
  @Environment(MobileModel.self) private var model
  let query: String

  var body: some View {
    let concepts = model.searchConcepts(query)
    let terms = model.searchTerms(query)
    let symbols = model.searchSymbols(query)
    if concepts.isEmpty && terms.isEmpty && symbols.isEmpty {
      Section { Text("찾은 것이 없습니다").foregroundStyle(.secondary) }
    }
    if !concepts.isEmpty {
      Section("개념") {
        ForEach(concepts) { c in
          Button {
            model.open(c.id, find: query)
          } label: {
            Text(TitleParts(c.title).head).foregroundStyle(.primary)
          }
        }
      }
    }
    if !terms.isEmpty {
      Section("용어") {
        ForEach(terms, id: \.en) { t in TermRow(term: t) }
      }
    }
    if !symbols.isEmpty {
      Section("기호") {
        ForEach(symbols, id: \.symbol) { s in SymbolRow(symbol: s.symbol, meaning: s.meaning) }
      }
    }
  }
}

struct TermRow: View {
  @Environment(MobileModel.self) private var model
  let term: GlossaryTerm

  var body: some View {
    Button {
      model.lookup = .term(term.en)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(term.en).foregroundStyle(.primary)
        Text(term.ko).foregroundStyle(.secondary)
      }
    }
  }
}

struct SymbolRow: View {
  @Environment(MobileModel.self) private var model
  let symbol: String
  let meaning: String

  var body: some View {
    Button {
      model.lookup = .symbol(symbol)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(TexText.display(symbol)).font(.system(.title3, design: .serif)).italic().foregroundStyle(.primary).frame(minWidth: 40, alignment: .leading)
        Text(TexText.display(meaning)).foregroundStyle(.secondary)
      }
    }
  }
}

// 사전: 용어나 기호를 첫 글자로 묶는다 (맥의 모아 보기와 같은 A–Z)
struct DictionaryList: View {
  @Environment(MobileModel.self) private var model
  let symbols: Bool

  var body: some View {
    List {
      if symbols {
        ForEach(AlphaIndex.sections(model.symbols) { $0.symbol }, id: \.letter) { section in
          Section(section.letter) {
            ForEach(section.items, id: \.symbol) { s in SymbolRow(symbol: s.symbol, meaning: s.meaning) }
          }
        }
      } else {
        ForEach(AlphaIndex.sections(model.glossary.terms) { $0.en }, id: \.letter) { section in
          Section(section.letter) {
            ForEach(section.items, id: \.en) { TermRow(term: $0) }
          }
        }
      }
    }
    .navigationTitle(symbols ? "기호" : "용어")
  }
}

// 용어나 기호를 고르면 뜨는 시트: 한국어(뜻), 기호, 나온 개념, 쓰인 문장
struct LookupSheet: View {
  @Environment(MobileModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let lookup: Lookup

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          switch lookup {
          case .term(let en):
            if let t = model.glossary.terms.first(where: { $0.en == en }) { term(t) }
          case .symbol(let s):
            if let found = model.symbols.first(where: { $0.symbol == s }) { symbol(found) }
          }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
    }
    .presentationDetents([.medium, .large])
  }

  @ViewBuilder func term(_ t: GlossaryTerm) -> some View {
    let concepts = model.conceptsMentioning(t)
    VStack(alignment: .leading, spacing: 4) {
      Text(t.en).font(.title.bold())
      Text(t.ko).font(.title3).foregroundStyle(.secondary)
    }
    if let s = concepts.flatMap(\.symbols).first(where: { $0.meaning.localizedCaseInsensitiveContains(t.en) }) {
      row("기호") { Text(TexText.display(s.symbol)).font(.system(.title3, design: .serif)).italic() }
    }
    if !concepts.isEmpty { row("나온 개념") { chips(concepts) } }
    usage(concepts) { UnitDigest.mentions($0, t.en) }
  }

  @ViewBuilder func symbol(_ s: (symbol: String, meaning: String, concepts: [Concept])) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      Text(TexText.display(s.symbol)).font(.system(size: 40, design: .serif)).italic()
      Text(TexText.display(s.meaning)).font(.title3).foregroundStyle(.secondary)
    }
    row("나온 개념") { chips(s.concepts) }
    usage(s.concepts) { $0.contains(s.symbol) }
  }

  func row(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.footnote).foregroundStyle(.secondary)
      content()
    }
  }

  func chips(_ concepts: [Concept]) -> some View {
    FlowChips(items: concepts.map { ($0.id, TitleParts($0.title).head) }) { id in
      dismiss()
      model.open(id)
    }
  }

  // 그 말이 쓰인 첫 주장과 근거 쪽
  @ViewBuilder func usage(_ concepts: [Concept], matches: (String) -> Bool) -> some View {
    let found = concepts.compactMap { c in c.claimRefs.first { matches($0.claim.text) }.map { (c, $0.claim) } }.first
    if let (c, claim) = found {
      row("쓰인 문장") {
        VStack(alignment: .leading, spacing: 6) {
          Text(TexText.display(claim.text))
          HStack(spacing: 8) {
            Text(TitleParts(c.title).head).font(.footnote).foregroundStyle(.secondary)
            PhonePageChip(src: claim.src) { dismiss() }
          }
        }
      }
    }
  }
}

// 개념 칩 (줄을 넘긴다)
struct FlowChips: View {
  let items: [(id: String, label: String)]
  let tap: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(items, id: \.id) { item in
        Button(item.label) { tap(item.id) }
          .font(.body.weight(.semibold))
          .padding(.horizontal, 12)
          .frame(minHeight: 36)
          .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.14)))
      }
    }
  }
}

// 근거 쪽: 누르면 원래 자료의 그 쪽을 연다
struct PhonePageChip: View {
  @Environment(MobileModel.self) private var model
  let src: [String]
  var before: () -> Void = {}

  var body: some View {
    let groups = UnitDigest.pages(src)
    if let first = groups.first, let page = first.pages.first {
      Button {
        before()
        model.openSource(first.source, page: page)
      } label: {
        Text(groups.map { $0.pages.map(String.init).joined(separator: "·") }.joined(separator: " / "))
          .font(.caption.monospacedDigit())
          .padding(.horizontal, 8)
          .frame(minHeight: 28)
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityLabel("원래 자료 \(page)쪽 열기")
    }
  }
}

// 단원 요약: 맥의 단원 개요와 같은 것을 한 칸으로 (DECISIONS.md 34). 요약은 고른 주장을 글자 그대로, 줄마다 근거 쪽.
struct UnitSummaryScreen: View {
  @Environment(MobileModel.self) private var model
  let subject: String
  let key: String
  @State private var openTerm: String?

  var body: some View {
    let unit = model.unit(subject, key)
    if let data = model.data, !unit.concepts.isEmpty {
      let d = UnitDigest.make(data, concepts: unit.concepts, inquiry: unit.inquiry)
      List {
        Section {
          VStack(alignment: .leading, spacing: 4) {
            Text(unit.title).font(.system(.largeTitle, design: .serif).weight(.semibold))
            Text("개념 \(d.concepts.count) · 배우는 순서로").font(.subheadline).foregroundStyle(.secondary)
          }
          .listRowBackground(Color.clear)
        }
        Section {
          if d.unpicked > 0 { Text("요약을 아직 고르지 않은 개념이 \(d.unpicked)개 있습니다").font(.footnote).foregroundStyle(.secondary) }
          ForEach(d.concepts, id: \.concept.id) { s in summary(s) }
        } header: {
          Text("한 장 요약")
        } footer: {
          Text("자료에서 확인된 문장 그대로입니다. 숫자는 근거 쪽입니다.")
        }
        if !d.formulas.isEmpty {
          Section("공식") {
            ForEach(Array(d.formulas.enumerated()), id: \.offset) { _, f in
              VStack(alignment: .leading, spacing: 6) {
                Text(TexText.display(f.line.text)).font(.system(.body, design: .serif))
                HStack {
                  Text(TitleParts(f.concept.title).head).font(.footnote).foregroundStyle(.secondary)
                  Spacer()
                  PhonePageChip(src: f.line.src)
                }
              }
            }
          }
        }
        if !d.terms.isEmpty {
          Section("용어") { ForEach(d.terms, id: \.en) { TermRow(term: $0) } }
        }
        if !d.symbols.isEmpty {
          Section("기호") { ForEach(d.symbols, id: \.symbol) { SymbolRow(symbol: $0.symbol, meaning: $0.meaning) } }
        }
        if !d.mistakes.isEmpty {
          Section("자주 하는 실수") {
            ForEach(Array(d.mistakes.enumerated()), id: \.offset) { _, m in
              Label {
                VStack(alignment: .leading, spacing: 4) {
                  Text(TexText.display(m.text))
                  Text(TitleParts(m.concept.title).head).font(.footnote).foregroundStyle(.secondary)
                }
              } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
              }
            }
          }
        }
        if !d.references.isEmpty {
          Section("더 볼 자료") {
            ForEach(Array(d.references.enumerated()), id: \.offset) { _, r in
              if let url = URL(string: r.reference.url) {
                Link(destination: url) {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(r.reference.title).font(.body.weight(.semibold))
                    Text(r.reference.why).font(.footnote).foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        }
        if d.inquiry != nil || !d.keyConcepts.isEmpty || !d.commandTerms.isEmpty {
          Section("IB 맥락") {
            if let inquiry = d.inquiry { Text(inquiry).font(.system(.body, design: .serif)) }
            ForEach(
              [("Key concepts", d.keyConcepts), ("Related concepts", d.relatedConcepts), ("TOK", d.tok)].filter { !$0.1.isEmpty }, id: \.0
            ) { g in
              VStack(alignment: .leading, spacing: 4) {
                Text(g.0).font(.footnote).foregroundStyle(.secondary)
                Text(g.1.map { "\($0.value) \($0.count)" }.joined(separator: " · "))
              }
            }
            ForEach(d.commandTerms, id: \.term) { t in
              DisclosureGroup(isExpanded: Binding(get: { openTerm == t.term }, set: { openTerm = $0 ? t.term : nil })) {
                if let def = t.definition { Text(def.definition).font(.subheadline) }
              } label: {
                HStack {
                  Text(t.term).font(.body.weight(.semibold))
                  Text(t.definition?.ko ?? "").foregroundStyle(.secondary)
                  Spacer()
                  Text("\(t.count)").foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      }
      .navigationTitle(unit.title)
      .navigationBarTitleDisplayMode(.inline)
    } else {
      ContentUnavailableView("이 단원에 개념이 없습니다", systemImage: "square.stack")
    }
  }

  func summary(_ s: UnitDigest.ConceptSummary) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        model.open(s.concept.id)
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(TitleParts(s.concept.title).head).font(.headline).foregroundStyle(.primary)
          if let ko = s.titleKo { Text(TitleParts(ko).head).font(.subheadline).foregroundStyle(.secondary) }
        }
      }
      .buttonStyle(.plain)
      ForEach(s.lines, id: \.ref) { line in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("•").foregroundStyle(.secondary)
          Text(TexText.display(line.text)).frame(maxWidth: .infinity, alignment: .leading)
          PhonePageChip(src: line.src)
        }
      }
      ForEach(s.keyIdeas, id: \.self) { idea in
        VStack(alignment: .leading, spacing: 3) {
          Text("핵심 생각").font(.caption.weight(.bold)).foregroundStyle(.teal)
          Text(TexText.display(idea)).font(.subheadline)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.teal.opacity(0.12)))
      }
    }
    .padding(.vertical, 6)
  }
}
