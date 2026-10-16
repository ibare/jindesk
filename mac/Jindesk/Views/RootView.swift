import JindeskKit
import SwiftUI

// 켤 때의 상태에 따라 화면을 고른다
struct RootView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    switch model.phase {
    case .starting:
      ProgressView("여는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
    case .choosingFolder(let message):
      FolderSetupView(message: message)
    case .migrating(let message):
      StatusScreen(icon: "arrow.triangle.2.circlepath", title: "데이터를 새 모양으로 바꾸고 있습니다", detail: message, busy: true)
    case .migrationFailed(let message):
      MigrationFailedView(message: message)
    case .newerData(let version):
      StatusScreen(
        icon: "arrow.down.circle", title: "이 데이터는 더 새 판의 Jindesk 가 만들었습니다",
        detail: "데이터의 스키마는 \(version), 이 앱은 \(CurrentSchema.version) 입니다. 앱을 업데이트합니다. 업데이트가 오지 않으면 관리자에게 알려 주세요.",
        busy: false)
    case .unusable(let message):
      StatusScreen(icon: "exclamationmark.triangle", title: "데이터 폴더를 열 수 없습니다", detail: message, busy: false)
    case .ready:
      MainView()
    }
  }
}

struct StatusScreen: View {
  let icon: String
  let title: String
  let detail: String
  let busy: Bool

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
      Text(title).font(.title2.weight(.semibold))
      Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
      if busy { ProgressView().controlSize(.small) }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// 마이그레이션이 실패했을 때: 원래 데이터는 그대로다. 다시 시도하거나 이전 판 앱을 받는다 (MIGRATION.md).
struct MigrationFailedView: View {
  @Environment(AppModel.self) private var model
  let message: String

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.orange)
      Text("데이터를 새 모양으로 바꾸지 못했습니다").font(.title2.weight(.semibold))
      Text("원래 데이터 폴더는 그대로입니다. 그동안은 데이터를 열지 않습니다.").foregroundStyle(.secondary)
      ScrollView {
        Text(message).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: 560, maxHeight: 180)
      .padding(10)
      .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
      HStack {
        Button("다시 시도") { Task { await model.retryMigration() } }.keyboardShortcut(.defaultAction)
        Button("이전 판 앱 받기") {
          NSWorkspace.shared.open(URL(string: "https://github.com/ibare/jindesk/releases")!)
        }
      }
      Text("이전 판 앱은 릴리즈 페이지에서 받을 수 있습니다. 관리자에게 알려 주세요.").font(.callout).foregroundStyle(.secondary)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
