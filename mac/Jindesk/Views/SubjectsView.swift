import JindeskKit
import SwiftUI

// 과목 화면: 자료의 꼬리표에서 모은 과목마다 정리된 개념과 자료. 개념을 고르면 학습 페이지, 자료를 고르면 쪽이 보인다.
struct SubjectsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    let library = model.library
    if library.sources.isEmpty {
      ContentUnavailableView {
        Label("아직 자료가 없어요", systemImage: "books.vertical")
      } description: {
        Text("학교에서 받은 자료를 넣으면 과목마다 모여 보입니다. 과목은 자료를 넣을 때 붙이는 꼬리표에서 생깁니다.")
      } actions: {
        Button("자료 넣기…") { model.showIntake = true }
      }
    } else {
      HSplitView {
        VStack(spacing: 0) {
          if !model.waitingWork.isEmpty { PendingBanner() }
          List(selection: $model.selection) {
            ForEach(library.subjects) { subject in
              Section {
                ConceptRows(subject: subject.id)
                DisclosureGroup("자료 \(subject.sources.count)개") {
                  ForEach(subject.sources) { SourceRow(source: $0).tag(SubjectSelection.source($0.id)) }
                }
              } header: {
                SubjectHeader(subject: subject)
              }
            }
            if !library.unlabeled.isEmpty {
              Section("과목 꼬리표가 없는 자료") {
                ForEach(library.unlabeled) { SourceRow(source: $0).tag(SubjectSelection.source($0.id)) }
              }
            }
          }
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
        Group {
          switch model.selection {
          case .concept(let id)?:
            if let concept = model.concept(id) {
              ConceptPageView(concept: concept)
            } else {
              ContentUnavailableView("개념을 찾지 못했어요", systemImage: "questionmark.folder")
            }
          case .source(let id)?:
            if let source = library.source(id) {
              SourceViewer(source: source).id(source.id)
            } else {
              ContentUnavailableView("자료를 찾지 못했어요", systemImage: "questionmark.folder")
            }
          case nil:
            ContentUnavailableView("개념이나 자료를 고르세요", systemImage: "doc.text.magnifyingglass")
          }
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
      }
      .sheet(item: $model.peek) { SourcePeekSheet(peek: $0) }
    }
  }
}

// 과목의 개념: 목차 항목(없으면 단원 제안)으로 묶는다
struct ConceptRows: View {
  @Environment(AppModel.self) private var model
  let subject: String

  var body: some View {
    let concepts = model.concepts[subject] ?? []
    if concepts.isEmpty {
      Text(model.library.subjects.first { $0.id == subject }.map { s in s.sources.contains { model.readSources[$0.id] != nil } } == true ? "개념을 정리하는 중이에요" : "자료를 읽으면 개념이 생겨요")
        .font(.caption).foregroundStyle(.secondary)
    }
    ForEach(Self.groups(concepts), id: \.name) { group in
      Text(group.name).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 4)
      ForEach(group.concepts) { c in ConceptRow(concept: c).tag(SubjectSelection.concept(c.id)) }
    }
  }

  static func groups(_ concepts: [Concept]) -> [(name: String, concepts: [Concept])] {
    var order: [String] = []
    var byName: [String: [Concept]] = [:]
    for c in concepts {
      let name = c.item ?? c.itemProposed ?? "목차 밖"
      if byName[name] == nil { order.append(name) }
      byName[name, default: []].append(c)
    }
    return order.sorted().map { ($0, byName[$0]!) }
  }
}

struct ConceptRow: View {
  @Environment(AppModel.self) private var model
  let concept: Concept

  var body: some View {
    let state = model.pageState(concept)
    VStack(alignment: .leading, spacing: 1) {
      Text(concept.title).lineLimit(2)
      HStack(spacing: 6) {
        if let ko = state.titleKo { Text(ko) }
        if let note = state.note { Text(note).foregroundStyle(.orange) }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 1)
  }
}

// 흐름이 끊겨 남은 일: 토큰 없이 넣은 자료, 앱이 꺼져 멈춘 정리 등
struct PendingBanner: View {
  @Environment(AppModel.self) private var model
  @State private var error: String?
  @State private var busy = false

  var body: some View {
    let work = model.waitingWork
    VStack(alignment: .leading, spacing: 6) {
      Text(Self.summary(work)).font(.callout)
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      Button(busy ? "넣는 중…" : "이어서 하기") {
        busy = true
        Task {
          do {
            try await model.continuePending()
            error = nil
          } catch {
            self.error = error.localizedDescription
          }
          busy = false
        }
      }
      .disabled(busy)
      .controlSize(.small)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.accentColor.opacity(0.08))
  }

