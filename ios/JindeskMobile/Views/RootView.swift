// 과목 → 단원 → 개념 목록 → 학습 페이지 (DECISIONS.md 39). iPad 와 큰 화면은 과목 · 단원 · 개념 목록이 나란히 서고
// 학습 페이지는 개념 목록 자리에 올라온다. iPhone 은 차례로 쌓인다 (MOBILE.md 의 화면).
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
      if model.subject == MobileModel.termsSelection || model.subject == MobileModel.symbolsSelection {
        DictionaryList(symbols: model.subject == MobileModel.symbolsSelection)
      } else if let subject = model.subject {
        UnitList(subject: subject)
      } else {
        ContentUnavailableView("과목을 고릅니다", systemImage: "books.vertical")
      }
    } detail: {
      NavigationStack(path: $model.pages) {
        detail.navigationDestination(for: PageRoute.self) { page($0) }
      }
    }
    .sheet(isPresented: $model.showSettings) { SettingsView() }
    .sheet(item: $model.sourcePeek) { SourcePageView(peek: $0) }
    .sheet(item: $model.lookup) { LookupSheet(lookup: $0) }
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

  // 과목 개념 지도이거나 단원의 개념 목록
  @ViewBuilder private var detail: some View {
    if let subject = MobileModel.mapSubject(model.unit) {
      ConceptMapScreen(subject: subject).id(subject)
    } else if let unit = MobileModel.unitKey(model.unit) {
      ConceptList(subject: unit.subject, key: unit.key).id(model.unit)
    } else {
      ContentUnavailableView("단원을 고릅니다", systemImage: "square.stack")
    }
  }

  // 개념 목록 위에 올린 학습 페이지나 단원 요약
  @ViewBuilder private func page(_ route: PageRoute) -> some View {
    switch route {
    case .concept(let id):
      if let concept = model.concept(id) {
        ConceptPage(concept: concept)
      } else {
        ContentUnavailableView("개념을 찾지 못했습니다", systemImage: "questionmark.folder")
      }
    case .summary(let subject, let key):
      UnitSummaryScreen(subject: subject, key: key)
    }
  }
}

extension Color {
  // 앱 아이콘의 리본 색 (맥과 같다). 하루 안에 정리된 개념의 점
  static let ribbon = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.886, green: 0.333, blue: 0.247, alpha: 1) : UIColor(red: 0.776, green: 0.231, blue: 0.153, alpha: 1)
    })
}

// 하루 안에 정리된 개념의 점 (DECISIONS.md 39)
struct NewDot: View {
  var body: some View {
    Circle().fill(Color.ribbon).frame(width: 7, height: 7).accessibilityLabel("새로 정리됨")
  }
}

struct SubjectList: View {
  @Environment(MobileModel.self) private var model
  // 찾기: 개념, 용어, 기호 (DECISIONS.md 34). 찾기 칸은 화면 위에 둔다.
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
      } else if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
        SearchResults(query: searchText.trimmingCharacters(in: .whitespaces))
      } else {
        Section("과목") {
          ForEach(model.subjects, id: \.id) { s in
            HStack(spacing: 8) {
              VStack(alignment: .leading, spacing: 2) {
                Text(s.name)
                Text("단원 \(model.units(s.id).count) · 개념 \(s.count)").font(.caption).foregroundStyle(.secondary)
              }
              Spacer(minLength: 6)
              if model.hasNew(subject: s.id) { NewDot() }
            }
            .tag(s.id)
          }
        }
        Section("사전") {
          LabeledContent("용어", value: "\(model.glossary.terms.count)").tag(MobileModel.termsSelection)
          LabeledContent("기호", value: "\(model.symbols.count)").tag(MobileModel.symbolsSelection)
        }
      }
      Section { SyncStatusRow() }
    }
    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "개념·용어·기호 찾기")
    #if DEBUG
      // 화면 확인: 찾기 칸에 넣어 둔 채 연다 (-searchText <말>)
      .onAppear { if let q = UserDefaults.standard.string(forKey: "searchText") { searchText = q } }
    #endif
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

// 과목의 단원: 맨 위에 개념 지도, 그 아래 단원 (이름의 알파벳순, DECISIONS.md 39). 맥의 과목 단계와 같다.
struct UnitList: View {
  @Environment(MobileModel.self) private var model
  let subject: String

  var body: some View {
    @Bindable var model = model
    let units = model.units(subject)
    List(selection: $model.unit) {
      if !units.isEmpty {
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
        Section {
          ForEach(units) { u in
            HStack(spacing: 8) {
              Text(u.name).lineLimit(1)
              Spacer(minLength: 6)
              if u.hasNew { NewDot() }
              Text("\(u.concepts.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .tag(MobileModel.unitSelection(subject, u.key))
          }
        } header: {
          HStack {
            Text("단원 \(units.count)")
            Spacer()
            Text("A–Z")
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle(model.subjects.first { $0.id == subject }?.name ?? subject)
    .refreshable { await model.sync(force: true) }
  }
}

// 단원의 개념: 맨 위에 단원 요약, 그 아래 개념 (배우는 순서). 누르면 그 위에 올린다.
struct ConceptList: View {
  @Environment(MobileModel.self) private var model
  let subject: String
  let key: String

  var body: some View {
    let unit = model.unit(subject, key)
    List {
      Section {
        NavigationLink(value: PageRoute.summary(subject, key)) { UnitRow() }
      }
      Section {
        ForEach(unit.concepts) { c in
          NavigationLink(value: PageRoute.concept(c.id)) { ConceptRow(concept: c) }
        }
      }
    }
    .navigationTitle(unit.title)
    .refreshable { await model.sync(force: true) }
  }
}

// 단원의 개념 목록 첫 줄: 단원 요약을 연다 (DECISIONS.md 34)
struct UnitRow: View {
  var body: some View {
    Label("단원 요약", systemImage: "doc.text.below.ecg").foregroundStyle(Color.accentColor)
  }
}

struct ConceptRow: View {
  @Environment(MobileModel.self) private var model
  let concept: Concept

  var body: some View {
    let titles = model.pageTitles(concept)
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(concept.title).lineLimit(2)
        HStack(spacing: 6) {
          if let ko = titles.ko { Text(ko) }
          if !titles.hasPage { Text("페이지 만드는 중").foregroundStyle(.orange) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 6)
      if concept.isNew() { NewDot() }
    }
    .padding(.vertical, 1)
  }
}
