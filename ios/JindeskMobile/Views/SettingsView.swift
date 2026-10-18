// 설정: 데이터 리포(주인, 이름, 가지)와 읽기 토큰, 마지막 받기 결과 (SETUP.md 의 폰 앱)
import SwiftUI

struct SettingsView: View {
  @Environment(MobileModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var draft = RepoConfig()
  @State private var token = ""
  @State private var bucket = ""
  @State private var bucketID = ""
  @State private var bucketSecret = ""
  @State private var message: String?
  @State private var confirmClear = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          field("주인", $draft.owner, prompt: "GitHub 사용자나 조직")
          field("리포", $draft.name, prompt: "jindesk-data")
          field("가지", $draft.branch, prompt: "main")
        } header: {
          Text("데이터 리포")
        } footer: {
          Text("맥의 Jindesk 가 데이터 폴더를 올리는 비공개 리포입니다.")
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        Section {
          SecureField(model.hasToken ? "키체인에 있음 · 바꾸려면 새 토큰" : "github_pat_…", text: $token)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          if model.hasToken {
            Button("토큰 지우기", role: .destructive) {
              do { try model.deleteToken() } catch { message = error.localizedDescription }
            }
          }
        } header: {
          Text("읽기 토큰")
        } footer: {
          Text("이 리포만 고른 fine-grained 토큰이고, 권한은 Contents: Read-only 입니다. 폰의 키체인에 둡니다.")
        }
        Section {
          field("버킷", $bucket, prompt: "jindesk-files")
          SecureField(model.hasBucketKey ? "키체인에 있음 · 바꾸려면 새 접근 id" : "접근 id", text: $bucketID)
          SecureField(model.hasBucketKey ? "바꾸려면 새 비밀" : "비밀", text: $bucketSecret)
        } header: {
          Text("자료 버킷")
        } footer: {
          Text("원래 자료의 쪽 이미지를 받는 곳입니다. 폰용 읽기 전용 HMAC 키를 넣습니다. 폰의 키체인에 둡니다.")
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        Section("받기") {
          SyncStatusRow()
          Button("지금 받기") {
            Task {
              await save()
              await model.sync(force: true)
            }
          }
          .disabled(!draft.isComplete || isSyncing)
          Button("받아 둔 것 지우기", role: .destructive) { confirmClear = true }
            .disabled(model.manifest == nil || isSyncing)
        }
        if let message { Text(message).font(.footnote).foregroundStyle(.red) }
      }
      .navigationTitle("설정")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("완료") {
            Task {
              await save()
              if message == nil { dismiss() }
            }
          }
        }
      }
      .confirmationDialog("받아 둔 학습 페이지를 모두 지웁니다. 다음 받기에서 처음부터 받습니다.", isPresented: $confirmClear, titleVisibility: .visible) {
        Button("지우기", role: .destructive) { model.clearMirror() }
      }
      .onAppear {
        draft = model.config
        bucket = model.bucketName
      }
    }
  }

  private func field(_ label: String, _ text: Binding<String>, prompt: String) -> some View {
    LabeledContent(label) {
      TextField(label, text: text, prompt: Text(prompt)).multilineTextAlignment(.trailing)
    }
  }

  private var isSyncing: Bool {
    if case .syncing = model.state { return true }
    return false
  }

  private func save() async {
    do {
      try model.save(draft, token: token)
      try model.saveBucket(name: bucket, accessID: bucketID, secret: bucketSecret)
      token = ""
      bucketID = ""
      bucketSecret = ""
      message = nil
    } catch {
      message = error.localizedDescription
    }
  }
}
