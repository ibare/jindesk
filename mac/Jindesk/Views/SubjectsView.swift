import JindeskKit
import SwiftUI

// 과목 화면 (DECISIONS.md 39): 사이드바에서 고른 과목을 목록 칸의 스택으로 연다.
// 과목 단계(과목 머리, 개념 지도, 단원)에서 단원을 누르면 단원 단계(단원 머리, 개념)로 들어간다.
// 단원 머리를 고르면 단원 개요, 개념을 고르면 학습 페이지가 내용 칸에 열린다.
// ⌘ 로 개념 여러 줄을 고를 수 있다. 하나만 고르면 내용 칸이 그것을 열고, 여럿을 고르면 줄 메뉴가 고른 것 모두에 한다.
struct SubjectsView: View {
  @Environment(AppModel.self) private var model
  // 목록 칸에서 고른 줄
  @State private var picked: Set<SubjectSelection> = []
  // 확인을 기다리는 페이지 다시 만들기
  @State private var rebuild: PageRebuildAsk?
  // 확인 시트를 띄운 개념 다시 정리 (고른 개념 id)
  @State private var recurating: RecurateAsk?
  @State private var error: String?

  var body: some View {
    if let id = model.currentSubject, let subject = model.library.subjects.first(where: { $0.id == id }) {
      // 목록 칸. 고른 것은 내용 칸(SelectionDetail)에 보인다.
      VStack(spacing: 0) {
        if !model.waitingWork.isEmpty { PendingBanner().card().padding(.horizontal, 10).padding(.top, 8) }
        ForEach(model.proposals.filter { $0.subject == subject.id }) { p in ProposalRow(proposal: p).card().padding(.horizontal, 10).padding(.top, 8) }
        ScrollViewReader { proxy in
          List(selection: $picked) {
            // 줄 사이에 구분선을 긋지 않는다 (DECISIONS.md 32)
            Group {
              if let key = model.openUnit {
                UnitLevel(subject: subject, key: key)
              } else {
                SubjectLevel(subject: subject)
              }
            }
            .listRowSeparator(.hidden)
          }
          .contextMenu(forSelectionType: SubjectSelection.self) { items in rowMenu(items) }
          // 학습 페이지의 앞뒤 개념이나 개념 지도에서 옮겨 가면 그 개념의 줄이 보이게 내린다
          .onChange(of: model.revealInList) { reveal(proxy) }
          .onAppear { reveal(proxy) }
        }
      }
      // 다른 곳에서 연 개념이나 단원을 따라 과목과 단원을 옮긴다
      .onAppear {
        model.follow(model.selection)
        picked = Set([model.selection].compactMap { $0 })
      }
      .onChange(of: model.selection) {
        model.follow(model.selection)
        // 다른 곳에서 고른 것으로 바뀌면 목록의 고른 줄도 그것 하나로 맞춘다 (여럿을 고른 가운데 하나면 그대로 둔다)
        guard let s = model.selection else { return picked = [] }
        if !picked.contains(s) { picked = [s] }
      }
      .onChange(of: picked) {
        if picked.count == 1, let one = picked.first, model.selection != one { model.selection = one }
      }
      .confirmationDialog(rebuild?.title ?? "", isPresented: Binding(get: { rebuild != nil }, set: { if !$0 { rebuild = nil } }), presenting: rebuild) { ask in
        Button("다시 만들기") {
          Task {
            do { try await model.rebuildPages(ask.ids) } catch { self.error = error.localizedDescription }
          }
        }
        Button("취소", role: .cancel) {}
      } message: { ask in
        Text("개념 \(ask.ids.count)개의 학습 페이지를 지금 지침으로 처음부터 다시 짭니다. 문단 글은 개념 원문 그대로이고, 확인 문제, 강조 상자, 그림이 새로 나옵니다. 이전 판은 기록에 남습니다.")
      }
      .sheet(item: $recurating) { ask in RecurateSheet(ask: ask) }
      .alert("작업을 넣지 못했습니다", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        Button("확인", role: .cancel) {}
      } message: {
        Text(error ?? "")
      }
    } else {
      ContentUnavailableView {
        Label("아직 과목이 없어요", systemImage: "books.vertical")
      } description: {
        Text("학교에서 받은 자료를 넣으면 과목마다 모여 보입니다. 과목은 자료를 넣을 때 붙이는 꼬리표에서 생깁니다.")
      } actions: {
        Button("자료 넣기…") { model.showIntake = true }
      }
    }
  }

