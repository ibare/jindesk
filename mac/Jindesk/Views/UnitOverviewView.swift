import AppKit
import JindeskKit
import SwiftUI

// 단원 개요 (PAGES.md 의 단원 개요, DECISIONS.md 34): 한 장 요약, 공식과 풀이, 용어와 기호, 자주 하는 실수, 더 볼 자료, IB 맥락.
// 한 장 요약과 공식은 관점 붙이기가 고른 개념 원문의 주장을 글자 그대로 보이고, 줄마다 근거 쪽을 단다. 쪽을 누르면 원래 자료의 그 쪽이 열린다.
struct UnitOverviewView: View {
  @Environment(AppModel.self) private var model
  let subject: String
  let key: String

  enum Section: String, CaseIterable, Identifiable {
    case summary, formulas, words, mistakes, references, ib
    var id: String { rawValue }
    var label: String {
      switch self {
      case .summary: "한 장 요약"
      case .formulas: "공식과 풀이"
      case .words: "용어 · 기호"
      case .mistakes: "자주 하는 실수"
      case .references: "더 볼 자료"
      case .ib: "IB 맥락"
      }
    }
  }

  var body: some View {
    let unit = model.unit(subject, key)
    if !unit.concepts.isEmpty, let digest = model.unitDigest(subject, key, unit) {
      ScrollViewReader { proxy in
        ScrollView {
          UnitDigestBody(subject: subject, title: unit.title, digest: digest) { section in withAnimation { proxy.scrollTo(section, anchor: .top) } }
            .padding(.horizontal, 36)
            .padding(.vertical, 26)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        #if DEBUG
          // 화면 확인: 절까지 내려 연다 (-snapshotUnitSection <summary|formulas|words|mistakes|references|ib>)
          .task {
            guard let name = UserDefaults.standard.string(forKey: "snapshotUnitSection"), let s = Section(rawValue: name) else { return }
            try? await Task.sleep(for: .milliseconds(1000))
            proxy.scrollTo(s, anchor: .top)
          }
        #endif
      }
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("PDF로 뽑기", systemImage: "arrow.down.doc") { UnitPDF.save(model: model, subjectName: subjectName, title: unit.title, digest: digest) }
            .help("이 단원 개요를 PDF 로 저장합니다")
        }
      }
    } else {
      ContentUnavailableView("이 단원에 개념이 없어요", systemImage: "square.stack")
    }
  }

  var subjectName: String { model.library.subjects.first { $0.id == subject }?.name ?? subject }
}

