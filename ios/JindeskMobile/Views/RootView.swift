// 과목 → 단원 → 개념 목록 → 학습 페이지 (DECISIONS.md 39, 43). iPad 는 두 칸이다: 왼쪽 칸은 목록 스택, 오른쪽 칸은 고른 것.
// iPhone 과 iPad 의 좁은 창은 목록 단계 위에 고른 것이 차례로 쌓인다 (MOBILE.md 의 화면).
import JindeskKit
import SwiftUI

struct RootView: View {
  @Environment(MobileModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    @Bindable var model = model
    Group {
      // iPhone 은 가로로 돌려 폭 등급이 넓음이 되어도(Plus·Max) 한 스택이다 (DECISIONS.md 43)
      if UIDevice.current.userInterfaceIdiom == .phone || sizeClass == .compact { StackLayout() } else { SplitLayout() }
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
}

// iPad: 왼쪽 칸은 과목 → 단원 → 개념의 스택, 오른쪽 칸은 고른 것 (DECISIONS.md 43).
// 가로는 두 칸이 나란히 서고(balanced) 개념을 골라도 왼쪽 칸을 그대로 둔다. 세로는 오른쪽 칸이 전체 폭이고 왼쪽 칸을 그 위에
// 띄우며(prominentDetail), 고르면 닫는다. 모양은 방향마다 갈아 끼우므로 돌리면 칸을 새로 만든다. 목록 단계, 고른 것, 개념 지도의 상태는 모델에 있고,
// 학습 페이지 보기는 칸 바깥에 두고 다시 쓴다(PageWebView). UISplitViewController 의 분할 방식을 직접 바꾸는 것은 SwiftUI 가 되돌린다.
struct SplitLayout: View {
  @Environment(MobileModel.self) private var model
  @State private var columns = NavigationSplitViewVisibility.automatic
  @State private var portrait = false

  var body: some View {
    Group {
      if portrait { split.navigationSplitViewStyle(.prominentDetail) } else { split.navigationSplitViewStyle(.balanced) }
    }
    // 돌리면 그 방향의 기본으로 돌아간다 (가로는 두 칸, 세로는 오른쪽 칸만). 세로에서 고른 것이 없으면 왼쪽 칸을 띄워 둔다.
    .onGeometryChange(for: Bool.self) { $0.size.height > $0.size.width } action: { tall in
      portrait = tall
      columns = tall && model.page != nil ? .detailOnly : .all
    }
    // 세로에서 고르면 왼쪽 칸을 닫고, 고른 것이 없어지면(새 판에서 사라짐) 다시 띄운다
    .onChange(of: model.page) { if portrait { columns = model.page == nil ? .all : .detailOnly } }
  }

  private var split: some View {
    @Bindable var model = model
    return NavigationSplitView(columnVisibility: $columns) {
      NavigationStack(path: $model.lists) {
        SubjectList().navigationDestination(for: Route.self) { RouteScreen(route: $0) }
      }
      .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
    } detail: {
      NavigationStack { PageScreen(route: model.page) }
    }
  }
}

// iPhone 과 iPad 의 좁은 창: 목록 단계 위에 고른 것을 올린다. 한 경로에 함께 쌓아야 뒤로 갈 때 목록 단계로 돌아온다.
struct StackLayout: View {
  @Environment(MobileModel.self) private var model

  var body: some View {
    NavigationStack(path: path) {
      SubjectList().navigationDestination(for: Route.self) { RouteScreen(route: $0) }
    }
    .environment(\.stacksPages, true)
  }

  private var path: Binding<[Route]> {
    Binding {
      model.lists + (model.page.map { [Route.page($0)] } ?? [])
    } set: { routes in
      var page: PageRoute?
      if case .page(let last)? = routes.last { page = last }
      let lists = routes.filter { if case .page = $0 { false } else { true } }
      if model.lists != lists { model.lists = lists }
      if model.page != page { model.page = page }
    }
  }
}

// 스택의 한 단계: 과목의 단원, 단원의 개념, 사전, 고른 것(iPhone)
struct RouteScreen: View {
  let route: Route

  var body: some View {
    switch route {
    case .subject(let subject): UnitList(subject: subject)
    case .unit(let subject, let key): ConceptList(subject: subject, key: key)
    case .dictionary(let symbols): DictionaryList(symbols: symbols)
    case .page(let page): PageScreen(route: page)
    }
  }
}

// 고른 것: 학습 페이지, 단원 요약, 과목 개념 지도. 다른 개념을 골라도 같은 학습 페이지 보기를 다시 쓴다 (맥과 같다).
struct PageScreen: View {
  @Environment(MobileModel.self) private var model
  let route: PageRoute?

  var body: some View {
    switch route {
    case .concept(let id)?:
      if let concept = model.concept(id) {
        ConceptPage(concept: concept, kept: true)
      } else {
        ContentUnavailableView("개념을 찾지 못했습니다", systemImage: "questionmark.folder")
      }
    case .summary(let subject, let key)?:
      UnitSummaryScreen(subject: subject, key: key).id(key)
    case .map(let subject)?:
      ConceptMapScreen(subject: subject).id(subject)
    case nil:
      ContentUnavailableView("개념을 고릅니다", systemImage: "square.stack", description: Text("왼쪽 칸에서 과목, 단원, 개념 차례로 들어갑니다."))
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
    List {
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
            NavigationLink(value: Route.subject(s.id)) {
              HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(s.name)
                  Text("단원 \(model.units(s.id).count) · 개념 \(s.count)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if model.hasNew(subject: s.id) { NewDot() }
              }
            }
          }
        }
        Section("사전") {
          NavigationLink(value: Route.dictionary(symbols: false)) { LabeledContent("용어", value: "\(model.glossary.terms.count)") }
          NavigationLink(value: Route.dictionary(symbols: true)) { LabeledContent("기호", value: "\(model.symbols.count)") }
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
// 개념 지도는 오른쪽 칸(iPhone 은 목록 위)에 열고, 단원은 목록 스택에 들어간다.
struct UnitList: View {
  @Environment(MobileModel.self) private var model
  let subject: String

  var body: some View {
    @Bindable var model = model
    let units = model.units(subject)
    List(selection: $model.page) {
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
          .opensPage()
          .tag(PageRoute.map(subject))
        }
        Section {
          ForEach(units) { u in
            NavigationLink(value: Route.unit(subject, u.key)) {
              HStack(spacing: 8) {
                Text(u.name).lineLimit(1)
                Spacer(minLength: 6)
                if u.hasNew { NewDot() }
                Text("\(u.concepts.count)").foregroundStyle(.secondary).monospacedDigit()
              }
            }
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

// 단원의 개념: 맨 위에 단원 요약, 그 아래 개념 (배우는 순서). 고르면 오른쪽 칸(iPhone 은 목록 위)에 열고, 고른 줄이 표시된다.
struct ConceptList: View {
  @Environment(MobileModel.self) private var model
  let subject: String
  let key: String

  var body: some View {
    @Bindable var model = model
    let unit = model.unit(subject, key)
    List(selection: $model.page) {
      Section {
        UnitRow().opensPage().tag(PageRoute.summary(subject, key))
      }
      Section {
        ForEach(unit.concepts) { c in
          ConceptRow(concept: c).opensPage().tag(PageRoute.concept(c.id))
        }
      }
    }
    .navigationTitle(unit.title)
    .refreshable { await model.sync(force: true) }
  }
}

extension EnvironmentValues {
  // 한 스택(StackLayout) 안이다: 고른 것이 목록 위에 올라간다. iPad 왼쪽 칸도 폭 등급은 좁음이라 그것으로 가르지 않는다.
  @Entry var stacksPages = false
}

// 고르면 여는 줄(개념 지도, 단원 요약, 개념). 한 스택에서는 목록 위에 올라가므로 넘어가는 표시를 붙인다.
// iPad 는 오른쪽 칸에 열고 고른 줄이 표시된다.
struct OpensPage: ViewModifier {
  @Environment(\.stacksPages) private var stacksPages

  func body(content: Content) -> some View {
    if stacksPages {
      HStack(spacing: 8) {
        content.frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
      }
    } else {
      content
    }
  }
}

extension View {
  func opensPage() -> some View { modifier(OpensPage()) }
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
