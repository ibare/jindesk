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
      switch model.section {
      case .jobs:
        JobsView()
      case .today:
        ContentUnavailableView("오늘 볼 것이 아직 없어요", systemImage: "sun.max", description: Text("자료를 넣고 정리가 끝나면 여기에 다시 볼 개념과 새로 정리된 개념이 보입니다."))
      case .subjects:
        SubjectsView()
      case .collections:
        ContentUnavailableView("모아 볼 것이 아직 없어요", systemImage: "square.stack", description: Text("과목 사이 연결, 원래 자료, 확인 문제, 코멘트를 여기서 모아 봅니다."))
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("자료 넣기", systemImage: "tray.and.arrow.down") { model.showIntake = true }
          .help("그날 받은 자료를 넣습니다")
      }
    }
    .sheet(isPresented: $model.showIntake) { IntakeSheet() }
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