  static func summary(_ work: [PendingWork]) -> String {
    var counts: [(JobKind, Int)] = []
    for w in work {
      if let i = counts.firstIndex(where: { $0.0 == w.kind }) { counts[i].1 += 1 } else { counts.append((w.kind, 1)) }
    }
    return "남은 일: " + counts.map { "\($0.0.label) \($0.1)" }.joined(separator: " · ")
  }
}

struct SubjectHeader: View {
  let subject: SubjectSummary

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(subject.name).font(.headline)
      Text((subject.grades + subject.levels).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
      Spacer()
      Text("\(subject.sources.count)").font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct ReadingBadge: View {
  @Environment(AppModel.self) private var model
  let source: SourceSummary

  var body: some View {
    switch model.readingState(source.id) {
    case .unread: Text("읽기 전")
    case .queued: Text("읽기 대기")
    case .reading(let phase): Text("읽는 중 · \(phase)").foregroundStyle(Color.accentColor)
    case .read: Text("읽음")
    case .failed: Text("읽지 못함").foregroundStyle(.red)
    }
  }
}

struct SourceRow: View {
  let source: SourceSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(Self.title(source)).lineLimit(2)
      HStack(spacing: 6) {
        Text(Self.date(source.meta.received))
        Text("\(source.meta.pages)쪽")
        ReadingBadge(source: source)
        if let memo = source.labels.memo { Text(memo).lineLimit(1) }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }

  // 파일 이름에서 확장자를 떼고 _ 를 띄어 쓴다
  static func title(_ source: SourceSummary) -> String {
    let name = (source.meta.original.name as NSString).deletingPathExtension
    return name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "  ", with: " ")
  }

  static func date(_ iso: String) -> String {
    guard let d = Clock.parse(iso) else { return "" }
    return d.formatted(.dateTime.month().day().weekday(.abbreviated))
  }
}

// 자료 하나: 꼬리표와 메모, 쪽 이미지. 쪽 아래에 글자층을 펼쳐 볼 수 있다.
struct SourceViewer: View {
  @Environment(AppModel.self) private var model
  let source: SourceSummary
  @State private var editing = false
  @State private var showText = false

  var body: some View {
    let runs = Dictionary(source.meta.buildUps.flatMap { run in run.map { ($0, run) } }, uniquingKeysWith: { a, _ in a })
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        header
        ForEach(1...max(source.meta.pages, 1), id: \.self) { n in
          PageView(source: source, page: n, run: runs[n], showText: showText)
        }
      }
      .padding(20)
    }
    .sheet(isPresented: $editing) { LabelEditSheet(source: source) }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(SourceRow.title(source)).font(.title2.weight(.semibold)).textSelection(.enabled)
      HStack(spacing: 6) {
        ForEach(source.labels.labels.entries, id: \.name) { label in
          Text(label.value)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .help(SourceLabels.displayName(label.name))
        }
        if source.labels.syllabusBasis {
          Text("목차의 근거").font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.orange.opacity(0.18)))
        }
      }
      Text("\(SourceRow.date(source.meta.received)) 받음 · \(source.meta.pages)쪽 · \(source.meta.original.name)")
        .font(.callout).foregroundStyle(.secondary)
      if let memo = source.labels.memo { Text(memo).font(.callout) }
      HStack {
        Button("꼬리표 고치기…") { editing = true }
        Button("원본 열기") { if let url = source.folder.original { NSWorkspace.shared.open(url) } }
        ReadButton(source: source)
        Toggle("글자층 보기", isOn: $showText).toggleStyle(.switch).controlSize(.small)
      }
      .controlSize(.small)
    }
  }
}

// 자료를 (다시) 읽게 한다. 읽는 중이거나 기다리는 중이면 쓸 수 없다.
struct ReadButton: View {
  @Environment(AppModel.self) private var model
  let source: SourceSummary
  @State private var error: String?

  var body: some View {
    let state = model.readingState(source.id)
    let busy = state == .queued || { if case .reading = state { true } else { false } }()
    Button(state == .read ? "다시 읽기" : "읽기") {
      Task {
        do {
          try await model.read(source)
          error = nil
        } catch {
          self.error = error.localizedDescription
        }
      }
    }
    .disabled(busy || source.labels.labels.subjectID == nil)
    .help(error ?? (source.labels.labels.subjectID == nil ? "과목 꼬리표를 붙이면 읽을 수 있어요" : "에이전트가 이 자료를 읽고 개념 엔트리를 씁니다"))
    if case .failed(let message) = state { Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).help(message) }
    if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
  }
}

struct PageView: View {
  @Environment(AppModel.self) private var model
  let source: SourceSummary
  let page: Int
  let run: [Int]?
  let showText: Bool
  @State private var image: NSImage?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text("\(page)쪽").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        if let run, let last = run.last {
          Text(page == last ? "이어 채운 쪽의 마지막 모습" : "\(last)쪽으로 이어 채워짐").font(.caption).foregroundStyle(.tertiary)
        }
      }
      Group {
        if let image {
          Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
          Rectangle().fill(Color.secondary.opacity(0.08)).aspectRatio(16 / 9, contentMode: .fit).overlay(ProgressView().controlSize(.small))
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
      .opacity(run != nil && page != run?.last ? 0.55 : 1)
      if showText {
        let text = SourcePages.text(source.folder, page: page)
        Text(text.isEmpty ? "(글자층 없음)" : text)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .task(id: page) {
      guard image == nil, let url = await model.pageImage(source, page: page) else { return }
      image = NSImage(contentsOf: url)
    }
  }
}