// 단원 개요의 본문. 화면과 PDF 가 함께 쓴다 (PDF 는 printing 이 참이고, 누르는 것이 없다).
struct UnitDigestBody: View {
  @Environment(AppModel.self) private var model
  let subject: String
  let title: String
  let digest: UnitDigest
  var printing = false
  var jump: (UnitOverviewView.Section) -> Void = { _ in }
  @State private var term: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 30) {
      header
      if digest.concepts.contains(where: { $0.picked || !$0.keyIdeas.isEmpty }) || digest.unpicked > 0 { summary.id(UnitOverviewView.Section.summary) }
      if !digest.formulas.isEmpty || !digest.workings.isEmpty { formulas.id(UnitOverviewView.Section.formulas) }
      if !digest.terms.isEmpty || !digest.symbols.isEmpty { words.id(UnitOverviewView.Section.words) }
      if !digest.mistakes.isEmpty { mistakes.id(UnitOverviewView.Section.mistakes) }
      if !digest.references.isEmpty && !printing { references.id(UnitOverviewView.Section.references) }
      if hasIB { ib.id(UnitOverviewView.Section.ib) }
    }
  }

  var subjectName: String { model.library.subjects.first { $0.id == subject }?.name ?? subject }

  var hasIB: Bool {
    digest.inquiry != nil || !digest.keyConcepts.isEmpty || !digest.relatedConcepts.isEmpty || !digest.tok.isEmpty || !digest.commandTerms.isEmpty
  }

  // MARK: - 머리

  var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("\(subjectName) › 단원").font(.system(size: 12)).foregroundStyle(.secondary)
      Text(title).font(.system(size: 32, weight: .semibold, design: .serif))
      Text(meta).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
      if !printing {
        FlowLayout(spacing: 6) {
          ForEach(UnitOverviewView.Section.allCases.filter(shown)) { s in
            Button(s.label) { jump(s) }
              .buttonStyle(.plain)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
              .overlay(Capsule().stroke(Color.primary.opacity(0.2)))
          }
        }
        .padding(.top, 8)
      }
    }
  }

  func shown(_ s: UnitOverviewView.Section) -> Bool {
    switch s {
    case .summary: true
    case .formulas: !digest.formulas.isEmpty || !digest.workings.isEmpty
    case .words: !digest.terms.isEmpty || !digest.symbols.isEmpty
    case .mistakes: !digest.mistakes.isEmpty
    case .references: !digest.references.isEmpty
    case .ib: hasIB
    }
  }

  var meta: String {
    let sources = Set(digest.concepts.flatMap { $0.concept.occurrences.map(\.source) })
    let pages = sources.compactMap { model.library.source($0)?.meta.pages }.reduce(0, +)
    return "개념 \(digest.concepts.count) · 자료 \(sources.count)" + (pages > 0 ? " (\(pages)쪽)" : "") + " · 배우는 순서로"
  }

  func sectionTitle(_ text: String, note: String? = nil) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(text).font(.system(size: 16, weight: .bold))
      if let note { Text(note).font(.system(size: 12)).foregroundStyle(.secondary) }
    }
  }

  // MARK: - 한 장 요약

  var summary: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionTitle("한 장 요약", note: "자료에서 확인된 문장 그대로 · 숫자는 근거 쪽")
      if digest.unpicked > 0 {
        Label("요약을 아직 고르지 않은 개념이 \(digest.unpicked)개 있어요. 관점 붙이기가 고릅니다 (남은 일).", systemImage: "hourglass")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      }
      Columns(count: 2, items: digest.concepts) { s in summaryCard(s) }
    }
  }

  func summaryCard(_ s: UnitDigest.ConceptSummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        model.selection = .concept(s.concept.id)
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(TitleParts(s.concept.title).head).font(.system(size: 15, weight: .bold)).multilineTextAlignment(.leading)
          if let ko = s.titleKo { Text(TitleParts(ko).head).font(.system(size: 12.5)).foregroundStyle(.secondary) }
        }
      }
      .buttonStyle(.plain)
      .disabled(printing)
      if s.picked {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(s.lines, id: \.ref) { line in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Circle().fill(Color.secondary).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
              Text(TexText.display(line.text)).font(.system(size: 13)).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
              PageChip(src: line.src, printing: printing)
            }
          }
        }
      } else {
        Text("요약을 고르는 중이에요").font(.system(size: 12.5)).foregroundStyle(.secondary)
      }
      ForEach(s.keyIdeas, id: \.self) { idea in
        VStack(alignment: .leading, spacing: 3) {
          Text("핵심 생각").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Color.teal)
          Text(TexText.display(idea)).font(.system(size: 12.5)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.12)))
      }
      Text(foot(s)).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .card()
  }

  func foot(_ s: UnitDigest.ConceptSummary) -> String {
    let pages = Occurrence.pagesLabel(s.concept.occurrences).map { $0.hasPrefix("자료") ? $0 : "자료 \($0)" }
    return [pages, s.checks > 0 ? "확인 문제 \(s.checks)" : nil].compactMap { $0 }.joined(separator: " · ")
  }

  // MARK: - 공식과 풀이

  var formulas: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionTitle("공식과 풀이")
      if !digest.formulas.isEmpty {
        VStack(spacing: 0) {
          ForEach(Array(digest.formulas.enumerated()), id: \.offset) { i, f in
            HStack(alignment: .firstTextBaseline, spacing: 16) {
              Text(TexText.display(f.line.text)).font(.system(size: 15, design: .serif)).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
              Text(TitleParts(f.concept.title).head).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 180, alignment: .leading)
              PageChip(src: f.line.src, printing: printing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            if i < digest.formulas.count - 1 { Divider() }
          }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
      }
      if !digest.workings.isEmpty {
        FlowLayout(spacing: 8) {
          Text("풀이 \(digest.workings.count)").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 5)
          ForEach(Array(digest.workings.enumerated()), id: \.offset) { _, w in
            Button(w.title) { model.selection = .concept(w.concept.id) }
              .buttonStyle(.plain)
              .disabled(printing)
              .font(.system(size: 12.5))
              .foregroundStyle(Color.accentColor)
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.12)))
          }
        }
      }
    }
  }

  // MARK: - 용어와 기호

  var words: some View {
    VStack(alignment: .leading, spacing: 24) {
      if !digest.terms.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          sectionTitle("용어", note: "\(digest.terms.count)")
          Columns(count: 2, spacing: 24, rowSpacing: 0, items: digest.terms) { t in
            HStack(alignment: .firstTextBaseline) {
              Text(t.en).font(.system(size: 13))
              Spacer(minLength: 6)
              Text(t.ko).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) { Divider() }
          }
        }
      }
      if !digest.symbols.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          sectionTitle("기호", note: "\(digest.symbols.count)")
          Columns(count: 2, spacing: 24, rowSpacing: 0, items: digest.symbols) { s in
            HStack(alignment: .firstTextBaseline, spacing: 14) {
              Text(TexText.display(s.symbol)).font(.system(size: 15, design: .serif)).italic().frame(width: 44, alignment: .leading)
              Text(TexText.display(s.meaning)).font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) { Divider() }
          }
        }
      }
    }
  }

  // MARK: - 자주 하는 실수

  var mistakes: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionTitle("자주 하는 실수", note: "\(digest.mistakes.count)")
      ForEach(Array(digest.mistakes.enumerated()), id: \.offset) { _, m in
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.ribbon)
          VStack(alignment: .leading, spacing: 4) {
            Text(TexText.display(m.text)).font(.system(size: 13.5)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            Text(TitleParts(m.concept.title).head).font(.system(size: 12)).foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.ribbon.opacity(0.12)))
      }
    }
  }

  // MARK: - 더 볼 자료

  var references: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionTitle("더 볼 자료", note: referenceNote)
      Columns(count: 2, spacing: 10, items: digest.references) { r in
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.kindLabel(r.reference.kind)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.accentColor)
              .padding(.horizontal, 6).padding(.vertical, 1)
              .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.12)))
            if let url = URL(string: r.reference.url) {
              Link(destination: url) {
                Text(r.reference.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
          Text(r.reference.why).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          Text(TitleParts(r.concept.title).head).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
      }
    }
  }

  var referenceNote: String {
    let kinds = Dictionary(grouping: digest.references, by: { Self.kindLabel($0.reference.kind) }).map { "\($0.key) \($0.value.count)" }.sorted()
    return ([String(digest.references.count)] + kinds).joined(separator: " · ")
  }

  static func kindLabel(_ kind: String) -> String {
    switch kind {
    case "video": "영상"
    case "article": "글"
    case "interactive": "시뮬레이션"
    case "practice": "연습"
    default: "자료"
    }
  }

  // MARK: - IB 맥락

  var ib: some View {
    VStack(alignment: .leading, spacing: 14) {
      sectionTitle("IB 맥락")
      if let inquiry = digest.inquiry {
        VStack(alignment: .leading, spacing: 4) {
          Text("탐구 진술 (목차의 MYP 단원 안내)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
          Text(inquiry).font(.system(size: 17, design: .serif)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
      }
      let groups = [("Key concepts", digest.keyConcepts), ("Related concepts", digest.relatedConcepts), ("Global contexts", digest.globalContexts), ("TOK", digest.tok), ("NOS", digest.nos)]
        .filter { !$0.1.isEmpty }
      if !groups.isEmpty {
        Columns(count: 3, items: groups) { g in
            VStack(alignment: .leading, spacing: 8) {
              Text(g.0).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
              FlowLayout(spacing: 6) {
                ForEach(g.1, id: \.value) { tag in
                  HStack(spacing: 4) {
                    Text(tag.value)
                    Text("\(tag.count)").foregroundStyle(.secondary)
                  }
                  .font(.system(size: 12.5))
                  .padding(.horizontal, 8)
                  .padding(.vertical, 3)
                  .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
              }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
        }
      }
      if !digest.commandTerms.isEmpty { commandTerms }
    }
  }

  var commandTerms: some View {
    let chosen = digest.commandTerms.first { $0.term == term } ?? digest.commandTerms[0]
    return VStack(alignment: .leading, spacing: 10) {
      Text("Command terms · \(digest.commandTerms.count) · 숫자는 그 말이 붙은 개념 수").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
      FlowLayout(spacing: 6) {
        ForEach(digest.commandTerms, id: \.term) { t in
          let on = t.term == chosen.term && !printing
          Button {
            term = t.term
          } label: {
            HStack(spacing: 4) {
              Text(t.term).fontWeight(.semibold)
              Text("\(t.count)")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(on ? Color.white : Color.accentColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor : Color.accentColor.opacity(0.12)))
          }
          .buttonStyle(.plain)
          .disabled(printing)
        }
      }
      ForEach(printing ? digest.commandTerms : [chosen], id: \.term) { t in CommandTermDetail(use: t) }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
  }
}

// 칸을 나눠 늘어놓는다. 게으르지 않게 그려 절로 옮겨 가는 스크롤이 정확하다 (LazyVGrid 는 보이지 않는 칸의 높이를 어림한다)
struct Columns<Item, Cell: View>: View {
  let count: Int
  var spacing: CGFloat = 12
  var rowSpacing: CGFloat?
  let items: [Item]
  @ViewBuilder let cell: (Item) -> Cell

  var body: some View {
    Grid(alignment: .topLeading, horizontalSpacing: spacing, verticalSpacing: rowSpacing ?? spacing) {
      ForEach(Array(stride(from: 0, to: items.count, by: count)), id: \.self) { start in
        GridRow {
          ForEach(start..<min(start + count, items.count), id: \.self) { i in
            cell(items[i]).frame(maxWidth: .infinity, alignment: .topLeading)
          }
          ForEach(0..<max(0, start + count - items.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
        }
      }
    }
  }
}

// command term 하나: IB 정의, 한국어, 학습 페이지의 command term 상자
struct CommandTermDetail: View {
  let use: UnitDigest.TermUse

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(use.term).font(.system(size: 13, weight: .bold))
        if let ko = use.definition?.ko { Text(ko).font(.system(size: 12.5)).foregroundStyle(.secondary) }
      }
      if let d = use.definition {
        (Text(d.definition).font(.system(size: 12.5)) + Text("  · IB 정의").font(.system(size: 11.5)).foregroundColor(.secondary))
          .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
      }
      ForEach(Array(use.notes.enumerated()), id: \.offset) { _, n in
        Text("학습 페이지의 말: \(TexText.display(n.text)) · \(TitleParts(n.concept.title).head)").font(.system(size: 12.5)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
  }
}

// 근거 쪽 칩: 자료가 하나면 "33·35", 여럿이면 자료마다 묶는다. 누르면 원래 자료의 첫 쪽을 연다.
struct PageChip: View {
  @Environment(AppModel.self) private var model
  let src: [String]
  var printing = false

  var body: some View {
    let groups = UnitDigest.pages(src)
    if let first = groups.first, let page = first.pages.first {
      Button {
        model.peek = SourcePeek(source: first.source, page: page)
      } label: {
        Text(groups.map { $0.pages.map(String.init).joined(separator: "·") }.joined(separator: " / "))
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .frame(height: 18)
          .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.22)))
      }
      .buttonStyle(.plain)
      .disabled(printing)
      .help("원래 자료의 \(page)쪽을 엽니다")
      .fixedSize()
    }
  }
}

// 단원 개요를 PDF 로 저장한다. 밝은 모양으로 그린 뒤 시스템 인쇄가 쪽을 나눈다.
@MainActor
enum UnitPDF {
  static func save(model: AppModel, subjectName: String, title: String, digest: UnitDigest) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue = "\(subjectName) - \(title).pdf"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let info = NSPrintInfo()
    info.paperSize = NSSize(width: 595, height: 842)
    info.topMargin = 36
    info.bottomMargin = 36
    info.leftMargin = 36
    info.rightMargin = 36
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    info.jobDisposition = .save
    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
    let width = info.paperSize.width - info.leftMargin - info.rightMargin
    let body = UnitDigestBody(subject: digest.concepts.first?.concept.subject ?? "", title: title, digest: digest, printing: true)
      .frame(width: width, alignment: .topLeading)
      .environment(model)
      .environment(\.colorScheme, .light)
      .background(Color.white)
    let view = NSHostingView(rootView: body)
    view.frame = NSRect(origin: .zero, size: CGSize(width: width, height: view.fittingSize.height))
    let op = NSPrintOperation(view: view, printInfo: info)
    op.showsPrintPanel = false
    op.showsProgressPanel = false
    op.run()
  }
}
