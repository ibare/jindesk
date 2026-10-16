import JindeskKit
import SwiftUI

// 관리자 설정: 토큰, 모델과 상한, 동시 실행 수, 웹 금지어, 환경 점검, 데이터 폴더, 업데이트. 학생 화면에서는 감춘다.
struct AdminSettingsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    TabView(selection: $model.adminTab) {
      Tab("계정과 실행", systemImage: "key", value: AdminTab.run) { RunSettingsPane() }
      Tab("웹 금지어", systemImage: "hand.raised", value: AdminTab.privacy) { PrivacyPane() }
      Tab("환경 점검", systemImage: "stethoscope", value: AdminTab.doctor) { DoctorPane() }
      Tab("데이터와 업데이트", systemImage: "externaldrive", value: AdminTab.data) { DataPane() }
    }
    .padding(16)
  }
}

enum AdminTab: Hashable {
  case run, privacy, doctor, data
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

struct PrivacyPane: View {
  @Environment(AppModel.self) private var model
  @State private var text = ""
  @State private var message: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("학생·학교·선생님 이름을 한 줄에 하나씩 적습니다. 에이전트가 웹을 찾을 때 검색어와 주소에 이 말이 있으면 막습니다. 이 목록은 데이터 폴더의 meta/privacy.yaml 에만 있고 밖으로 나가지 않습니다.")
        .font(.callout).foregroundStyle(.secondary)
      TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 200).border(.quaternary)
      HStack {
        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        Spacer()
        Button("저장") {
          do {
            try model.savePrivacy(text)
            message = "저장했습니다 (\(model.privacy.terms.count)개)"
          } catch {
            message = error.localizedDescription
          }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(8)
    .onAppear { text = model.privacy.terms.joined(separator: "\n") }
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

  var body: some View {
    Form {
      Section("데이터 폴더") {
        LabeledContent("위치") { Text(model.data?.path ?? "없음").textSelection(.enabled) }
        HStack {
          Button("Finder 에서 보기") { if let data = model.data { model.reveal(data.url) } }
          Button("다른 폴더로 바꾸기…") { change() }.disabled(model.isBusy)
        }
        LabeledContent("스키마") { Text("\(CurrentSchema.version)") }
        LabeledContent("앱 지원 폴더") { Text(model.folders.support.path).textSelection(.enabled) }
        LabeledContent("캐시") { Text(model.folders.cache.path).textSelection(.enabled) }
        if !model.notes.isEmpty {
          LabeledContent("켤 때 한 일") { Text(model.notes.joined(separator: "\n")).font(.caption) }
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
  }

  private var updateText: String {
    switch model.update.state {
    case .disabled(let reason): reason
    case .idle: "자동으로 확인합니다 (켤 때와 6시간마다)"
    case .waiting(let v): "\(v) 를 내려받았습니다 · 지금 작업이 끝나면 설치"
    case .installing(let v): "\(v) 설치 중"
    }
  }

  private var updateDisabled: Bool {
    if case .idle = model.update.state { return false }
    return true
  }

  private func change() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "이 폴더 쓰기"
    panel.message = "비어 있는 폴더나 이미 있는 Jindesk 데이터 폴더(되살린 백업 포함)를 고르세요."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await model.useFolder(url) }
  }
}
