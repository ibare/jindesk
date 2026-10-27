import JindeskKit
import SwiftUI

// 메인 창: 세 칸이다. 사이드바(오늘, 과목들, 모아 보기, 작업) · 목록 · 내용(학습 페이지, 자료, 작업 기록)
struct MainView: View {
  @Environment(AppModel.self) private var model
  // ⌘F 를 눌렀는데 학습 페이지가 열려 있지 않으면 사이드바의 찾기 칸에 커서를 둔다
  @FocusState private var searchFocused: Bool

  var body: some View {
    @Bindable var model = model
    NavigationSplitView {
      List(selection: $model.sidebarPick) {
        sectionRow(.today)
        // "과목"은 누를 수 없는 이름표이고, 과목은 그 아래에 늘 펼쳐져 있다 (DECISIONS.md 39)
        Label(SidebarSection.subjects.label, systemImage: SidebarSection.subjects.icon)
        ForEach(model.library.subjects) { s in
          HStack(spacing: 6) {
            Text(s.name).lineLimit(1)
            Spacer(minLength: 4)
            if model.hasNew(subject: s.id) { NewDot().help("하루 안에 정리된 개념이 있음") }
          }
          .padding(.leading, 24)
          .tag(SidebarPick.subject(s.id))
        }
        sectionRow(.collections)
        sectionRow(.jobs)
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 200)
      .safeAreaInset(edge: .bottom) { StatusFooter().padding(10) }
    } content: {
      Group {
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
          SearchResultsView()
        } else {
          listColumn
        }
      }
      .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
      // 목록 칸 위에는 고른 화면의 이름을 둔다 (DECISIONS.md 32)
      .navigationTitle(model.searchText.trimmingCharacters(in: .whitespaces).isEmpty ? model.section.label : "찾기")
      // 툴바 항목은 열마다 따로 건다. 목록 칸에 항목이 하나라도 있어야 SwiftUI 가 목록|내용 경계에서 툴바 칸을 나눠,
      // 내용 칸 가운데의 진행 표시가 열 경계선 위에 걸치지 않는다 (Assayer 와 같다).
      .toolbar { ToolbarSpacer(.flexible) }
    } detail: {
      Group {
        if model.section == .jobs && model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
          JobDetail(id: model.selectedJob)
        } else {
          SelectionDetail()
        }
      }
      .toolbar {
        // 진행 표시는 Xcode 의 활동 표시처럼 내용 칸 가운데에 단추 테두리 없이 둔다
        ToolbarItem(placement: .principal) { ActivityStatus() }
          .sharedBackgroundVisibility(.hidden)
        // 진행 표시가 비어 있을 때도 자료 넣기 단추가 오른쪽 끝에 남게 한다
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) {
          Button("자료 넣기", systemImage: "tray.and.arrow.down") { model.showIntake = true }
            .help("그날 받은 자료를 넣습니다")
        }
      }
    }
    .searchable(text: $model.searchText, placement: .sidebar, prompt: "찾기 (개념·용어·기호·자료)")
    .searchFocused($searchFocused)
    .onChange(of: model.focusSearchField) { searchFocused = true }
    // 자료와 나란히: 사이드바와 목록 칸을 접어 학습 페이지와 근거 쪽에 폭을 준다
    .onChange(of: model.sideBySide) { SplitColumns.collapseLists(model.sideBySide) }
    .onChange(of: model.selection) {
      if model.sideBySide, !Self.isConcept(model.selection) { model.sideBySide = false }
      // 다른 개념을 열면 페이지 안 찾기 막대를 닫는다 (찾기 결과에서 연 개념은 그 개념의 막대를 이미 열어 두었다)
      if let find = model.pageFind, model.selection != .concept(find.concept) { model.closePageFind() }
    }
    .sheet(isPresented: $model.showIntake) { IntakeSheet() }
    .sheet(item: $model.peek) { SourcePeekSheet(peek: $0) }
    .sheet(item: $model.regenTarget) { RegenSheet(target: $0) }
  }

  static func isConcept(_ s: SubjectSelection?) -> Bool {
    if case .concept = s { return true }
    return false
  }

  private func sectionRow(_ section: SidebarSection) -> some View {
    Label(section.label, systemImage: section.icon).tag(SidebarPick.section(section))
  }

  @ViewBuilder
  private var listColumn: some View {
    switch model.section {
    case .jobs:
      JobsView()
    case .today:
      TodayView()
    case .subjects:
      SubjectsView()
    case .collections:
      CollectionsView()
    }
  }
}