  // 줄 메뉴: 개념 줄이면 고른 개념 모두, 단원 머리면 그 단원의 개념 모두
  @ViewBuilder private func rowMenu(_ items: Set<SubjectSelection>) -> some View {
    let ids = items.compactMap { if case .concept(let id) = $0 { id } else { nil } }.sorted()
    if !ids.isEmpty {
      Button(ids.count == 1 ? "페이지 다시 만들기" : "페이지 다시 만들기 (\(ids.count)개)") {
        rebuild = PageRebuildAsk(title: ids.count == 1 ? "이 개념의 페이지를 다시 만들까요?" : "개념 \(ids.count)개의 페이지를 다시 만들까요?", ids: ids)
      }
      Button(ids.count == 1 ? "개념 다시 정리…" : "개념 다시 정리… (\(ids.count)개)") { recurating = RecurateAsk(ids: ids) }
    }
    ForEach(items.compactMap { if case .unit(let s, let k) = $0 { [s, k] } else { nil } }, id: \.self) { pair in
      let unit = model.unit(pair[0], pair[1])
      Button("이 단원 페이지 다시 만들기") {
        rebuild = PageRebuildAsk(title: "\(unit.title)의 페이지 \(unit.concepts.count)개를 다시 만들까요?", ids: unit.concepts.map(\.id))
      }
      .disabled(unit.concepts.isEmpty)
    }
  }

  private func reveal(_ proxy: ScrollViewProxy) {
    guard let id = model.revealInList else { return }
    model.revealInList = nil
    // 단원 단계로 바뀐 목록이 그려진 뒤에 내린다
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(60))
      withAnimation { proxy.scrollTo(id, anchor: .center) }
    }
  }
}

// 확인 시트를 띄운 개념 다시 정리 (DECISIONS.md 47)
struct RecurateAsk: Identifiable {
  let ids: [String]
  var id: String { ids.joined(separator: ",") }
}

// 개념 다시 정리 확인 시트: 무엇을 하는지 보이고 작업을 넣는다. 결과는 후보로 남고 대응표를 보고 반영한다.
struct RecurateSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let ask: RecurateAsk
  @State private var error: String?
  @State private var busy = false

  var body: some View {
    let concepts = ask.ids.compactMap { model.concept($0) }
    let entries = Set(concepts.flatMap { $0.occurrences.map(\.entry) }).count
    let others = (model.concepts[concepts.first?.subject ?? ""]?.count ?? 0) - concepts.count
    VStack(alignment: .leading, spacing: 12) {
      Text("개념 \(concepts.count)개를 다시 정리합니다").font(.headline)
      Text("이 개념들이 쓴 엔트리 \(entries)개를 지금 지침으로 다시 정리합니다.").font(.callout)
      VStack(alignment: .leading, spacing: 4) {
        Label("개념이 줄거나 늘고, 나뉘거나 합쳐질 수 있습니다.", systemImage: "arrow.triangle.branch")
        Label("끝나면 대응표를 보여 드립니다. 보고 반영할지 고릅니다.", systemImage: "tablecells")
        Label("고르지 않은 개념 \(max(others, 0))개는 바꾸지 않고, 내용을 받을 때만 보강합니다.", systemImage: "lock")
      }
      .font(.callout).foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(concepts) { c in Text("· \(c.title)").font(.system(size: 12)).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 120)
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(busy ? "넣는 중…" : "다시 정리") {
          busy = true
          Task {
            do {
              try await model.recurate(ask.ids)
              dismiss()
            } catch {
              self.error = error.localizedDescription
            }
            busy = false
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(busy || concepts.isEmpty)
      }
    }
    .padding(18)
    .frame(width: 460)
  }
}

