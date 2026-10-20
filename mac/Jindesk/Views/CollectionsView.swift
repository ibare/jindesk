import JindeskKit
import SwiftUI

// 오늘 (DECISIONS.md 32): 위에 할 일(멈춘 일, 고를 새 판), 아래에 지난 7일 동안 넣은 자료를 날마다 묶어 그 자료에서 정리된 개념을 보인다
struct TodayView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let bundles = model.recentBundles(days: 7)
    let candidates = model.candidates()
    let proposals = model.proposals
    if bundles.isEmpty && candidates.isEmpty && proposals.isEmpty && model.waitingWork.isEmpty {
      ContentUnavailableView("오늘 볼 것이 아직 없어요", systemImage: "sun.max", description: Text("자료를 넣으면 그 묶음에서 정리된 개념이 여기에 모입니다."))
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          if !model.waitingWork.isEmpty || !candidates.isEmpty || !proposals.isEmpty {
            ListLabel(text: "할 일", trailing: "\((model.waitingWork.isEmpty ? 0 : 1) + candidates.count + proposals.count)").padding(.horizontal, 10).padding(.top, 6)
            VStack(spacing: 0) {
              if !model.waitingWork.isEmpty { PendingBanner() }
              ForEach(proposals) { p in
                if p.id != proposals.first?.id || !model.waitingWork.isEmpty { Divider().padding(.horizontal, 10) }
                ProposalRow(proposal: p)
              }
              ForEach(candidates) { d in
                if d.id != candidates.first?.id || !model.waitingWork.isEmpty || !proposals.isEmpty { Divider().padding(.horizontal, 10) }
                CandidateRow(directive: d)
              }
            }
            .card()
          }
          ForEach(Self.days(bundles, model: model), id: \.label) { day in
            ListLabel(text: "\(day.label) 넣은 묶음", trailing: "\(day.bundles.count)").padding(.horizontal, 10).padding(.top, 10)
            ForEach(day.bundles) { BundleCard(bundle: $0) }
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
      }
    }
  }

  // 넣은 날마다 묶는다 ("오늘", "어제", "10월 16일 금요일"). 나중에 자료를 더한 묶음은 더한 날로 올라온다.
  static func days(_ bundles: [SourceBundle], model: AppModel) -> [(label: String, bundles: [SourceBundle])] {
    var out: [(label: String, bundles: [SourceBundle])] = []
    for b in bundles {
      let label = Clock.parse(model.lastReceived(b)).map { d in
        Calendar.current.isDateInToday(d) ? "오늘" : Calendar.current.isDateInYesterday(d) ? "어제" : d.formatted(.dateTime.month().day().weekday(.wide).locale(SourceRow.korean))
      } ?? "날짜 모름"
      if out.last?.label == label { out[out.count - 1].bundles.append(b) } else { out.append((label, [b])) }
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

// 넣은 묶음 하나: 이름, 자료와 쪽, 단계 막대, 그 묶음에서 정리된 개념 (DECISIONS.md 35)
struct BundleCard: View {
  @Environment(AppModel.self) private var model
  let bundle: SourceBundle

  var body: some View {
    let rows = model.concepts(fromBundle: bundle).map { (concept: $0, state: model.pageState($0)) }
    let progress = model.progress(bundle)
    VStack(alignment: .leading, spacing: 0) {
      Button {
        model.selection = .bundle(bundle.id)
      } label: {
        VStack(alignment: .leading, spacing: 6) {
          Text(model.bundleTitle(bundle)).font(.system(size: 14.5, design: .serif)).lineLimit(2).multilineTextAlignment(.leading)
          Text(meta).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
          HStack(spacing: 8) {
            StageBar(progress: progress, onAccent: model.selection == .bundle(bundle.id)).frame(width: 110)
            Text(progress.summary).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .contentShape(Rectangle())
        .rowHighlight(model.selection == .bundle(bundle.id))
      }
      .buttonStyle(.plain)
      if !rows.isEmpty {
        Divider().padding(.horizontal, 8).padding(.vertical, 4)
        ListLabel(text: "정리된 개념", trailing: rows.compactMap(\.state.madeAt).max()).padding(.horizontal, 8).padding(.bottom, 2)
        ForEach(rows, id: \.concept.id) { row in
          Button {
            model.selection = .concept(row.concept.id)
          } label: {
            HStack(spacing: 8) {
              ConceptNames(title: row.concept.title, titleKo: row.state.titleKo)
              Spacer(minLength: 4)
              if let note = row.state.note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
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

  // "자료 2 · 61쪽 · 22:45 넣음"
  var meta: String {
    let members = model.members(bundle)
    let time = Clock.parse(model.lastReceived(bundle)).map { Self.clock.string(from: $0) + " 넣음" }
    return ["자료 \(members.count)", "\(members.map(\.meta.pages).reduce(0, +))쪽", time].compactMap { $0 }.joined(separator: " · ")
  }

  static let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
  }()
}

// 묶음의 단계 막대: 읽기 · 정리 · 페이지 · 한국어. 끝난 칸은 채우고, 도는 칸은 흐리게 채운다.
struct StageBar: View {
  let progress: AppModel.BundleProgress
  // 고른 줄의 강조색 위에 그린다 (흰색 계열)
  var onAccent = false

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(progress.stages.enumerated()), id: \.offset) { _, stage in
        Capsule().fill(color(stage.state)).frame(height: 4)
      }
    }
    .accessibilityElement()
    .accessibilityLabel(progress.summary)
  }

  func color(_ state: AppModel.StageState) -> Color {
    if onAccent {
      switch state {
      case .done: return .white
      case .active, .failed: return .white.opacity(0.55)
      case .waiting, .none: return .white.opacity(0.25)
      }
    }
    return switch state {
    case .done: Color.accentColor
    case .active: Color.accentColor.opacity(0.45)
    case .failed: Color.red.opacity(0.7)
    case .waiting, .none: Color.primary.opacity(0.15)
    }
  }
}

// 모아 보기 (DECISIONS.md 34): 위에 범주 칩 세 줄(사전, 모음, 내 것)과 과목 거르기. 목록은 첫 글자로 묶고 오른쪽에 A–Z 인덱스를 둔다.
// 고른 항목은 내용 칸에 연다 (메모와 자료는 그 개념과 자료).
struct CollectionsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let items = model.compendium(model.collectionsTab, subject: model.collectionsSubject)
    let sections = AlphaIndex.sections(items) { $0.index }
    VStack(spacing: 0) {
      CategoryChips().padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
      Divider()
      HStack {
        Text(Self.headline(model.collectionsTab, items)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        Spacer(minLength: 0)
        Menu(model.library.subjects.first { $0.id == model.collectionsSubject }?.name ?? "모든 과목") {
          Button("모든 과목") { model.collectionsSubject = nil }
          Divider()
          ForEach(model.library.subjects) { s in Button(s.name) { model.collectionsSubject = s.id } }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 12))
      }
      .padding(.leading, 18)
      .padding(.trailing, 12)
      .padding(.vertical, 6)
      if items.isEmpty {
        EmptyList(icon: "square.stack", title: Self.emptyTitle(model.collectionsTab), detail: Self.emptyDetail(model.collectionsTab))
      } else {
        ScrollViewReader { proxy in
          HStack(spacing: 0) {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.letter) { section in
                  Section {
                    ForEach(section.items) { CompendiumRow(item: $0) }
                  } header: {
                    Text(section.letter).font(.system(size: 11.5, weight: .bold)).foregroundStyle(Color.accentColor)
                      .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .background(.background)
                      .id("letter:\(section.letter)")
                  }
                }
              }
              .padding(.leading, 8)
              .padding(.bottom, 16)
            }
            AlphaIndexBar(present: Set(sections.map(\.letter))) { l in withAnimation { proxy.scrollTo("letter:\(l)", anchor: .top) } }
          }
        }
      }
    }
  }

  static func headline(_ tab: CollectionsTab, _ items: [CompendiumItem]) -> String {
    switch tab {
    case .terms: "용어 \(items.count) · 영어 ↔ 한국어"
    case .symbols: "기호 \(items.count)"
    case .commandTerms: "Command terms \(items.count) · 숫자는 붙은 개념 수"
    case .ib: "IB 맥락 \(items.count) · 숫자는 묶인 개념 수"
    case .links: "과목 사이 연결 \(items.count)"
    case .sources: "자료 \(items.count)"
    default: "\(tab.label) \(items.count) · 개념 이름순"
    }
  }

  static func emptyTitle(_ tab: CollectionsTab) -> String {
    switch tab {
    case .links: "아직 과목 사이 연결이 없어요"
    case .memos: "아직 메모가 없어요"
    case .sources: "아직 자료가 없어요"
    default: "아직 \(tab.label)이 없어요"
    }
  }

  static func emptyDetail(_ tab: CollectionsTab) -> String {
    switch tab {
    case .terms: "자료를 읽으면 영어 용어와 한국어 뜻이 여기에 모입니다."
    case .symbols: "개념이 정리되면 그 개념의 기호표가 여기에 모입니다."
    case .commandTerms, .ib, .formulas: "관점 붙이기가 끝나면 여기에 모입니다."
    case .mistakes: "학습 페이지의 오개념 상자가 여기에 모입니다."
    case .references: "관점 붙이기가 찾은 공개 자료가 여기에 모입니다."
    case .links: "두 과목 이상에서 개념이 정리되면, 서로 이어지는 개념이 여기에 모입니다."
    case .checks: "학습 페이지가 만들어지면 그 페이지의 확인 문제가 여기에 모입니다."
    case .memos: "학습 페이지의 문단에 남긴 메모가 여기에 모입니다."
    case .sources: "학교에서 받은 자료를 넣으면 여기에 모입니다."
    }
  }
}

// 범주 칩 세 줄 (사전, 모음, 내 것)
struct CategoryChips: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ForEach(CollectionsTab.groups, id: \.name) { group in
        HStack(alignment: .top, spacing: 6) {
          Text(group.name).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading).padding(.top, 5)
          FlowLayout(spacing: 6) {
            ForEach(group.tabs) { tab in
              let on = model.collectionsTab == tab
              Button {
                model.collectionsTab = tab
              } label: {
                Text(tab.label)
                  .font(.system(size: 12.5, weight: .medium))
                  .foregroundStyle(on ? Color.white : Color.primary)
                  .padding(.horizontal, 10)
                  .frame(height: 24)
                  .background(Capsule().fill(on ? Color.accentColor : Color.clear))
                  .overlay(Capsule().stroke(on ? Color.clear : Color.primary.opacity(0.22)))
                  .contentShape(Capsule())
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(on ? .isSelected : [])
            }
          }
        }
      }
    }
  }
}

struct CompendiumRow: View {
  @Environment(AppModel.self) private var model
  let item: CompendiumItem

  var body: some View {
    Button {
      model.selection = item.open
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        VStack(alignment: .leading, spacing: 1) {
          Text(item.title)
            .font(item.symbol ? .system(size: 15, design: .serif).italic() : .system(size: 13, weight: .semibold))
            .lineLimit(2)
          if !item.sub.isEmpty { Text(item.sub).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let n = item.count { Text("\(n)").font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit() }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .rowHighlight(model.selection == item.open)
    }
    .buttonStyle(.plain)
  }
}

// 오른쪽 A–Z 인덱스. 항목이 있는 글자만 누를 수 있다.
struct AlphaIndexBar: View {
  let present: Set<String>
  let jump: (String) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ForEach(AlphaIndex.letters, id: \.self) { l in
        let on = present.contains(l)
        Button {
          jump(l)
        } label: {
          Text(l).font(.system(size: 9.5, weight: .bold)).foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!on)
        .accessibilityLabel("\(l) 로 가기")
      }
    }
    .frame(width: 22)
    .padding(.vertical, 6)
  }
}
