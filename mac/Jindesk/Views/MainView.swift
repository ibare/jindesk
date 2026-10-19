import JindeskKit
import SwiftUI

// 메인 창: 세 칸이다. 사이드바(오늘, 과목, 모아 보기, 작업) · 목록 · 내용(학습 페이지, 자료, 작업 기록)
struct MainView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    NavigationSplitView {
      List(selection: $model.section) {
        ForEach(SidebarSection.allCases) { section in
          Label(section.label, systemImage: section.icon).tag(section)
        }
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
    // 자료와 나란히: 사이드바와 목록 칸을 접어 학습 페이지와 근거 쪽에 폭을 준다
    .onChange(of: model.sideBySide) { SplitColumns.collapseLists(model.sideBySide) }
    .onChange(of: model.selection) { if model.sideBySide, !Self.isConcept(model.selection) { model.sideBySide = false } }
    .sheet(isPresented: $model.showIntake) { IntakeSheet() }
    .sheet(item: $model.peek) { SourcePeekSheet(peek: $0) }
    .sheet(item: $model.regenTarget) { RegenSheet(target: $0) }
  }

  static func isConcept(_ s: SubjectSelection?) -> Bool {
    if case .concept = s { return true }
    return false
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

  // 찾기 (DECISIONS.md 34): 개념, 용어, 기호, 원래 자료의 쪽으로 묶는다
  var body: some View {
    let q = model.searchText
    let hits = model.searchResults
    let terms = model.searchTerms(q)
    let symbols = model.searchSymbols(q)
    let pages = model.searchPageHits
    if hits.isEmpty && terms.isEmpty && symbols.isEmpty && pages.isEmpty {
      ContentUnavailableView.search(text: q)
    } else {
      List {
        if !hits.isEmpty {
          // 개념마다 한 줄: 처음 찾은 곳과 찾은 곳의 수
          let grouped = Self.byConcept(hits)
          Section("개념 · \(grouped.count)") {
            ForEach(grouped, id: \.first.concept) { g in
              row(selected: model.selection == .concept(g.first.concept), action: { model.selection = .concept(g.first.concept) }) {
                VStack(alignment: .leading, spacing: 3) {
                  HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(TitleParts(g.first.title).head).font(.system(size: 13, weight: .semibold))
                    if let ko = g.first.titleKo { Text(TitleParts(ko).head).font(.system(size: 12)).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    if g.count > 1 { Text("\(g.count)곳").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit() }
                  }
                  Text(Self.highlight(TexText.display(g.first.snippet))).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
              }
            }
          }
        }
        if !terms.isEmpty {
          Section("용어 · \(terms.count)") {
            ForEach(terms, id: \.en) { t in
              row(selected: model.selection == .entry("term:\(t.en)"), action: { model.selection = .entry("term:\(t.en)") }) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text(t.en).font(.system(size: 13))
                  Text(t.ko).font(.system(size: 12)).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
        if !symbols.isEmpty {
          Section("기호 · \(symbols.count)") {
            ForEach(symbols, id: \.symbol) { s in
              row(selected: model.selection == .entry("symbol:\(s.symbol)"), action: { model.selection = .entry("symbol:\(s.symbol)") }) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                  Text(TexText.display(s.symbol)).font(.system(size: 14, design: .serif)).italic().frame(minWidth: 34, alignment: .leading)
                  Text(TexText.display(s.meaning)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
        if !pages.isEmpty {
          Section("원래 자료 · \(pages.count)쪽") {
            ForEach(Dictionary(grouping: pages, by: \.source).sorted { $0.key < $1.key }, id: \.key) { source, hits in
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

  // 찾은 곳을 개념마다 묶는다 (처음 찾은 곳, 수). 차례는 처음 나온 차례 (FTS 순위)
  static func byConcept(_ hits: [SearchHit]) -> [(first: SearchHit, count: Int)] {
    var out: [(first: SearchHit, count: Int)] = []
    for h in hits {
      if let i = out.firstIndex(where: { $0.first.concept == h.concept }) { out[i].count += 1 } else { out.append((h, 1)) }
    }
    return out
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

  // 찾은 말(SearchHit.open … close)을 굵게
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
      if ch == SearchHit.open || ch == SearchHit.close {
        flush()
        bold = ch == SearchHit.open
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
