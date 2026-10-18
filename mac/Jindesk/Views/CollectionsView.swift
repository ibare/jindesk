import JindeskKit
import SwiftUI

// 오늘 (DECISIONS.md 32): 위에 할 일(멈춘 일, 고를 새 판), 아래에 지난 7일 동안 넣은 자료를 날마다 묶어 그 자료에서 정리된 개념을 보인다
struct TodayView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let sources = model.recentSources(days: 7)
    let candidates = model.candidates()
    if sources.isEmpty && candidates.isEmpty && model.waitingWork.isEmpty {
      ContentUnavailableView("오늘 볼 것이 아직 없어요", systemImage: "sun.max", description: Text("자료를 넣으면 그 자료에서 정리된 개념이 여기에 모입니다."))
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          if !model.waitingWork.isEmpty || !candidates.isEmpty {
            ListLabel(text: "할 일", trailing: "\((model.waitingWork.isEmpty ? 0 : 1) + candidates.count)").padding(.horizontal, 10).padding(.top, 6)
            VStack(spacing: 0) {
              if !model.waitingWork.isEmpty { PendingBanner() }
              ForEach(candidates) { d in
                if d.id != candidates.first?.id || !model.waitingWork.isEmpty { Divider().padding(.horizontal, 10) }
                CandidateRow(directive: d)
              }
            }
            .card()
          }
          ForEach(Self.days(sources), id: \.label) { day in
            ListLabel(text: "\(day.label) 넣은 자료", trailing: "\(day.sources.count)").padding(.horizontal, 10).padding(.top, 10)
            ForEach(day.sources) { SourceCard(source: $0) }
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
      }
    }
  }

  // 넣은 날마다 묶는다 ("오늘", "어제", "10월 16일 금요일")
  static func days(_ sources: [SourceSummary]) -> [(label: String, sources: [SourceSummary])] {
    var out: [(label: String, sources: [SourceSummary])] = []
    for s in sources {
      let label = Clock.parse(s.meta.received).map { d in
        Calendar.current.isDateInToday(d) ? "오늘" : Calendar.current.isDateInYesterday(d) ? "어제" : d.formatted(.dateTime.month().day().weekday(.wide))
      } ?? "날짜 모름"
      if out.last?.label == label { out[out.count - 1].sources.append(s) } else { out.append((label, [s])) }
    }
    return out
  }
}

// 고를 새 판: 그 개념의 페이지를 열어 견준다
struct CandidateRow: View {
  @Environment(AppModel.self) private var model
  let directive: Directive

  var body: some View {
    let title = model.concept(directive.target.concept)?.title ?? directive.target.concept
    HStack(spacing: 10) {
      Image(systemName: "rectangle.split.2x1").font(.system(size: 13)).foregroundStyle(Color.accentColor).frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text("고를 새 판").font(.system(size: 13, weight: .semibold))
        Text("\(TitleParts(title).head) · \(directive.op.label)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      Button("비교하기") { model.selection = .concept(directive.target.concept) }.controlSize(.small)
    }
    .padding(10)
  }
}

// 넣은 자료 하나와 그 자료에서 정리된 개념
struct SourceCard: View {
  @Environment(AppModel.self) private var model
  let source: SourceSummary

  var body: some View {
    let rows = model.concepts(from: source.id).map { (concept: $0, state: model.pageState($0)) }
    VStack(alignment: .leading, spacing: 0) {
      Button {
        model.selection = .source(source.id)
      } label: {
        HStack(alignment: .top, spacing: 10) {
          SourceThumb()
          VStack(alignment: .leading, spacing: 3) {
            Text(SourceRow.title(source)).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
            Text(meta).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
          }
          Spacer(minLength: 0)
        }
        .padding(8)
        .rowHighlight(model.selection == .source(source.id))
      }
      .buttonStyle(.plain)
      Divider().padding(.horizontal, 8).padding(.vertical, 4)
      if rows.isEmpty {
        Text(status).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 8)
      } else {
        ListLabel(text: "정리된 개념", trailing: rows.compactMap(\.state.madeAt).max()).padding(.horizontal, 8).padding(.bottom, 2)
        ForEach(rows, id: \.concept.id) { row in
          Button {
            model.selection = .concept(row.concept.id)
          } label: {
            HStack(spacing: 8) {
              ConceptNames(title: row.concept.title, titleKo: row.state.titleKo)
              Spacer(minLength: 4)
              if let pages = Occurrence.pagesLabel(row.concept.occurrences, source: source.id) {
                Text(pages).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
              }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .rowHighlight(model.selection == .concept(row.concept.id))
          }
          .buttonStyle(.plain)
          .help(row.concept.title)
        }
        Divider().padding(.horizontal, 8).padding(.top, 4)
        HStack {
          Text("학습 페이지 \(rows.filter(\.state.hasPage).count) · 확인 문제 \(rows.map(\.state.checks).reduce(0, +))")
            .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
          Spacer(minLength: 0)
          if let subject = rows.first?.concept.subject {
            Button("개념 지도에서 보기") { model.selection = .map(subject) }.buttonStyle(.link).font(.system(size: 11.5))
          }
        }
        .padding(8)
      }
    }
    .padding(4)
    .card()
  }

