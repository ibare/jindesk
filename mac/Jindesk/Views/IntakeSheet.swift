import JindeskKit
import PDFKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// 자료 넣기 (PAGES.md 의 시트, DECISIONS.md 35): 그날 받은 파일을 같은 내용끼리 묶음으로 넣는다.
// 꼬리표(학년, 과목, 수준)는 위에 한 번 붙이고, 메모는 묶음마다 붙인다. 묶음의 이름은 받지 않는다(묶음 읽기가 짓는다).
// 한 번에 놓은 파일은 한 묶음이 되고, 파일 줄을 끌어 다른 묶음이나 새 묶음 자리로 옮긴다. 파일 이름은 믿지 않으므로 첫 쪽 미리보기를 둔다.
struct IntakeSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var groups: [DraftGroup] = []
  // 목차의 근거로 넣을 파일 (파일마다 묶음 하나)
  @State private var basis: [URL] = []
  @State private var plan: [URL: IntakeCandidate] = [:]
  @State private var pages: [URL: Int] = [:]
  @State private var planning = false
  @State private var labels = LabelDraft()
  @State private var error: String?
  @State private var submitting = false
  @State private var targeted = false

  struct DraftGroup: Identifiable, Equatable {
    let id = UUID()
    var files: [URL] = []
    var memo = ""
    // 더할 묶음 id. nil 이면 새 묶음
    var bundle: String?
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("자료 넣기").font(.title2.weight(.semibold))
        Text("같은 내용을 다루는 파일을 한 묶음으로 넣습니다. 묶음마다 함께 읽고 함께 정리합니다.").foregroundStyle(.secondary)
      }
      LabelFields(draft: $labels, library: model.library, inline: true)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(Array(groups.enumerated()), id: \.element.id) { i, group in
            groupCard(group, number: groups[..<i].filter { $0.bundle == nil }.count + 1)
          }
          newBundleZone
          if !skipped.isEmpty { skippedList }
          extras
        }
        .padding(2)
      }
      .frame(minHeight: 380, maxHeight: 600)
      if let error { Text(error).font(.callout).foregroundStyle(.red) }
      HStack {
        Text(summary).foregroundStyle(.secondary).monospacedDigit()
        if planning { ProgressView().controlSize(.small) }
        Spacer()
        if labels.subject.trimmingCharacters(in: .whitespaces).isEmpty, !allFiles.isEmpty {
          Text("과목을 적어 주세요").font(.callout).foregroundStyle(.secondary)
        }
        Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("넣기") { submit() }
          .keyboardShortcut(.defaultAction)
          .disabled(acceptedCount == 0 || planning || submitting || labels.subject.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 720)
    .onAppear {
      labels = LabelDraft(model.library.lastLabels)
      if let id = model.intakeBundle {
        groups = [DraftGroup(bundle: id)]
        model.intakeBundle = nil
      }
      #if DEBUG
        let preset = SnapshotDriver.intakePreset
        if !preset.isEmpty {
          // 있는 묶음 카드가 있으면 첫 묶음의 마지막 파일을 거기에 둔다
          if !groups.isEmpty, let last = preset.last?.last { groups[0].files = [last] }
          groups += preset.enumerated().map { i, files in
            DraftGroup(files: i == preset.count - 1 && !groups.isEmpty ? Array(files.dropLast()) : files, memo: i == 1 ? "워크시트 끝은 지난 단원 복습" : "")
          }.filter { !$0.files.isEmpty }
          replan()
        }
      #endif
    }
  }

  // MARK: - 묶음 카드

  func groupCard(_ group: DraftGroup, number: Int) -> some View {
    let rows = group.files.filter { plan[$0]?.status.accepted != false }
    let existing = group.bundle.flatMap { model.bundle($0) }
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        if let existing {
          Chip(text: "있는 묶음에 더하기", tint: .green)
          VStack(alignment: .leading, spacing: 1) {
            Text(model.bundleTitle(existing)).font(.system(size: 14, design: .serif)).lineLimit(1)
            Text("\(SourceRow.date(existing.created))에 넣은 묶음 · 자료 \(existing.sources.count)").font(.system(size: 11.5)).foregroundStyle(.secondary)
          }
        } else {
          Chip(text: "묶음 \(number)", tint: .accentColor)
          Text("이름은 읽으면서 내용으로 짓습니다").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Text(pageText(rows)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        Button("묶음 지우기", systemImage: "xmark") { remove(group) }.labelStyle(.iconOnly).buttonStyle(.borderless)
      }
      if rows.isEmpty {
        Text(group.bundle == nil ? "파일을 여기에 놓으세요" : "이 묶음에 더할 파일을 여기에 놓으세요").font(.system(size: 12)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      ForEach(rows, id: \.self) { url in
        IntakeFileRow(url: url, pages: pages[url], bytes: plan[url]?.bytes)
          .draggable(url)
          .contextMenu {
            Button("새 묶음으로 빼기") { place([url], into: nil) }
            Button("목차의 근거로 넣기") { toBasis(url) }
            Divider()
            Button("빼기") { drop(url) }
          }
      }
      if existing == nil {
        TextField("메모 (적지 않아도 됩니다)", text: binding(group).memo).textFieldStyle(.roundedBorder)
      } else {
        Text("더한 파일만 읽고, 묶음에 이미 있는 엔트리와 함께 묶음을 다시 정리합니다.").font(.system(size: 11.5)).foregroundStyle(.secondary)
      }
      HStack {
        Button("파일 더하기…") { choose { place($0, into: group.id) } }.controlSize(.small)
      }
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
    .dropDestination(for: URL.self) { urls, _ in
      place(urls, into: group.id)
      return true
    }
  }

  // 새 묶음 자리: 다른 내용의 파일을 놓는다. 처음에는 크게 둔다.
  var newBundleZone: some View {
    VStack(spacing: 8) {
      Image(systemName: groups.isEmpty ? "tray.and.arrow.down" : "plus.rectangle.on.rectangle").font(.system(size: groups.isEmpty ? 28 : 18)).foregroundStyle(.secondary)
      Text(groups.isEmpty ? "여기에 파일을 끌어다 놓으세요" : "새 묶음").font(.system(size: 13, weight: .semibold))
      Text(groups.isEmpty ? "한 번에 놓은 파일은 한 묶음이 됩니다. 내용이 다른 파일은 따로 놓으세요." : "다른 내용의 파일을 여기에 놓으세요. 파일 줄을 끌어와도 됩니다.")
        .font(.system(size: 12)).foregroundStyle(.secondary)
      Button("파일 고르기…") { choose { place($0, into: nil) } }.controlSize(.small)
      Text("PDF, PPT·PPTX·KEY, DOC·DOCX·PAGES, JPEG·PNG·HEIC").font(.caption).foregroundStyle(.tertiary)
    }
    // 내용이 점선에 닿지 않게 안쪽 여백을 둔다
    .padding(.horizontal, 16)
    .padding(.vertical, 18)
    .frame(maxWidth: .infinity, minHeight: groups.isEmpty ? 220 : 110)
    .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.12) : Color.clear))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(Color.primary.opacity(0.25)))
    .dropDestination(for: URL.self) { urls, _ in
      place(urls, into: nil)
      return true
    } isTargeted: { targeted = $0 }
  }

  // 넣지 않는 파일과 까닭
  var skippedList: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("넣지 않는 파일").font(.system(size: 11.5, weight: .bold)).foregroundStyle(.secondary)
      ForEach(skipped, id: \.url) { c in
        HStack(spacing: 8) {
          Image(systemName: "minus.circle").foregroundStyle(.secondary)
          Text(c.name).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 8)
          Text(c.status.reason ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
          Button("빼기", systemImage: "xmark") { drop(c.url) }.labelStyle(.iconOnly).buttonStyle(.borderless)
        }
      }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
  }

  // 있는 묶음에 더하기와 목차의 근거
  var extras: some View {
    let recent = model.bundles.filter { b in !groups.contains { $0.bundle == b.id } }.prefix(30)
    return VStack(alignment: .leading, spacing: 10) {
      Menu {
        ForEach(Array(recent)) { b in
          Button("\(model.bundleTitle(b)) · \(SourceRow.date(model.lastReceived(b)))") { groups.append(DraftGroup(bundle: b.id)) }
        }
      } label: {
        Label("이미 있는 묶음에 더하기…", systemImage: "plus")
      }
      .disabled(recent.isEmpty)
      .fixedSize()
      .help("한 주 뒤에 받은 워크시트처럼, 넣어 둔 묶음과 같은 내용일 때")
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("목차의 근거").font(.system(size: 13, weight: .semibold))
          Text("과목 가이드, 과정·단원 안내. 파일마다 묶음 하나로 넣고 목차를 만드는 데도 씁니다").font(.system(size: 11.5)).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button("고르기…") { choose { urls in urls.forEach(toBasis) } }.controlSize(.small)
        }
        ForEach(basis.filter { plan[$0]?.status.accepted != false }, id: \.self) { url in
          IntakeFileRow(url: url, pages: pages[url], bytes: plan[url]?.bytes)
            .draggable(url)
            .contextMenu { Button("빼기") { drop(url) } }
        }
      }
      .padding(12)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
      .dropDestination(for: URL.self) { urls, _ in
        urls.forEach(toBasis)
        return true
      }
    }
  }

  // MARK: - 상태

  var allFiles: [URL] { groups.flatMap(\.files) + basis }
  var skipped: [IntakeCandidate] { allFiles.compactMap { plan[$0] }.filter { !$0.status.accepted } }
  var acceptedCount: Int { allFiles.filter { plan[$0]?.status.accepted == true }.count }

  // "새 묶음 2개 · 있는 묶음에 1개 · 파일 5개 · 113쪽"
  var summary: String {
    let accepted = { (u: URL) in plan[u]?.status.accepted == true }
    let live = groups.filter { $0.files.contains(where: accepted) }
    let fresh = live.filter { $0.bundle == nil }.count + basis.filter(accepted).count
    let adding = live.filter { $0.bundle != nil }.count
    let files = allFiles.filter(accepted)
    let total = files.compactMap { pages[$0] }.reduce(0, +)
    var parts = ["새 묶음 \(fresh)개"]
    if adding > 0 { parts.append("있는 묶음에 \(adding)개") }
    parts.append("파일 \(files.count)개")
    if total > 0 { parts.append("\(total)쪽") }
    return parts.joined(separator: " · ")
  }

  func pageText(_ urls: [URL]) -> String {
    let total = urls.compactMap { pages[$0] }.reduce(0, +)
    return total > 0 ? "\(total)쪽" : ""
  }

  func binding(_ group: DraftGroup) -> Binding<DraftGroup> {
    Binding(
      get: { groups.first { $0.id == group.id } ?? group },
      set: { new in if let i = groups.firstIndex(where: { $0.id == group.id }) { groups[i] = new } })
  }

  // 파일을 묶음에 놓는다. 시트 안의 줄을 끌어왔으면 옮기고, 새 파일이면 더한다. 묶음 id 가 nil 이면 새 묶음.
  func place(_ urls: [URL], into id: UUID?) {
    let files = urls.filter { $0.isFileURL && !FileOps.isDirectory($0) }
    guard !files.isEmpty else { return }
    for u in files {
      for i in groups.indices { groups[i].files.removeAll { $0 == u } }
      basis.removeAll { $0 == u }
    }
    if let id, let i = groups.firstIndex(where: { $0.id == id }) {
      groups[i].files += files
    } else {
      groups.append(DraftGroup(files: files))
    }
    groups.removeAll { $0.files.isEmpty && $0.bundle == nil && $0.id != id }
    replan()
  }

  func toBasis(_ url: URL) {
    guard url.isFileURL, !FileOps.isDirectory(url) else { return }
    for i in groups.indices { groups[i].files.removeAll { $0 == url } }
    groups.removeAll { $0.files.isEmpty && $0.bundle == nil }
    if !basis.contains(url) { basis.append(url) }
    replan()
  }

  func drop(_ url: URL) {
    for i in groups.indices { groups[i].files.removeAll { $0 == url } }
    basis.removeAll { $0 == url }
    groups.removeAll { $0.files.isEmpty && $0.bundle == nil }
    replan()
  }

  func remove(_ group: DraftGroup) {
    groups.removeAll { $0.id == group.id }
    replan()
  }

  private func choose(_ then: ([URL]) -> Void) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = ["pdf", "ppt", "pptx", "key", "doc", "docx", "pages", "jpg", "jpeg", "png", "heic", "heif"].compactMap {
      UTType(filenameExtension: $0)
    }
    panel.prompt = "고르기"
    if panel.runModal() == .OK { then(panel.urls) }
  }

  // 파일마다 해시와 쪽 수를 낸다. 큰 파일이 있을 수 있어 메인 스레드 밖에서 한다.
  private func replan() {
    let files = allFiles
    let library = model.library
    planning = true
    Task {
      let result = await Task.detached { () -> ([IntakeCandidate], [URL: Int]) in
        let candidates = SourceIntake.plan(files, library: library)
        var pages: [URL: Int] = [:]
        for u in files where u.pathExtension.lowercased() == "pdf" { if let n = PDFDocument(url: u)?.pageCount { pages[u] = n } }
        return (candidates, pages)
      }.value
      if files == allFiles {
        plan = Dictionary(result.0.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        pages = result.1
        planning = false
      }
    }
  }

  private func submit() {
    submitting = true
    let accepted = { (u: URL) in plan[u]?.status.accepted == true }
    var request = groups.compactMap { g -> IntakeGroup? in
      let files = g.files.filter(accepted)
      return files.isEmpty ? nil : IntakeGroup(files: files, memo: g.memo.nilIfBlank, bundle: g.bundle)
    }
    request += basis.filter(accepted).map { IntakeGroup(files: [$0], syllabusBasis: true) }
    let intake = IntakeRequest(labels: labels.labels, groups: request)
    Task {
      do {
        try await model.submitIntake(intake)
        dismiss()
      } catch {
        self.error = error.localizedDescription
        submitting = false
      }
    }
  }
}