// 검토를 기다리는 개념 다시 정리 후보: 누르면 내용 칸에 대응표를 연다 (DECISIONS.md 47)
struct ProposalRow: View {
  @Environment(AppModel.self) private var model
  let proposal: Recuration.Proposal

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "arrow.triangle.merge").font(.system(size: 13)).foregroundStyle(Color.accentColor).frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text("검토할 다시 정리").font(.system(size: 13, weight: .semibold))
        Text("\(model.library.subjects.first { $0.id == proposal.subject }?.name ?? proposal.subject) · 개념 \(proposal.before)개 → \(proposal.after)개")
          .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      Button("대응표 보기") { model.selection = .proposal(proposal.job) }.controlSize(.small)
    }
    .padding(10)
  }
}

// 확인을 기다리는 페이지 다시 만들기 (DECISIONS.md 46)
struct PageRebuildAsk: Identifiable {
  let title: String
  let ids: [String]
  var id: String { ids.joined(separator: ",") }
}

// 과목 단계: 과목 머리, 목차 확인, 개념 지도 카드, 단원 (이름의 알파벳순)
struct SubjectLevel: View {
  @Environment(AppModel.self) private var model
  let subject: SubjectSummary

  var body: some View {
    let units = model.units(subject.id)
    let syllabus = model.syllabi[subject.id]
    SubjectHeader(subject: subject, unitCount: units.count)
    if let syllabus, syllabus.confirmed == nil { SyllabusConfirmRow(subject: subject.id, count: syllabus.items.count) }
    if units.isEmpty {
      Text(subject.sources.contains { model.readSources[$0.id] != nil } ? "개념을 정리하는 중이에요" : "자료를 읽으면 개념이 생겨요")
        .font(.caption).foregroundStyle(.secondary)
    } else {
      ConceptMapRow(subject: subject.id).tag(SubjectSelection.map(subject.id))
      ListLabel(text: "단원 \(units.count)", trailing: "A–Z").padding(.top, 12)
      ForEach(units) { unit in
        UnitRow(subject: subject.id, unit: unit, current: unit.key == currentKey).id(unit.key)
      }
    }
  }

  // 들어갔다 나온 단원: 고른 단원 개요나 개념의 단원
  var currentKey: String? {
    switch model.selection {
    case .unit(_, let key)?: key
    case .concept(let id)?: model.concept(id).map { SubjectUnits.key($0, syllabus: model.syllabi[$0.subject]) }
    default: nil
    }
  }
}

// 단원 줄: 이름, 하루 안에 정리된 개념이 있으면 점, 개념 수. 누르면 단원 단계로 들어간다.
struct UnitRow: View {
  @Environment(AppModel.self) private var model
  let subject: String
  let unit: SubjectUnit
  // 방금 있던 단원이면 옅게 칠한다
  let current: Bool