// 내용 칸: 고른 개념의 학습 페이지, 자료의 쪽, 과목의 개념 지도 (오늘, 과목, 모아 보기, 찾기가 같이 쓴다)
struct SelectionDetail: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    switch model.selection {
    case .concept(let id)?:
      if let concept = model.concept(id) {
        ConceptPageView(concept: concept)
      } else {
        ContentUnavailableView("개념을 찾지 못했어요", systemImage: "questionmark.folder")
      }
    case .source(let id)?:
      if let source = model.library.source(id) {
        SourceViewer(source: source).id(source.id)
      } else {
        ContentUnavailableView("자료를 찾지 못했어요", systemImage: "questionmark.folder")
      }
    case .map(let subject)?:
      ConceptMapView(subject: subject).id(subject)
    case .unit(let subject, let key)?:
      UnitOverviewView(subject: subject, key: key).id("\(subject)|\(key)")
    case .entry(let id)?:
      CompendiumEntryView(id: id).id(id)
    case .bundle(let id)?:
      if let bundle = model.bundle(id) {
        BundleDetailView(bundle: bundle).id(bundle.id)
      } else {
        ContentUnavailableView("묶음을 찾지 못했어요", systemImage: "questionmark.folder")
      }
    case .proposal(let job)?:
      if let proposal = model.proposals.first(where: { $0.job == job }) {
        RecurationReview(proposal: proposal).id(job)
      } else {
        ContentUnavailableView("반영했거나 버린 다시 정리예요", systemImage: "checkmark.circle")
      }
    case nil:
      ContentUnavailableView("개념이나 자료를 고르세요", systemImage: "doc.text.magnifyingglass")
    }
  }
}

// 찾은 것: 개념과 그 안의 단위. 누르면 그 개념의 학습 페이지로 간다.
// 세 칸 창의 앞 두 칸(사이드바, 목록)을 접고 편다. NavigationSplitView 의 columnVisibility 는 맥에서 목록 칸을 접지 않아
// 창의 NSSplitViewController 를 직접 다룬다.
@MainActor
enum SplitColumns {
  static func collapseLists(_ on: Bool) {
    guard let window = NSApp.windows.first(where: AppDelegate.isMainWindow), let split = find(window.contentView),
      let controller = split.delegate as? NSSplitViewController
    else { return }
    for item in controller.splitViewItems.dropLast() {
      item.canCollapse = true
      item.animator().isCollapsed = on
    }
  }

  static func find(_ view: NSView?) -> NSSplitView? {
    guard let view else { return nil }
    if let split = view as? NSSplitView { return split }
    return view.subviews.lazy.compactMap { find($0) }.first
  }
}

struct SearchResultsView: View {
  @Environment(AppModel.self) private var model