// 묶음 카드의 머리 칩
struct Chip: View {
  let text: String
  let tint: Color

  var body: some View {
    Text(text).font(.system(size: 11.5, weight: .bold)).foregroundStyle(tint)
      .padding(.horizontal, 8).padding(.vertical, 2)
      .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.12)))
  }
}

// 넣을 파일 한 줄: 첫 쪽 미리보기, 파일 이름, 형식 · 쪽 수 · 크기
struct IntakeFileRow: View {
  let url: URL
  let pages: Int?
  let bytes: Int?
  @State private var thumb: NSImage?

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.tertiary)
      Group {
        if let thumb {
          Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
        } else {
          SourceThumb()
        }
      }
      .frame(width: 48, height: 40)
      .clipShape(RoundedRectangle(cornerRadius: 3))
      VStack(alignment: .leading, spacing: 2) {
        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
        Text(meta).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
    .task(id: url) {
      let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 80), scale: 2, representationTypes: .thumbnail)
      thumb = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
  }

  var meta: String {
    var parts = [url.pathExtension.uppercased()]
    if let pages { parts.append("\(pages)쪽") }
    if let bytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
    return parts.joined(separator: " · ")
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
  // 세 칸을 한 줄에 둔다 (자료 넣기)
  var inline = false

  var body: some View {
    if inline {
      HStack(alignment: .top, spacing: 10) {
        column(SourceLabels.grade, $draft.grade, prompt: "예: DP1, MYP 5")
        column(SourceLabels.subject, $draft.subject, prompt: "예: Physics")
        column(SourceLabels.level, $draft.level, prompt: "예: HL (없으면 비움)")
      }
    } else {
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        row(SourceLabels.grade, $draft.grade, prompt: "예: DP1, MYP 5")
        row(SourceLabels.subject, $draft.subject, prompt: "예: Physics, Extended Math")
        row(SourceLabels.level, $draft.level, prompt: "예: HL, SL, Extended (없으면 비워 둡니다)")
      }
    }
  }

  private func column(_ name: String, _ text: Binding<String>, prompt: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(SourceLabels.displayName(name)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
      field(name, text, prompt: prompt)
    }
    .frame(maxWidth: .infinity)
  }

  private func field(_ name: String, _ text: Binding<String>, prompt: String) -> some View {
    let used = library.usedValues(name)
    let suggestions = LabelSuggestions.merged(used: used, name: name)
    return HStack(spacing: 4) {
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

  private func row(_ name: String, _ text: Binding<String>, prompt: String) -> some View {
    GridRow {
      Text(SourceLabels.displayName(name)).gridColumnAlignment(.trailing)
      field(name, text, prompt: prompt)
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