  var body: some View {
    Button {
      model.enterUnit(subject, unit.key)
    } label: {
      HStack(spacing: 8) {
        Text(unit.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
        Spacer(minLength: 6)
        if unit.hasNew { NewDot().help("하루 안에 정리된 개념이 있음") }
        Text("\(unit.concepts.count)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 6)
      .contentShape(Rectangle())
      .background(RoundedRectangle(cornerRadius: 7).fill(current ? Color.primary.opacity(0.07) : .clear))
    }
    .buttonStyle(.plain)
    .help(unit.name)
  }
}

// 단원 단계: 과목으로 돌아가기, 단원 머리(고르면 단원 개요), 단원의 개념 (배우는 순서)
struct UnitLevel: View {
  @Environment(AppModel.self) private var model
  let subject: SubjectSummary
  let key: String

  var body: some View {
    let unit = model.unit(subject.id, key)
    let comments = model.commentCounts()
    Button {
      model.openUnit = nil
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
        Text(subject.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
      }
      .foregroundStyle(Color.accentColor)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.vertical, 4)
    .help("\(subject.name)의 단원으로 돌아갑니다")
    UnitHeaderRow(title: unit.title, count: unit.concepts.count).tag(SubjectSelection.unit(subject.id, key))
    if unit.concepts.isEmpty {
      Text("이 단원에 개념이 없어요").font(.caption).foregroundStyle(.secondary)
    }
    ForEach(unit.concepts) { c in
      ConceptRow(concept: c, comments: comments[c.id] ?? 0).tag(SubjectSelection.concept(c.id)).id(c.id)
    }
  }
}

// 단원 머리: 세리프로 쓴 단원 이름, "단원 요약 · 개념 N"
struct UnitHeaderRow: View {
  let title: String
  let count: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 18, weight: .semibold, design: .serif)).lineLimit(2)
      Text("단원 요약 · 개념 \(count)").font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
    }
    .padding(.vertical, 6)
    .padding(.bottom, 4)
  }
}

// 처음 만든 목차는 화면에서 확인한다
struct SyllabusConfirmRow: View {
  @Environment(AppModel.self) private var model
  let subject: String
  let count: Int
  @State private var error: String?

  var body: some View {
    HStack {
      Label("목차 확인 전 · 항목 \(count)개", systemImage: "list.bullet.clipboard").font(.caption).foregroundStyle(.orange)
      Spacer()
      Button("확인") {
        do { try model.confirmSyllabus(subject) } catch { self.error = error.localizedDescription }
      }
      .controlSize(.small)
      .help(error ?? "목차가 근거 문서와 맞는지 보고 확인합니다")
    }
  }
}

// 과목 꼬리표의 이름을 바꾸거나 다른 과목에 합친다
struct SubjectRenameSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let subject: SubjectSummary
  @State private var name = ""
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("과목 이름 바꾸기·합치기").font(.headline)
      Text("이 과목(\(subject.name))의 자료 \(subject.sources.count)개에 붙은 과목 꼬리표를 바꿉니다. 다른 과목의 이름을 고르면 그 과목에 합칩니다. 엔트리, 개념, 목차도 함께 옮깁니다.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        TextField("새 과목 이름", text: $name).textFieldStyle(.roundedBorder)
        Menu("있는 과목") {
          ForEach(model.library.subjects.filter { $0.id != subject.id }) { s in Button(s.name) { name = s.name } }
        }
        .fixedSize()
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("바꾸기") {
          do {
            _ = try model.renameSubject(subject.id, to: name)
            dismiss()
          } catch {
            self.error = error.localizedDescription
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || LabelMatch.key(name) == LabelMatch.key(subject.name))
      }
    }
    .padding(18)
    .frame(width: 460)
    .onAppear { name = subject.name }
  }
}

// 과목의 개념 지도를 여는 카드 (PAGES.md 의 개념 지도). 고르면 카드 바탕을 거두고 목록의 강조를 쓴다.
struct ConceptMapRow: View {
  @Environment(AppModel.self) private var model
  let subject: String

  var body: some View {
    let map = model.conceptMap(subject)
    let selected = model.selection == .map(subject)
    HStack(spacing: 12) {
      MapGlyph()
        .frame(width: 40, height: 40)
        .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.accentColor))
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white.opacity(0.18) : Color.primary.opacity(0.06)))
      VStack(alignment: .leading, spacing: 2) {
        Text("개념 지도").font(.system(size: 13, weight: .semibold))
        Text("개념 \(map.conceptCount) · 선수 연결 \(map.linkCount)").font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 9)
    .background {
      if !selected {
        RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035))
          .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
      }
    }
    .padding(.vertical, 2)
  }
}

// 개념 줄: 영어 이름과 한국어 이름의 콜론 앞, 오른쪽에 상태. 고른 줄은 이름의 나머지를 펼친다 (DECISIONS.md 32, 39).
struct ConceptRow: View {
  @Environment(AppModel.self) private var model
  let concept: Concept
  var comments = 0

