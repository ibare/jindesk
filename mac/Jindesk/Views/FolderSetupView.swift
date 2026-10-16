import JindeskKit
import SwiftUI

// 처음 켤 때 데이터 폴더를 고른다. 기본은 ~/Jindesk 다 (DATA.md).
struct FolderSetupView: View {
  @Environment(AppModel.self) private var model
  let message: String?
  @State private var url = DataFolder.defaultURL

  var body: some View {
    let folder = DataFolder(url)
    let issues = folder.issues(appBundle: AppPaths.bundle)
    VStack(alignment: .leading, spacing: 18) {
      Text("Jindesk 데이터 폴더").font(.title.weight(.semibold))
      Text("학교에서 받은 자료와 정리한 내용, 코멘트가 모두 이 폴더에 쌓입니다. 백업은 이 폴더를 통째로 합니다.")
        .foregroundStyle(.secondary)
      if let message {
        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
      }
      HStack {
        Image(systemName: "folder")
        Text(url.path).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
        Spacer()
        Button("다른 폴더 고르기…") { choose() }
      }
      .padding(12)
      .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
      Text(folder.isInitialized ? "이미 있는 Jindesk 데이터 폴더입니다. 그대로 엽니다." : "비어 있거나 없는 폴더면 새로 만듭니다.")
        .font(.callout).foregroundStyle(.secondary)
      ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
        Label(issue.message, systemImage: issue.isError ? "xmark.octagon" : "exclamationmark.triangle")
          .foregroundStyle(issue.isError ? .red : .orange)
          .font(.callout)
      }
      HStack {
        Spacer()
        Button("이 폴더 쓰기") { Task { await model.useFolder(url) } }
          .keyboardShortcut(.defaultAction)
          .disabled(issues.contains(where: \.isError))
      }
    }
    .padding(40)
    .frame(maxWidth: 640)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "고르기"
    panel.message = "비어 있는 폴더나 이미 있는 Jindesk 데이터 폴더를 고르세요. iCloud 로 동기화되는 폴더는 피하세요."
    if panel.runModal() == .OK, let picked = panel.url { url = picked }
  }
}