  // "Extended Mathematics · 55쪽 · 22:45 넣음"
  var meta: String {
    let time = Clock.parse(source.meta.received).map { Self.clock.string(from: $0) + " 넣음" }
    return [model.subjectName(source), "\(source.meta.pages)쪽", time].compactMap { $0 }.joined(separator: " · ")
  }

  // 아직 개념이 없을 때
  var status: String {
    switch model.readingState(source.id) {
    case .unread: "읽기 전이에요"
    case .queued: "읽기를 기다려요"
    case .reading(let phase): "읽는 중 · \(phase)"
    case .read: "개념을 정리하는 중이에요"
    case .failed: "읽지 못했어요"
    }
  }

  static let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
  }()
}

// 모아 보기 (DECISIONS.md 32): 연결(과목 사이 연결), 자료, 문제(확인 문제), 메모
struct CollectionsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    VStack(spacing: 0) {
      Picker("", selection: $model.collectionsTab) {
        ForEach(CollectionsTab.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 12)
      .padding(.top, 10)
      .padding(.bottom, 4)
      switch model.collectionsTab {
      case .links: LinksList()
      case .sources: SourcesList()
      case .checks: ChecksList()
      case .memos: MemosList()
      }
    }
  }
}

// 목록 위의 한 줄: 수와 거르기·차례
struct ListHeadline<Trailing: View>: View {
  let text: String
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack {
      Text(text).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
      Spacer(minLength: 0)
      trailing
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
  }
}

// 확인 문제: 개념마다 묶어 배우는 순서로. 답을 목록에서 펼쳐 보고, 그 학습 페이지를 연다.
struct ChecksList: View {
  @Environment(AppModel.self) private var model
  // 거를 과목 (nil 이면 모든 과목)
  @State private var subject: String?
  @State private var open: Set<String> = []

  var body: some View {
    let all = model.allChecks()
    let checks = all.filter { subject == nil || $0.concept.subject == subject }
    let groups = Self.groups(checks)
    if all.isEmpty {
      EmptyList(icon: "checklist", title: "아직 확인 문제가 없어요", detail: "학습 페이지가 만들어지면 그 페이지의 확인 문제가 개념마다 여기에 모입니다.")
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ListHeadline(text: "확인 문제 \(checks.count) · 개념 \(groups.count)") {
            Menu(model.library.subjects.first { $0.id == subject }?.name ?? "모든 과목") {
              Button("모든 과목") { subject = nil }
              Divider()
              ForEach(model.library.subjects) { s in Button(s.name) { subject = s.id } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 12))
          }
          ForEach(groups, id: \.concept.id) { group in
            CheckGroupHeader(concept: group.concept, count: group.checks.count)
            ForEach(Array(group.checks.enumerated()), id: \.element.id) { i, check in
              CheckRow(number: i + 1, check: check, open: open.contains(check.id)) {
                if open.contains(check.id) { open.remove(check.id) } else { open.insert(check.id) }
              }
            }
          }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 16)
      }
    }
  }

  // 받은 차례(과목끼리, 배우는 순서)를 지키며 개념마다 묶는다
  static func groups(_ checks: [AppModel.PageCheck]) -> [(concept: Concept, checks: [AppModel.PageCheck])] {
    var out: [(concept: Concept, checks: [AppModel.PageCheck])] = []
    for c in checks {
      if out.last?.concept.id == c.concept.id { out[out.count - 1].checks.append(c) } else { out.append((c.concept, [c])) }
    }
    return out
  }
}

struct CheckGroupHeader: View {
  @Environment(AppModel.self) private var model
  let concept: Concept
  let count: Int

  var body: some View {
    let ko = model.pageState(concept).titleKo.map { TitleParts($0).head }
    let subject = model.library.subjects.first { $0.id == concept.subject }?.name
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(TitleParts(concept.title).head).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        Text([ko, subject].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 4)
      Text("\(count)문제").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
    }
    .padding(.horizontal, 10)
    .padding(.top, 16)
    .padding(.bottom, 4)
  }
}

