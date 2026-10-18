import JindeskKit
import SwiftUI

// 관리자 설정: 토큰, 모델과 상한, 동시 실행 수, 환경 점검, 데이터 폴더, 데이터 리포, 업데이트. 학생 화면에서는 감춘다.
struct AdminSettingsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    TabView(selection: $model.adminTab) {
      Tab("계정과 실행", systemImage: "key", value: AdminTab.run) { RunSettingsPane() }
      Tab("환경 점검", systemImage: "stethoscope", value: AdminTab.doctor) { DoctorPane() }
      Tab("데이터와 업데이트", systemImage: "externaldrive", value: AdminTab.data) { DataPane() }
    }
    .padding(16)
  }
}

enum AdminTab: Hashable {
  case run, doctor, data
}

struct RunSettingsPane: View {
  @Environment(AppModel.self) private var model
  @State private var token = ""
  @State private var tokenMessage: String?
  @State private var draft = AdminSettings()
  @State private var loaded = false

  var body: some View {
    Form {
      Section("Claude 토큰") {
        LabeledContent("키체인") {
          Text(model.tokenSaved ? "있음 (\(ClaudeToken.service) · \(ClaudeToken.account))" : "없음").foregroundStyle(model.tokenSaved ? Color.primary : .red)
        }
        SecureField("claude setup-token 으로 만든 토큰", text: $token)
        HStack {
          Button("키체인에 저장") {
            do {
              try model.saveToken(token)
              token = ""
              tokenMessage = "저장했습니다"
            } catch {
              tokenMessage = error.localizedDescription
            }
          }
          .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button("지우기", role: .destructive) {
            do {
              try model.deleteToken()
              tokenMessage = "지웠습니다"
            } catch {
              tokenMessage = error.localizedDescription
            }
          }
          .disabled(!model.tokenSaved)
          if let tokenMessage { Text(tokenMessage).font(.caption).foregroundStyle(.secondary) }
        }
      }
      Section("실행") {
        TextField("모델", text: optionalText(\.model), prompt: Text(RunnerConfig.defaultModel))
        Picker("effort", selection: $draft.effort) {
          Text("기본 (\(AdminSettings.defaults.effort.rawValue))").tag(Effort?.none)
          ForEach(Effort.allCases, id: \.self) { Text($0.rawValue).tag(Effort?.some($0)) }
        }
        TextField("최대 턴", value: $draft.maxTurns, format: .number, prompt: Text("\(AdminSettings.defaults.maxTurns)"))
        TextField("예산 (USD, 추정)", value: $draft.maxBudgetUSD, format: .number, prompt: Text("\(Int(AdminSettings.defaults.maxBudgetUSD))"))
        TextField("시간 상한 (분, 깨어 있던 시간)", value: $draft.timeoutMinutes, format: .number, prompt: Text("\(Int(AdminSettings.defaults.timeoutMinutes))"))
        TextField("사용량 미루기 기준 (5시간 %, 0 이면 미루지 않음)", value: $draft.holdAtPercent, format: .number, prompt: Text("\(AdminSettings.defaults.holdAtPercent)"))
        TextField("claude 경로 (비우면 찾은 위치)", text: optionalText(\.claudePath), prompt: Text("~/.local/bin/claude"))
      }
      Section("함께 도는 작업 수") {
        ForEach(JobLane.allCases.filter(\.adjustable), id: \.self) { lane in
          Stepper("\(lane.label): \(draft.limit(lane))", value: laneBinding(lane), in: JobManager.concurrencyRange)
        }
      }
      HStack {
        Spacer()
        Button("되돌리기") { draft = model.admin }.disabled(draft == model.admin)
        Button("저장") { model.saveAdmin(draft) }.keyboardShortcut(.defaultAction).disabled(draft == model.admin)
      }
    }
    .formStyle(.grouped)
    .onAppear {
      guard !loaded else { return }
      draft = model.admin
      loaded = true
    }
  }

