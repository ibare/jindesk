import JindeskKit
import SwiftUI

// 오늘: 새로 정리된 개념, 답이 온 질문, 고를 새 판, 남은 일
struct TodayView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let recent = model.recentConcepts(days: 7)
    let answers = model.recentAnswers(days: 7)
    let candidates = model.candidates()
    if recent.isEmpty && answers.isEmpty && candidates.isEmpty && model.waitingWork.isEmpty {
      ContentUnavailableView("오늘 볼 것이 아직 없어요", systemImage: "sun.max", description: Text("자료를 넣고 정리가 끝나면 여기에 새로 정리된 개념과 답이 온 질문이 보입니다."))
    } else {
      List {
        if !model.waitingWork.isEmpty { Section { PendingBanner() } }
        if !candidates.isEmpty {
          Section("고를 새 판") {
            ForEach(candidates) { d in
              OpenConceptRow(concept: d.target.concept, title: model.concept(d.target.concept)?.title ?? d.target.concept, detail: "\(d.op.label) · \(d.target.unit)")
            }
          }
        }
        if !answers.isEmpty {
          Section("답이 온 질문") {
            ForEach(answers, id: \.answer.id) { pair in
              OpenConceptRow(
                concept: pair.question.anchor?.concept ?? "", title: pair.question.text ?? "",
                detail: FileOps.prefix(pair.answer.textKo ?? pair.answer.textEn ?? pair.answer.text ?? "", 80))
            }
          }
        }
        if !recent.isEmpty {
          Section("새로 정리된 개념") {
            ForEach(recent) { c in OpenConceptRow(concept: c.id, title: c.title, detail: itemLabel(c)) }
          }
        }
      }
    }
  }
}

extension TodayView {
  // 개념이 놓인 목차 항목 ("U3 Logarithms …"). 목차가 없으면 제안한 항목 이름
  func itemLabel(_ c: Concept) -> String {
    guard let syllabus = model.syllabi[c.subject] else { return c.itemProposed ?? "" }
    guard let item = syllabus.item(c.item) else { return "목차 밖" }
    return "\(item.code) \(item.title)"
  }
}

// 모아 보기: 과목 사이 연결, 원래 자료, 확인 문제, 코멘트
struct CollectionsView: View {
  @Environment(AppModel.self) private var model
  @State private var tab = Tab.links

  enum Tab: String, CaseIterable, Identifiable {
    case links, sources, checks, comments
    var id: String { rawValue }
    var label: String {
      switch self {
      case .links: "과목 사이 연결"
      case .sources: "원래 자료"
      case .checks: "확인 문제"
      case .comments: "코멘트"
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("", selection: $tab) {
        ForEach(Tab.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(12)
      List {
        switch tab {
        case .links:
          let links = model.crossLinks()
          if links.isEmpty { Text("아직 과목 사이 연결이 없어요").foregroundStyle(.secondary) }
          ForEach(links, id: \.id) { l in
            VStack(alignment: .leading, spacing: 3) {
              HStack {
                OpenConceptButton(concept: l.from.id, title: l.from.title, subject: l.from.subject)
                Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary)
                OpenConceptButton(concept: l.to.id, title: l.to.title, subject: l.to.subject)
              }
              Text(l.note).font(.caption).foregroundStyle(.secondary)
            }
          }
        case .sources:
          ForEach(model.library.sources) { s in
            Button {
              model.section = .subjects
              model.selection = .source(s.id)
            } label: {
              SourceRow(source: s).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        case .checks:
          let checks = model.allChecks()
          if checks.isEmpty { Text("아직 확인 문제가 없어요").foregroundStyle(.secondary) }
          ForEach(checks, id: \.id) { c in OpenConceptRow(concept: c.concept, title: c.question, detail: c.title) }
        case .comments:
          let comments = model.allComments()
          if comments.isEmpty { Text("아직 코멘트가 없어요").foregroundStyle(.secondary) }
          ForEach(comments) { c in
            OpenConceptRow(
              concept: c.anchor?.concept ?? "", title: c.text ?? "",
              detail: "\(c.kind.label) · \(model.concept(c.anchor?.concept ?? "")?.title ?? "") · \(String(c.at.prefix(10)))")
          }
        }
      }
    }
  }
}

struct OpenConceptRow: View {
  @Environment(AppModel.self) private var model
  let concept: String
  let title: String
  let detail: String

  var body: some View {
    Button {
      guard model.concept(concept) != nil else { return }
      model.section = .subjects
      model.selection = .concept(concept)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(TexText.plain(title)).lineLimit(2)
        if !detail.isEmpty { Text(TexText.plain(detail)).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct OpenConceptButton: View {
  @Environment(AppModel.self) private var model
  let concept: String
  let title: String
  let subject: String

  var body: some View {
    Button {
      model.section = .subjects
      model.selection = .concept(concept)
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        Text(title)
        Text(model.library.subjects.first { $0.id == subject }?.name ?? subject).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.link)
  }
}