  // 찾기 (DECISIONS.md 48): 과목 칩, 개념, 용어, 기호, 원래 자료의 쪽. 결과가 없으면 비슷한 말을 제안한다
  var body: some View {
    let q = model.searchText
    let results = model.searchResults
    let terms = model.searchTerms(q)
    let symbols = model.searchSymbols(q)
    let pages = model.searchPageHits
    if results.concepts.isEmpty && terms.isEmpty && symbols.isEmpty && pages.isEmpty {
      ContentUnavailableView {
        Label("찾은 것이 없습니다", systemImage: "magnifyingglass")
      } description: {
        Text(results.suggestions.isEmpty ? "‘\(q)’" : "‘\(q)’ 대신 이 말을 찾을까요?")
      } actions: {
        ForEach(results.suggestions, id: \.self) { s in
          Button(s) { model.searchText = s }
        }
      }
    } else {
      let subject = model.searchSubject
      let concepts = results.concepts.filter { subject == nil || $0.subject == subject }
      let shownTerms = terms.filter { subject == nil || $0.subjects.isEmpty || $0.subjects.contains(subject!) }
      let shownSymbols = symbols.filter { subject == nil || $0.subjects.contains(subject!) }
      let shownPages = pages.filter { subject == nil || model.library.source($0.source)?.labels.labels.subjectID == subject }
      List {
        chips(results.concepts)
        if !concepts.isEmpty {
          Section("개념 · \(concepts.count)") {
            ForEach(concepts) { m in
              row(selected: model.selection == .concept(m.concept), action: { model.openSearchResult(m) }) {
                VStack(alignment: .leading, spacing: 2) {
                  HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(TitleParts(m.title).head).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    if m.count > 0 { Text("\(m.count)곳").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit() }
                  }
                  if let ko = m.titleKo { Text(TitleParts(ko).head).font(.system(size: 12)).foregroundStyle(.secondary) }
                  if let first = m.snippets.first {
                    Text(Self.highlight(TexText.display(first.text))).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                  } else {
                    Text("이름").font(.system(size: 11)).foregroundStyle(.tertiary)
                  }
                }
              }
            }
          }
        }
        if !shownTerms.isEmpty {
          Section("용어 · \(shownTerms.count)") {
            ForEach(shownTerms, id: \.en) { t in
              row(selected: model.selection == .entry("term:\(t.en)"), action: { model.selection = .entry("term:\(t.en)") }) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text(t.en).font(.system(size: 13))
                  Text(t.ko).font(.system(size: 12)).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
        if !shownSymbols.isEmpty {
          Section("기호 · \(shownSymbols.count)") {
            ForEach(shownSymbols, id: \.symbol) { s in
              row(selected: model.selection == .entry("symbol:\(s.symbol)"), action: { model.selection = .entry("symbol:\(s.symbol)") }) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                  Text(TexText.display(s.symbol)).font(.system(size: 14, design: .serif)).italic().frame(minWidth: 34, alignment: .leading)
                  Text(TexText.display(s.meaning)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
        if !shownPages.isEmpty {
          Section("원래 자료 · \(shownPages.count)쪽") {
            ForEach(Dictionary(grouping: shownPages, by: \.source).sorted { $0.key < $1.key }, id: \.key) { source, hits in
              Text(model.library.source(source).map(SourceRow.title) ?? source).font(.system(size: 11.5)).foregroundStyle(.secondary)
              ForEach(hits) { hit in
                row(selected: false, action: { model.peek = SourcePeek(source: hit.source, page: hit.page) }) {
                  HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(hit.page)쪽").font(.system(size: 11.5, weight: .semibold)).monospacedDigit().frame(width: 36, alignment: .leading)
                    Text(Self.highlight(TexText.display(hit.snippet))).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                  }
                }
              }
            }
          }
        }
      }
      .listRowSeparator(.hidden)
    }
  }

  // 결과가 두 과목 이상에 걸치면 과목 칩 (전체, 과목마다 개념 수). 고르면 네 묶음을 모두 그 과목으로 거른다
  @ViewBuilder
  func chips(_ concepts: [ConceptMatch]) -> some View {
    let counts = Dictionary(grouping: concepts, by: \.subject).mapValues(\.count)
    if counts.count >= 2 {
      let order = model.library.subjects.map(\.id).filter { counts[$0] != nil } + counts.keys.filter { id in !model.library.subjects.contains { $0.id == id } }.sorted()
      FlowLayout(spacing: 5) {
        chip("전체 \(concepts.count)", on: model.searchSubject == nil) { model.searchSubject = nil }
        ForEach(order, id: \.self) { id in
          let name = model.library.subjects.first { $0.id == id }?.name ?? id
          chip("\(name) \(counts[id]!)", on: model.searchSubject == id) { model.searchSubject = id }
        }
      }
      .listRowSeparator(.hidden)
      .padding(.bottom, 4)
    }
  }

  func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(label).font(.system(size: 11.5)).monospacedDigit()
        .padding(.horizontal, 9).padding(.vertical, 2)
        .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : .primary)
        .background(Capsule().fill(on ? Color.primary : Color.clear))
        .overlay(Capsule().stroke(Color.primary.opacity(on ? 0 : 0.2)))
    }
    .buttonStyle(.plain)
  }

  func row(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
    Button(action: action) {
      label()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .rowHighlight(selected)
    }
    .buttonStyle(.plain)
    .listRowSeparator(.hidden)
  }

  // 찾은 말(SearchMark.open … close)을 굵게
  static func highlight(_ snippet: String) -> AttributedString {
    var out = AttributedString()
    var bold = false
    var buffer = ""
    func flush() {
      var part = AttributedString(buffer)
      if bold { part.inlinePresentationIntent = .stronglyEmphasized }
      out += part
      buffer = ""
    }
    for ch in snippet {
      if ch == SearchMark.open || ch == SearchMark.close {
        flush()
        bold = ch == SearchMark.open
      } else {
        buffer.append(ch)
      }
    }
    flush()
    return out
  }
}

// 사이드바 아래: 백업, 업데이트, 환경 문제
struct StatusFooter: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let backup = model.backupStatus {
        Label(backup, systemImage: "archivebox").font(.caption)
      }
      switch model.update.state {
      case .waiting(let version):
        Label("업데이트 \(version) 대기 중 · 지금 작업이 끝나면 설치", systemImage: "arrow.down.circle").font(.caption)
      case .installing(let version):
        Label("업데이트 \(version) 설치 중", systemImage: "arrow.down.circle").font(.caption)
      default:
        EmptyView()
      }
      if !model.doctorFailures.isEmpty {
        Label("준비가 덜 된 것이 있습니다. 설정의 환경 점검에서 봅니다.", systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }
      // 데이터 리포에 올리지 못했거나 받지 못했다 (DATA.md 의 데이터 리포)
      if let problem = model.repoProblem {
        VStack(alignment: .leading, spacing: 4) {
          Label(model.repo?.error != nil ? "데이터 리포에 올리지 못했습니다" : "데이터 리포에서 받지 못했습니다", systemImage: "exclamationmark.icloud")
            .font(.caption).foregroundStyle(.orange)
          Text(problem).font(.caption2).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
          Button(model.repoSyncing ? "올리는 중…" : "다시 올리기") { model.syncNow() }
            .controlSize(.small)
            .disabled(model.repoSyncing)
        }
      }
      // 자료 버킷에 올리지 못했거나 받지 못했다 (DATA.md 의 자료 버킷)
      if let problem = model.bucket?.error {
        VStack(alignment: .leading, spacing: 4) {
          Label("자료 버킷에 올리지 못했습니다", systemImage: "exclamationmark.icloud")
            .font(.caption).foregroundStyle(.orange)
          Text(problem).font(.caption2).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
          Button(model.bucketSyncing ? "올리는 중…" : "다시 올리기") { model.syncBucket() }
            .controlSize(.small)
            .disabled(model.bucketSyncing)
        }
      }
      Text("Jindesk \(model.app.app)").font(.caption2).foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
