// 과목 → 개념 목록 → 학습 페이지. iPad 와 큰 화면은 나란히, iPhone 은 차례로 쌓인다 (MOBILE.md 의 화면).
import JindeskKit
import SwiftUI

struct RootView: View {
  @Environment(MobileModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    @Bindable var model = model
    NavigationSplitView {
      SubjectList()
    } content: {
      if let subject = model.subject {
        ConceptList(subject: subject)
      } else {
        ContentUnavailableView("과목을 고릅니다", systemImage: "books.vertical")
      }
    } detail: {
      NavigationStack { detail }
    }
    .sheet(isPresented: $model.showSettings) { SettingsView() }
    .sheet(item: $model.sourcePeek) { SourcePageView(peek: $0) }
    .alert("앱을 업데이트하세요", isPresented: Binding(get: { model.updateNotice != nil }, set: { if !$0 { model.updateNotice = nil } })) {
      Button("확인", role: .cancel) {}
    } message: {
      Text(model.updateNotice ?? "")
    }
    .task { await model.sync(force: false) }
    .onChange(of: scenePhase) {
      if scenePhase == .active { Task { await model.sync(force: false) } }
    }
  }

  // 과목 개념 지도이거나 학습 페이지
  @ViewBuilder private var detail: some View {
    if let subject = MobileModel.mapSubject(model.concept) {
      ConceptMapScreen(subject: subject).id(subject)
    } else if let id = model.concept, let concept = model.concept(id) {
      ConceptPage(concept: concept)
    } else {
      ContentUnavailableView("개념을 고릅니다", systemImage: "doc.text")
    }
  }
}

struct SubjectList: View {
  @Environment(MobileModel.self) private var model
  // 찾기는 다음 판에서 만든다. 이번에는 작동하지 않는 검색바만 둔다 (DECISIONS.md 29).
  @State private var searchText = ""

  var body: some View {
    @Bindable var model = model
    List(selection: $model.subject) {
      if model.data == nil {
        Section {
          VStack(alignment: .leading, spacing: 6) {
            Text("아직 받은 학습 페이지가 없습니다").font(.headline)
            Text(model.config.isComplete && model.hasToken ? "아래로 당겨 받습니다." : "설정에서 데이터 리포와 읽기 토큰을 넣습니다.")
              .font(.subheadline).foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }
      } else {
        Section("과목") {
          ForEach(model.subjects, id: \.id) { s in
            VStack(alignment: .leading, spacing: 2) {
              Text(s.name)
              Text("개념 \(s.count)개").font(.caption).foregroundStyle(.secondary)
            }
            .tag(s.id)
          }
        }
      }
      Section { SyncStatusRow() }
    }
    .navigationTitle("Jindesk")
    .searchable(text: $searchText, prompt: "개념 찾기")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("설정", systemImage: "gearshape") { model.showSettings = true }
      }
    }
    .refreshable { await model.sync(force: true) }
  }
}

// 받은 판과 받기 상태
struct SyncStatusRow: View {
  @Environment(MobileModel.self) private var model

  var body: some View {
    switch model.state {
    case .syncing(let done, let total):
      HStack(spacing: 8) {
        ProgressView()
        Text(total > 0 ? "받는 중 · \(done)/\(total)" : "새 판을 찾는 중").font(.footnote).foregroundStyle(.secondary)
      }
    case .failed(let message):
      VStack(alignment: .leading, spacing: 2) {
        Text("받지 못했습니다").font(.footnote.weight(.medium)).foregroundStyle(.orange)
        Text(message).font(.footnote).foregroundStyle(.secondary)
        if let line = Self.received(model.manifest) { Text("지금 보이는 것: \(line)").font(.caption).foregroundStyle(.tertiary) }
      }
    case .idle:
      Text(Self.received(model.manifest).map { "받은 판 · \($0)" } ?? "받은 판이 없습니다").font(.footnote).foregroundStyle(.secondary)
    }
  }

  static func received(_ manifest: MirrorManifest?) -> String? {
    guard let manifest else { return nil }
    let at = manifest.at.prefix(16).replacingOccurrences(of: "T", with: " ")
    return "\(at) · \(manifest.commit.prefix(7))"
  }
}

// 과목의 개념: 목차 항목마다 묶는다 (맥의 목록 칸과 같은 묶음). 목차에 없는 개념은 제안된 이름으로 묶는다.
struct ConceptList: View {
  @Environment(MobileModel.self) private var model
  let subject: String

  var body: some View {
    @Bindable var model = model
    let concepts = model.concepts[subject] ?? []
    let syllabus = model.syllabi[subject]
    List(selection: $model.concept) {
      if !concepts.isEmpty {
        let map = model.conceptMap(subject, showOthers: true)
        Section {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("개념 지도")
              Text("개념 \(map.conceptCount) · 선수 연결 \(map.linkCount)").font(.caption).foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Color.accentColor)
          }
          .tag(MobileModel.mapSelection(subject))
        }
      }
      if let syllabus {
        ForEach(syllabus.flat, id: \.item.code) { entry in
          let inItem = concepts.filter { $0.item.map(ItemPath.dir) == ItemPath.dir(entry.item.code) }
          if !inItem.isEmpty {
            Section("\(entry.item.code) \(entry.item.title)") {
              ForEach(inItem) { ConceptRow(concept: $0).tag($0.id) }
            }
          }
        }
      }
      ForEach(Self.groups(concepts.filter { $0.item == nil }, prefix: syllabus == nil ? nil : "목차 밖 · "), id: \.name) { group in
        Section(group.name) {
          ForEach(group.concepts) { ConceptRow(concept: $0).tag($0.id) }
        }
      }
    }
    .navigationTitle(model.subjects.first { $0.id == subject }?.name ?? subject)
    .refreshable { await model.sync(force: true) }
  }

  static func groups(_ concepts: [Concept], prefix: String?) -> [(name: String, concepts: [Concept])] {
    var order: [String] = []
    var byName: [String: [Concept]] = [:]
    for c in concepts {
      let name = (prefix ?? "") + (c.item ?? c.itemProposed ?? "목차 밖")
      if byName[name] == nil { order.append(name) }
      byName[name, default: []].append(c)
    }
    return order.sorted().map { ($0, byName[$0]!) }
  }
}

struct ConceptRow: View {
  @Environment(MobileModel.self) private var model
  let concept: Concept

  var body: some View {
    let titles = model.pageTitles(concept)
    VStack(alignment: .leading, spacing: 2) {
      Text(concept.title).lineLimit(2)
      HStack(spacing: 6) {
        if let ko = titles.ko { Text(ko) }
        if !titles.hasPage { Text("페이지 만드는 중").foregroundStyle(.orange) }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 1)
  }
}
