import JindeskKit
import SwiftUI

// 메인 창: 사이드바(오늘, 과목, 모아 보기, 작업)와 그 내용
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
    } detail: {
      if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
        SearchResultsView()
      } else {
        sectionView
      }
    }
    .searchable(text: $model.searchText, placement: .sidebar, prompt: "개념 찾기 (영어·한국어)")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("자료 넣기", systemImage: "tray.and.arrow.down") { model.showIntake = true }
          .help("그날 받은 자료를 넣습니다")
      }
    }
    .sheet(isPresented: $model.showIntake) { IntakeSheet() }
  }

  @ViewBuilder
  private var sectionView: some View {
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
          model.section = .subjects
          model.selection = .concept(hit.concept)
          model.searchText = ""
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
        Label("준비가 덜 된 것이 있습니다. 관리자에게 알려 주세요.", systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }
      Text("Jindesk \(model.app.app)").font(.caption2).foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