  var body: some View {
    let state = model.pageState(concept)
    let selected = model.selection == .concept(concept.id)
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        ConceptNames(title: concept.title, titleKo: state.titleKo)
        if selected, let tail = TitleParts(concept.title).tail {
          Text(tail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      RowBadges(note: state.note, comments: comments, isNew: state.isNew, selected: selected).frame(height: 17)
    }
    .padding(.vertical, 3)
    .help([concept.title, state.titleKo].compactMap { $0 }.joined(separator: "\n"))
  }
}

// 흐름이 끊겨 남은 일: 토큰 없이 넣은 자료, 앱이 꺼져 멈춘 정리 등
struct PendingBanner: View {
  @Environment(AppModel.self) private var model
  @State private var error: String?
  @State private var busy = false

  var body: some View {
    let work = model.waitingWork
    HStack(spacing: 10) {
      Image(systemName: "pause.circle").font(.system(size: 14)).foregroundStyle(Color.ribbon).frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text("멈춘 일 \(work.count)개").font(.system(size: 13, weight: .semibold))
        Text(Self.summary(work)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
      }
      Spacer(minLength: 0)
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
      .buttonStyle(.borderedProminent)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // "자료 읽기 1 · 개념 정리 1"
  static func summary(_ work: [PendingWork]) -> String {
    var counts: [(JobKind, Int)] = []
    for w in work {
      if let i = counts.firstIndex(where: { $0.0 == w.kind }) { counts[i].1 += 1 } else { counts.append((w.kind, 1)) }
    }
    return counts.map { "\($0.0.label) \($0.1)" }.joined(separator: " · ")
  }
}

// 과목 머리: 세리프로 쓴 이름, 학년·수준 · 단원 수 · 개념 수. 마우스를 올리면 과목 메뉴가 보인다 (DECISIONS.md 39).
struct SubjectHeader: View {
  @Environment(AppModel.self) private var model
  let subject: SubjectSummary
  let unitCount: Int
  @State private var renaming = false
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 6) {
      VStack(alignment: .leading, spacing: 3) {
        Text(subject.name).font(.system(size: 20, weight: .semibold, design: .serif)).foregroundStyle(.primary).lineLimit(2)
        Text(meta).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
      }
      Spacer(minLength: 0)
      Menu {
        Button("과목 이름 바꾸기·합치기…") { renaming = true }
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .opacity(hovering ? 1 : 0)
      .help("과목 이름 바꾸기·합치기")
    }
    .padding(.top, 4)
    .padding(.bottom, 8)
    .onHover { hovering = $0 }
    .sheet(isPresented: $renaming) { SubjectRenameSheet(subject: subject) }
  }

  var meta: String {
    let concepts = model.concepts[subject.id]?.count ?? 0
    return (subject.grades + subject.levels + ["단원 \(unitCount)", "개념 \(concepts)"]).joined(separator: " · ")
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
      Text(Self.title(source)).font(.system(size: 12.5)).lineLimit(2)
      HStack(spacing: 4) {
        Text(Self.date(source.meta.received))
        Text("· \(source.meta.pages)쪽 ·")
        ReadingBadge(source: source)
        if let memo = source.labels.memo { Text("· \(memo)").lineLimit(1) }
      }
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .monospacedDigit()
    }
    .padding(.vertical, 2)
  }

  // 파일 이름에서 확장자를 떼고 _ 를 띄어 쓴다
  static func title(_ source: SourceSummary) -> String {
    let name = (source.meta.original.name as NSString).deletingPathExtension
    return name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "  ", with: " ")
  }

  // 화면 글은 한국어다. 시스템 언어와 상관없이 "10월 18일 (일)"로 쓴다
  static let korean = Locale(identifier: "ko_KR")

  static func date(_ iso: String) -> String {
    guard let d = Clock.parse(iso) else { return "" }
    return d.formatted(.dateTime.month().day().weekday(.abbreviated).locale(Self.korean))
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
