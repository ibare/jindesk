import AppKit
import JindeskKit
import SwiftUI

// 처음 켤 때 데이터 리포를 연결한다 (DATA.md 의 데이터 리포). 데이터 폴더는 이 리포의 클론이다.
struct RepoSetupView: View {
  let message: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Jindesk 데이터 리포").font(.title.weight(.semibold))
      Text("학교에서 받은 자료와 정리한 내용, 코멘트가 모두 데이터 폴더에 쌓입니다. 데이터 폴더는 GitHub 비공개 리포의 클론이고, 이 앱이 커밋해 올리면 폰 앱이 받아 읽습니다.")
        .foregroundStyle(.secondary)
      if let message {
        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
      }
      RepoConnectForm(suggestedPath: DataFolder.defaultURL.path, followsRepoName: false)
    }
    .padding(40)
    .frame(maxWidth: 680)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// 리포 주소, 쓰기 토큰, 로컬 위치를 넣고 연결한다. 처음 켤 때와 관리자 설정의 "리포 바꾸기"에서 쓴다.
struct RepoConnectForm: View {
  @Environment(AppModel.self) private var model
  let suggestedPath: String
  // 로컬 위치를 리포 이름에 맞춰 제안한다 (리포 바꾸기: 이전 클론과 다른 폴더여야 한다)
  let followsRepoName: Bool
  var onConnected: (() -> Void)?
  @State private var url = ""
  @State private var token = ""
  @State private var path = ""
  @State private var pathEdited = false
  @State private var error: String?
  @State private var busy = false

  var body: some View {
    Form {
      LabeledContent("리포 주소") {
        TextField("리포 주소", text: $url, prompt: Text("https://github.com/<주인>/jindesk-data")).labelsHidden()
      }
      LabeledContent("쓰기 토큰") {
        SecureField("쓰기 토큰", text: $token, prompt: Text(model.repoTokenSaved ? "키체인에 있음 · 바꾸려면 새 토큰" : "github_pat_…")).labelsHidden()
      }
      Text("그 리포만 고른 fine-grained 토큰이고, 권한은 Contents: Read and write 입니다. 키체인에 둡니다.")
        .font(.caption).foregroundStyle(.secondary)
      LabeledContent("로컬 위치") {
        HStack {
          TextField("로컬 위치", text: Binding(get: { path }, set: { path = $0; pathEdited = true })).labelsHidden()
          Button("고르기…") { choose() }
        }
      }
      Text("없거나 빈 폴더, 또는 이미 그 리포의 클론인 폴더입니다. 빈 리포면 데이터 폴더를 새로 만들어 첫 커밋을 올리고, Jindesk 데이터 리포면 클론합니다.")
        .font(.caption).foregroundStyle(.secondary)
      if let error {
        Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout).textSelection(.enabled)
      }
      HStack {
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        Button(busy ? "연결하는 중…" : "연결") { connect() }
          .keyboardShortcut(.defaultAction)
          .disabled(!ready)
      }
    }
    .formStyle(.grouped)
    .onAppear { if path.isEmpty { path = suggestedPath } }
    .onChange(of: url) {
      guard followsRepoName, !pathEdited, let name = Self.repoName(url) else { return }
      path = (suggestedPath as NSString).deletingLastPathComponent + "/Jindesk-" + name
    }
  }

  private var ready: Bool {
    !busy && url.nilIfBlank != nil && path.nilIfBlank != nil && (token.nilIfBlank != nil || model.repoTokenSaved)
  }

  private func connect() {
    busy = true
    error = nil
    Task {
      let problem = await model.connect(url: url, token: token, path: path)
      busy = false
      if let problem {
        error = problem
      } else {
        token = ""
        onConnected?()
      }
    }
  }

  // 리포 주소의 마지막 이름 (https://github.com/a/jindesk-data.git → jindesk-data)
  static func repoName(_ url: String) -> String? {
    var name = (url.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
    if name.hasSuffix(".git") { name.removeLast(4) }
    return name.nilIfBlank
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "고르기"
    panel.message = "비어 있는 폴더나 이미 그 리포의 클론인 폴더를 고르세요. iCloud 로 동기화되는 폴더는 피하세요."
    if panel.runModal() == .OK, let picked = panel.url {
      path = picked.path
      pathEdited = true
    }
  }
}
