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
    .searchable(text: $model.searchText, placement: .sidebar, prompt: "개념 찾기 (영어·한국어)")
    .sheet(isPresented: $model.showIntake) { IntakeSheet() }
    .sheet(item: $model.peek) { SourcePeekSheet(peek: $0) }
    .sheet(item: $model.regenTarget) { RegenSheet(target: $0) }
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
    case nil:
      ContentUnavailableView("개념이나 자료를 고르세요", systemImage: "doc.text.magnifyingglass")
    }
  }
}

// 찾은 것: 개념과 그 안의 단위. 누르면 그 개념의 학습 페이지로 간다.
struct SearchResultsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let hits = model.searchResults
    if hits.isEmpty {
      ContentUnavailableView.search(text: model.searchText)
    } else {
      List(hits) { hit in
        Button {
          model.selection = .concept(hit.concept)
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              Text(hit.title).font(.body.weight(.medium))
              if let ko = hit.titleKo { Text(ko).font(.caption).foregroundStyle(.secondary) }
            }
            Text(Self.highlight(hit.snippet)).font(.callout).foregroundStyle(.secondary).lineLimit(3)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }

  // 찾은 말(SearchHit.open … close)을 굵게
  static func highlight(_ snippet: String) -> AttributedString {
    var out = AttributedString()
    var bold = false
    var buffer = ""
    func flush() {
      var part = AttributedString(buffer)
      if bold { part.font = .callout.bold() }
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