  private func optionalText(_ key: WritableKeyPath<AdminSettings, String?>) -> Binding<String> {
    Binding(get: { draft[keyPath: key] ?? "" }, set: { draft[keyPath: key] = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
  }

  private func laneBinding(_ lane: JobLane) -> Binding<Int> {
    Binding(get: { draft.limit(lane) }, set: { draft.laneLimits[lane.rawValue] = $0 })
  }
}

struct DoctorPane: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("작업을 돌리기 전에 필요한 것이 갖춰졌는지 봅니다. 토큰 값은 읽지 않습니다.").font(.callout).foregroundStyle(.secondary)
        Spacer()
        Button("다시 점검") { Task { await model.runDoctor() } }.disabled(model.doctorRunning)
      }
      if model.doctorRunning { ProgressView().controlSize(.small) }
      List(model.doctor) { item in
        HStack(alignment: .firstTextBaseline) {
          Image(systemName: item.status == .ok ? "checkmark.circle.fill" : item.status == .warn ? "exclamationmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(item.status == .ok ? .green : item.status == .warn ? .orange : .red)
          VStack(alignment: .leading) {
            Text(item.name).font(.callout.weight(.medium))
            Text(item.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
      }
    }
    .padding(8)
  }
}

struct DataPane: View {
  @Environment(AppModel.self) private var model
  @State private var newToken = ""
  @State private var tokenMessage: String?
  @State private var changingRepo = false
  @State private var bucketName = ""
  @State private var bucketAccessID = ""
  @State private var bucketSecret = ""
  @State private var bucketMessage: String?

  var body: some View {
    Form {
      Section("데이터 폴더") {
        LabeledContent("위치") { Text(model.data?.path ?? "없음").textSelection(.enabled) }
        Button("Finder 에서 보기") { if let data = model.data { model.reveal(data.url) } }
        LabeledContent("스키마") { Text("\(CurrentSchema.version)") }
        LabeledContent("앱 지원 폴더") { Text(model.folders.support.path).textSelection(.enabled) }
        LabeledContent("캐시") { Text(model.folders.cache.path).textSelection(.enabled) }
        if !model.notes.isEmpty {
          LabeledContent("켤 때 한 일") { Text(model.notes.joined(separator: "\n")).font(.caption) }
        }
      }
      // DATA.md 의 데이터 리포. 이 맥의 앱 설정에 두는 연결이다.
      Section("데이터 리포") {
        LabeledContent("리포") { Text(model.repoLink?.url ?? "연결하지 않았습니다").textSelection(.enabled) }
        LabeledContent("토큰") { Text(model.repoTokenSaved ? "키체인에 있음" : "없음").foregroundStyle(model.repoTokenSaved ? Color.primary : .red) }
        HStack {
          SecureField("새 토큰", text: $newToken, prompt: Text("바꿀 때만 넣습니다"))
          Button("토큰 바꾸기") {
            do {
              try model.saveRepoToken(newToken)
              newToken = ""
              tokenMessage = "바꿨습니다"
            } catch {
              tokenMessage = error.localizedDescription
            }
          }
          .disabled(newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if let tokenMessage { Text(tokenMessage).font(.caption).foregroundStyle(.secondary) }
        if let repo = model.repo {
          LabeledContent("마지막") { Text(repoText(repo)) }
          if let error = repo.error { LabeledContent("오류") { Text(error).font(.caption).textSelection(.enabled) } }
          if !repo.excluded.isEmpty {
            LabeledContent("100MB 이상이라 뺀 파일") { Text(repo.excluded.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
          }
        }
        if let pull = model.repoPullProblem { LabeledContent("받기") { Text(pull).font(.caption).textSelection(.enabled) } }
        HStack {
          Button(model.repoSyncing ? "올리는 중…" : "지금 올리기") { model.syncNow() }.disabled(model.repoSyncing || model.repoLink == nil)
          Button("리포 바꾸기…") { changingRepo = true }.disabled(model.isBusy)
        }
      }
      // DATA.md 의 자료 버킷. 원본 자료와 쪽 이미지를 둔다. 개발 맥과 학생 맥의 버킷이 다르다.
      Section("자료 버킷") {
        TextField("버킷 이름", text: $bucketName, prompt: Text("jindesk-files"))
        LabeledContent("쓰기 키") { Text(model.bucketKeySaved ? "키체인에 있음" : "없음").foregroundStyle(model.bucketKeySaved ? Color.primary : .red) }
        TextField("접근 id", text: $bucketAccessID, prompt: Text(model.bucketKeySaved ? "바꿀 때만 넣습니다" : "GOOG1…"))
        SecureField("비밀", text: $bucketSecret, prompt: Text(model.bucketKeySaved ? "바꿀 때만 넣습니다" : ""))
        if let bucket = model.bucket {
          LabeledContent("마지막") {
            Text("\(bucket.at.prefix(16).replacingOccurrences(of: "T", with: " ")) · 올림 \(bucket.uploaded) · 받음 \(bucket.downloaded)")
          }
          if let error = bucket.error { LabeledContent("오류") { Text(error).font(.caption).textSelection(.enabled) } }
        }
        if let bucketMessage { Text(bucketMessage).font(.caption).foregroundStyle(.secondary) }
        HStack {
          Button("저장하고 맞추기") {
            do {
              try model.saveBucket(name: bucketName, accessID: bucketAccessID, secret: bucketSecret)
              bucketAccessID = ""
              bucketSecret = ""
              bucketMessage = "저장했습니다"
            } catch {
              bucketMessage = error.localizedDescription
            }
          }
          .disabled(bucketName.trimmingCharacters(in: .whitespaces).isEmpty)
          Button(model.bucketSyncing ? "맞추는 중…" : "지금 맞추기") { model.syncBucket() }.disabled(model.bucketSyncing || model.bucketLink == nil)
        }
      }
      Section("업데이트") {
        LabeledContent("이 앱") { Text(model.app.label) }
        LabeledContent("상태") { Text(updateText) }
        if let last = model.update.lastCheck { LabeledContent("마지막 확인") { Text(last.formatted()) } }
        if let error = model.update.lastError { LabeledContent("마지막 오류") { Text(error).font(.caption) } }
        Button("지금 확인") { model.updater?.checkNow() }.disabled(updateDisabled)
      }
    }
    .formStyle(.grouped)
    .onAppear { if bucketName.isEmpty { bucketName = model.bucketLink?.name ?? "" } }
    .sheet(isPresented: $changingRepo) {
      VStack(alignment: .leading, spacing: 8) {
        Text("리포 바꾸기").font(.headline)
        Text("새 리포를 연결하고 그 클론을 데이터 폴더로 엽니다. 이전 리포와 그 폴더는 그대로 남습니다.")
          .font(.callout).foregroundStyle(.secondary)
        RepoConnectForm(suggestedPath: DataFolder.defaultURL.path, followsRepoName: true) { changingRepo = false }
        HStack {
          Spacer()
          Button("닫기") { changingRepo = false }.keyboardShortcut(.cancelAction)
        }
      }
      .padding(18)
      .frame(width: 600)
    }
  }

  private var updateText: String {
    switch model.update.state {
    case .disabled(let reason): reason
    case .idle: "자동으로 확인합니다 (켤 때와 6시간마다)"
    case .waiting(let v): "\(v) 를 내려받았습니다 · 지금 작업이 끝나면 설치"
    case .installing(let v): "\(v) 설치 중"
    }
  }

  private func repoText(_ repo: DataRepo.Outcome) -> String {
    let at = repo.at.prefix(16).replacingOccurrences(of: "T", with: " ")
    let head = repo.head.map { "커밋 \($0.prefix(7))" } ?? "커밋 없음"
    return "\(at) · \(head) · \(repo.pushed ? "올림" : "올리지 못함")"
  }

  private var updateDisabled: Bool {
    if case .idle = model.update.state { return false }
    return true
  }
}