struct CheckRow: View {
  @Environment(AppModel.self) private var model
  let number: Int
  let check: AppModel.PageCheck
  let open: Bool
  let toggle: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(number)").font(.system(size: 12)).foregroundStyle(.tertiary).monospacedDigit().frame(width: 18)
      VStack(alignment: .leading, spacing: 6) {
        Text(TexText.display(check.question)).font(.system(size: 13)).lineSpacing(2).lineLimit(open ? nil : 3)
          .fixedSize(horizontal: false, vertical: true)
        if open, let answer = check.answer {
          VStack(alignment: .leading, spacing: 3) {
            Text("답").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Color.accentColor)
            Text(TexText.display(answer)).font(.system(size: 12.5)).lineSpacing(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
        }
        HStack(spacing: 14) {
          if check.answer != nil { Button(open ? "답 숨기기" : "답 보기", action: toggle).buttonStyle(.link) }
          Button("페이지에서 보기") { model.selection = .concept(check.concept.id) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
    .onHover { hovering = $0 }
  }
}

// 원래 자료: 넣은 날 순이나 이름 순
struct SourcesList: View {
  @Environment(AppModel.self) private var model
  @State private var byName = false

  var body: some View {
    let sources = byName
      ? model.library.sources.sorted { SourceRow.title($0).localizedStandardCompare(SourceRow.title($1)) == .orderedAscending }
      : model.library.sources.sorted { $0.meta.received > $1.meta.received }
    if sources.isEmpty {
      EmptyList(icon: "doc", title: "아직 자료가 없어요", detail: "학교에서 받은 자료를 넣으면 여기에 모입니다.")
    } else {
      let checks = Dictionary(grouping: model.allChecks(), by: \.concept.id).mapValues(\.count)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ListHeadline(text: "자료 \(sources.count) · \(sources.map(\.meta.pages).reduce(0, +))쪽") {
            Menu(byName ? "이름 순" : "넣은 날 순") {
              Button("넣은 날 순") { byName = false }
              Button("이름 순") { byName = true }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 12))
          }
          ForEach(sources) { source in
            let concepts = model.concepts(from: source.id)
            Button {
              model.selection = .source(source.id)
            } label: {
              HStack(alignment: .top, spacing: 10) {
                SourceThumb()
                VStack(alignment: .leading, spacing: 3) {
                  Text(SourceRow.title(source)).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                  Text([model.subjectName(source), SourceRow.date(source.meta.received), "\(source.meta.pages)쪽"].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                  if concepts.isEmpty {
                    ReadingBadge(source: source).font(.system(size: 11.5)).foregroundStyle(.secondary)
                  } else {
                    Text("개념 \(concepts.count) · 확인 문제 \(concepts.map { checks[$0.id] ?? 0 }.reduce(0, +))")
                      .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                  }
                }
                Spacer(minLength: 0)
              }
              .padding(8)
              .rowHighlight(model.selection == .source(source.id))
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 16)
      }
    }
  }
}

// 과목 사이 연결
struct LinksList: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let links = model.crossLinks()
    if links.isEmpty {
      EmptyList(icon: "link", title: "아직 과목 사이 연결이 없어요", detail: "두 과목 이상에서 개념이 정리되면, 서로 이어지는 개념이 여기에 모입니다.")
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ListHeadline(text: "연결 \(links.count)") { EmptyView() }
          ForEach(links, id: \.id) { l in
            VStack(alignment: .leading, spacing: 6) {
              HStack(alignment: .top, spacing: 8) {
                LinkEnd(concept: l.from)
                Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(.top, 3)
                LinkEnd(concept: l.to)
              }
              Text(l.note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
          }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 16)
      }
    }
  }
}

struct LinkEnd: View {
  @Environment(AppModel.self) private var model
  let concept: Concept

  var body: some View {
    Button {
      model.selection = .concept(concept.id)
    } label: {
      VStack(alignment: .leading, spacing: 1) {
        Text(TitleParts(concept.title).head).font(.system(size: 12.5, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
        Text(model.library.subjects.first { $0.id == concept.subject }?.name ?? concept.subject).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .rowHighlight(model.selection == .concept(concept.id))
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// 메모 (학습 페이지에 남긴 코멘트). 예전에 남긴 질문과 이상해요도 함께 보인다(DECISIONS.md 30).
struct MemosList: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let comments = model.allComments()
    if comments.isEmpty {
      EmptyList(icon: "pencil", title: "아직 메모가 없어요", detail: "학습 페이지의 문단에 남긴 메모가 여기에 모입니다.")
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ListHeadline(text: "메모 \(comments.count)") { EmptyView() }
          ForEach(comments) { c in
            let concept = c.anchor.flatMap { model.concept($0.concept) }
            Button {
              if let concept { model.selection = .concept(concept.id) }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(TexText.display(c.text ?? "")).font(.system(size: 13)).lineLimit(3).multilineTextAlignment(.leading)
                Text([c.kind == .memo ? nil : c.kind.label, concept.map { TitleParts($0.title).head }, String(c.at.prefix(10))].compactMap { $0 }.joined(separator: " · "))
                  .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 10)
              .padding(.vertical, 8)
              .rowHighlight(concept.map { model.selection == .concept($0.id) } ?? false)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 16)
      }
    }
  }
}
