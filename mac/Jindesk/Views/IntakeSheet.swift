import JindeskKit
import SwiftUI
import UniformTypeIdentifiers

// 자료 넣기: 그날 받은 파일 몇 개를 넣고, 그 자료가 무슨 자료인지 꼬리표(학년, 과목, 수준)를 붙인다.
// 꼬리표는 이전에 쓴 값과 미리 준비한 값에서 고르거나 직접 적는다. 기본값은 마지막에 쓴 값이다 (DECISIONS.md 21).
struct IntakeSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var files: [URL] = []
  @State private var plan: [IntakeCandidate] = []
  @State private var planning = false
  @State private var labels = LabelDraft()
  @State private var memo = ""
  @State private var syllabusBasis = false
  @State private var error: String?
  @State private var submitting = false
  @State private var targeted = false

  var body: some View {
    let accepted = plan.filter { $0.status.accepted }.count
    VStack(alignment: .leading, spacing: 14) {
      Text("자료 넣기").font(.title2.weight(.semibold))
      fileArea
      LabelFields(draft: $labels, library: model.library)
      TextField("메모 (적지 않아도 됩니다)", text: $memo)
      Toggle("목차의 근거 (과목 가이드, 과정·단원 안내)", isOn: $syllabusBasis)
      if let error { Text(error).font(.callout).foregroundStyle(.red) }
      HStack {
        if labels.subject.trimmingCharacters(in: .whitespaces).isEmpty, !files.isEmpty {
          Text("과목을 적어 주세요").font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(accepted > 1 ? "\(accepted)개 넣기" : "넣기") { submit() }
          .keyboardShortcut(.defaultAction)
          .disabled(accepted == 0 || planning || submitting || labels.subject.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 620)
    .onAppear { labels = LabelDraft(model.library.lastLabels) }
  }

  private var fileArea: some View {
    VStack(alignment: .leading, spacing: 8) {
      if files.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "tray.and.arrow.down").font(.system(size: 30)).foregroundStyle(.secondary)
          Text("여기에 파일을 끌어다 놓으세요").foregroundStyle(.secondary)
          Button("파일 고르기…") { choose() }
          Text("PDF, PPT·PPTX·KEY, DOC·DOCX·PAGES, JPEG·PNG·HEIC").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(plan) { c in
              HStack(alignment: .firstTextBaseline) {
                Image(systemName: c.status.accepted ? "doc.badge.plus" : "minus.circle")
                  .foregroundStyle(c.status.accepted ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                  Text(c.name).lineLimit(1).truncationMode(.middle)
                  if let reason = c.status.reason { Text("빼요: \(reason)").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(c.bytes), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
              }
            }
            if planning { ProgressView().controlSize(.small) }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 80, maxHeight: 200)
        HStack {
          Button("파일 더하기…") { choose() }
          Button("모두 비우기") {
            files = []
            plan = []
          }
        }
        .controlSize(.small)
      }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10).fill(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)))
    .dropDestination(for: URL.self) { urls, _ in
      add(urls)
      return true
    } isTargeted: { targeted = $0 }
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = ["pdf", "ppt", "pptx", "key", "doc", "docx", "pages", "jpg", "jpeg", "png", "heic", "heif"].compactMap {
      UTType(filenameExtension: $0)
    }
    panel.prompt = "고르기"
    if panel.runModal() == .OK { add(panel.urls) }
  }

  private func add(_ urls: [URL]) {
    for url in urls where url.isFileURL && !files.contains(url) && !FileOps.isDirectory(url) { files.append(url) }
    replan()
  }

  // 파일마다 해시를 낸다. 큰 파일이 있을 수 있어 메인 스레드 밖에서 한다.
  private func replan() {
    let files = files
    let library = model.library
    planning = true
    Task {
      let result = await Task.detached { SourceIntake.plan(files, library: library) }.value
      if files == self.files {
        plan = result
        planning = false
      }
    }
  }

  private func submit() {
    submitting = true
    let request = IntakeRequest(
      files: plan.filter { $0.status.accepted }.map(\.url), labels: labels.labels, memo: memo, syllabusBasis: syllabusBasis)
    Task {
      do {
        try await model.submitIntake(request)
        dismiss()
      } catch {
        self.error = error.localizedDescription
        submitting = false
      }
    }
  }
}

// 화면에서 고치는 꼬리표 세 칸
struct LabelDraft: Equatable {
  var grade = ""
  var subject = ""
  var level = ""

  init() {}

  init(_ labels: SourceLabels) {
    grade = labels.grade ?? ""
    subject = labels.subject ?? ""
    level = labels.level ?? ""
  }

  var labels: SourceLabels { SourceLabels(grade: grade, subject: subject, level: level) }
}

// 꼬리표 칸: 직접 적거나, 오른쪽 메뉴에서 이전에 쓴 값과 미리 준비한 값을 고른다
struct LabelFields: View {
  @Binding var draft: LabelDraft
  let library: SourceLibrary

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
      row(SourceLabels.grade, $draft.grade, prompt: "예: DP1, MYP 5")
      row(SourceLabels.subject, $draft.subject, prompt: "예: Physics, Extended Math")
      row(SourceLabels.level, $draft.level, prompt: "예: HL, SL, Extended (없으면 비워 둡니다)")
    }
  }

  private func row(_ name: String, _ text: Binding<String>, prompt: String) -> some View {
    let used = library.usedValues(name)
    let suggestions = LabelSuggestions.merged(used: used, name: name)
    return GridRow {
      Text(SourceLabels.displayName(name)).gridColumnAlignment(.trailing)
      HStack(spacing: 4) {
        TextField("", text: text, prompt: Text(prompt))
        Menu {
          if !used.isEmpty {
            Section("이전에 쓴 값") { ForEach(used, id: \.self) { v in Button(v) { text.wrappedValue = v } } }
          }
          Section("제안") {
            ForEach(suggestions.filter { s in !used.contains(s) }, id: \.self) { v in Button(v) { text.wrappedValue = v } }
          }
        } label: {
          Image(systemName: "chevron.down")
        }
        .menuIndicator(.hidden)
        .fixedSize()
      }
    }
  }
}

// 자료 하나의 꼬리표, 메모, 목차의 근거 표시를 고친다
struct LabelEditSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let source: SourceSummary
  @State private var draft = LabelDraft()
  @State private var memo = ""
  @State private var syllabusBasis = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("꼬리표 고치기").font(.title2.weight(.semibold))
      Text(source.meta.original.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      LabelFields(draft: $draft, library: model.library)
      TextField("메모", text: $memo)
      Toggle("목차의 근거 (과목 가이드, 과정·단원 안내)", isOn: $syllabusBasis)
      if let error { Text(error).font(.callout).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("저장") {
          do {
            try model.updateLabels(source, labels: draft.labels, memo: memo, syllabusBasis: syllabusBasis)
            dismiss()
          } catch {
            self.error = error.localizedDescription
          }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 560)
    .onAppear {
      draft = LabelDraft(source.labels.labels)
      memo = source.labels.memo ?? ""
      syllabusBasis = source.labels.syllabusBasis
    }
  }
}
