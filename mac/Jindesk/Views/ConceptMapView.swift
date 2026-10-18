import JindeskKit
import SwiftUI

// 개념 지도 (PAGES.md 의 개념 지도): 과목의 개념을 선수 개념으로 이은 그래프. 목록 칸의 "개념 지도" 줄을 고르면 내용 칸에 열린다.
// 지도는 저장하지 않는다. 작업이 끝날 때 다시 읽는 개념 목록에서 그릴 때마다 계산한다 (DECISIONS.md 26).
struct ConceptMapView: View {
  @Environment(AppModel.self) private var model
  let subject: String
  @AppStorage("conceptMapArrangement") private var arrangement = ConceptMap.Arrangement.learning
  @AppStorage("conceptMapShowOthers") private var showOthers = true

  var body: some View {
    // 작업이 끝날 때마다 올라간다. 학습 페이지가 새로 생겼는지 다시 본다.
    let _ = model.commentsVersion
    let map = model.conceptMap(subject, showOthers: showOthers)
    let syllabus = model.syllabi[subject]
    let name = model.library.subjects.first { $0.id == subject }?.name ?? subject
    if map.conceptCount == 0 {
      ContentUnavailableView(
        "아직 정리된 개념이 없어요", systemImage: "point.3.connected.trianglepath.dotted", description: Text("자료를 읽고 개념 정리가 끝나면 지도가 생겨요."))
    } else {
      ConceptMapPane(
        name: name, map: map, layout: map.layout(arrangement, syllabus: syllabus), facts: MapFacts(model: model, map: map), syllabus: syllabus,
        arrangement: $arrangement, showOthers: $showOthers)
    }
  }
}

// 노드마다 보일 것: 목차 코드, 한국어 이름(학습 페이지가 있을 때), 학습 페이지가 있는지, 오늘 정리됐는지
struct MapFacts: Equatable {
  struct Fact: Equatable {
    var code: String?
    var titleKo: String?
    var hasPage = false
    var note: String?
    var isNew = false
    // 다른 과목 개념이면 그 과목 이름
    var subjectName: String?
  }

  var byID: [String: Fact] = [:]

  subscript(_ id: String) -> Fact { byID[id] ?? Fact() }

  @MainActor init(model: AppModel, map: ConceptMap) {
    let today = String(JobID.stamp(Date()).prefix(8))
    for n in map.nodes {
      var f = Fact()
      if n.kind != .missing, let c = model.concept(n.id) {
        let state = model.pageState(c)
        f.titleKo = state.titleKo
        f.hasPage = state.hasPage
        f.note = state.hasPage ? state.note : nil
        f.code = c.item.map { model.syllabi[c.subject]?.item($0)?.code ?? $0.uppercased() } ?? c.itemProposed
        f.isNew = n.curatedOn == today
        if case .other(let subject) = n.kind { f.subjectName = model.library.subjects.first { $0.id == subject }?.name ?? subject }
      }
      byID[n.id] = f
    }
  }
}

// 고른 노드와 그 선수 개념 전체, 이어지는 개념 전체
struct MapHighlight: Equatable {
  enum Role: Int { case dimmed, plain, descendant, ancestor, selected }

  var selected: String?
  var ancestors: Set<String> = []
  var descendants: Set<String> = []

  init(_ selected: String?, in map: ConceptMap) {
    guard let selected, map.node(selected) != nil else { return }
    self.selected = selected
    ancestors = map.ancestors(of: selected)
    descendants = map.descendants(of: selected)
  }

  func role(_ id: String) -> Role {
    guard let selected else { return .plain }
    if id == selected { return .selected }
    if ancestors.contains(id) { return .ancestor }
    if descendants.contains(id) { return .descendant }
    return .dimmed
  }

  func role(_ e: ConceptMap.Edge) -> Role {
    guard let selected else { return .plain }
    if (e.to == selected || ancestors.contains(e.to)) && ancestors.contains(e.from) { return .ancestor }
    if descendants.contains(e.to) && (e.from == selected || descendants.contains(e.from)) { return .descendant }
    return .dimmed
  }
}

// 지도의 크기 (pt). 배율 z 를 곱해 그린다
struct MapGeometry: Equatable {
  static let nodeWidth: CGFloat = 176
  static let nodeHeight: CGFloat = 58
  static let rowPitch: CGFloat = 74
  static let padX: CGFloat = 24
  static let top: CGFloat = 54
  static let padBottom: CGFloat = 28

  let columns: Int
  let rows: Double
  // 칸 간격. 목차대로는 같은 칸 안의 화살표가 칸 사이로 돌아 나가므로 조금 넓다
  let pitch: CGFloat
  let z: CGFloat

  init(_ layout: ConceptMap.Layout, _ arrangement: ConceptMap.Arrangement, z: CGFloat) {
    columns = layout.columns
    rows = layout.rows
    pitch = arrangement == .learning ? 220 : 250
    self.z = z
  }

  var size: CGSize {
    CGSize(
      width: (Self.padX * 2 + CGFloat(max(columns - 1, 0)) * pitch + Self.nodeWidth) * z,
      height: (Self.top + CGFloat(max(rows - 1, 0)) * Self.rowPitch + Self.nodeHeight + Self.padBottom) * z)
  }

  var node: CGSize { CGSize(width: Self.nodeWidth * z, height: Self.nodeHeight * z) }

  // 노드의 왼쪽 위
  func origin(_ p: ConceptMap.Layout.Place) -> CGPoint {
    CGPoint(x: (Self.padX + CGFloat(p.column) * pitch) * z, y: (Self.top + CGFloat(p.row) * Self.rowPitch) * z)
  }

  func center(_ p: ConceptMap.Layout.Place) -> CGPoint {
    let o = origin(p)
    return CGPoint(x: o.x + node.width / 2, y: o.y + node.height / 2)
  }

  func columnX(_ column: Int) -> CGFloat { (Self.padX + CGFloat(column) * pitch) * z }
}

struct ConceptMapPane: View {
  @Environment(AppModel.self) private var model
  let name: String
  let map: ConceptMap
  let layout: ConceptMap.Layout
  let facts: MapFacts
  let syllabus: Syllabus?
  @Binding var arrangement: ConceptMap.Arrangement
  @Binding var showOthers: Bool
  @State private var selected: String?
  // nil 이면 맞춤
  @State private var zoom: CGFloat? = 1
  @State private var viewport: CGSize = .zero
  // 아래 칸에서 고른 개념으로 지도를 옮긴다
  @State private var scrollTarget: String?

  var body: some View {
    let geo = MapGeometry(layout, arrangement, z: currentZoom)
    let highlight = MapHighlight(selected, in: map)
    VStack(spacing: 0) {
      header
      Divider()
      ScrollViewReader { proxy in
        ScrollView([.horizontal, .vertical]) {
          MapCanvas(
            map: map, layout: layout, geo: geo, arrangement: arrangement, syllabus: syllabus, facts: facts, highlight: highlight,
            select: { selected = $0 }, open: open)
          .frame(minWidth: viewport.width, minHeight: viewport.height, alignment: .topLeading)
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        .onChange(of: scrollTarget) { _, id in
          guard let id else { return }
          withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
          scrollTarget = nil
        }
      }
      Divider()
      MapDetail(map: map, facts: facts, highlight: highlight, select: { id in
        selected = id
        scrollTarget = id
      }, open: open)
    }
    .onChange(of: arrangement) { if let selected { scrollTarget = selected } }
    .onAppear {
      // 화면 찍기: 골라 둘 개념
      if let id = model.snapshotDebug?["mapSelect"]?.stringValue, map.node(id) != nil {
        selected = id
        scrollTarget = id
      }
    }
  }

  private var header: some View {
    let title = VStack(alignment: .leading, spacing: 1) {
      Text("\(name) 개념 지도").font(.headline)
      Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
    let controls = HStack(spacing: 12) {
      Picker("배치", selection: $arrangement) {
        Text("배우는 순서").tag(ConceptMap.Arrangement.learning)
        Text("목차대로").tag(ConceptMap.Arrangement.syllabus)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .help("배우는 순서: 선수 개념이 몇 겹 쌓였는지로 칸을 나눕니다. 목차대로: 강의 계획 항목마다 한 칸입니다.")
      Toggle("다른 과목 개념", isOn: $showOthers)
        .toggleStyle(.checkbox)
        .fixedSize()
        .help("이 과목 개념의 선수 개념인 다른 과목 개념을 보입니다")
      ControlGroup {
        Button("작게", systemImage: "minus") { zoom = max(0.5, currentZoom / 1.15) }.labelStyle(.iconOnly)
        Button(zoom == nil ? "맞춤" : "\(Int((currentZoom * 100).rounded()))%") { zoom = zoom == nil ? 1 : nil }
          .help(zoom == nil ? "원래 크기로 봅니다" : "지도가 한눈에 보이게 맞춥니다")
        Button("크게", systemImage: "plus") { zoom = min(1.4, currentZoom * 1.15) }.labelStyle(.iconOnly)
      }
      .controlSize(.small)
      .fixedSize()
    }
    return VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 12) {
          title
          Spacer(minLength: 12)
          controls
        }
        VStack(alignment: .leading, spacing: 8) {
          title
          controls
        }
      }
      MapLegend()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var summary: String {
    var s = "개념 \(map.conceptCount) · 선수 연결 \(map.linkCount) · 아직 없는 개념 \(map.missingCount)"
    if map.hiddenLinks > 0 { s += " · 다른 과목 선수 개념 \(map.hiddenLinks)곳 감춤" }
    return s
  }

  private var currentZoom: CGFloat { zoom ?? fitZoom }

  private var fitZoom: CGFloat {
    let base = MapGeometry(layout, arrangement, z: 1).size
    guard base.width > 0, base.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
    return min(1, max(0.5, min(viewport.width / base.width, viewport.height / base.height)))
  }

  // 학습 페이지가 있는 개념만 연다
  private func open(_ id: String) {
    guard facts[id].hasPage, model.concept(id) != nil else { return }
    model.selection = .concept(id)
  }
}

struct MapCanvas: View {
  let map: ConceptMap
  let layout: ConceptMap.Layout
  let geo: MapGeometry
  let arrangement: ConceptMap.Arrangement
  let syllabus: Syllabus?
  let facts: MapFacts
  let highlight: MapHighlight
  let select: (String?) -> Void
  let open: (String) -> Void

  struct EdgeItem: Identifiable {
    let id: String
    let start: CGPoint
    let end: CGPoint
    let bend: CGFloat
    let role: MapHighlight.Role
    let dashed: Bool
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      DotGrid(z: geo.z)
        .contentShape(Rectangle())
        .onTapGesture { select(nil) }
      labels
      ForEach(edgeItems) { e in
        EdgeShape(start: e.start, end: e.end, bend: e.bend, arrow: 6 * max(geo.z, 0.7))
          .stroke(color(e.role), style: StrokeStyle(lineWidth: e.role.rawValue >= MapHighlight.Role.descendant.rawValue ? 2 : 1.3, lineCap: .round, lineJoin: .round, dash: e.dashed ? [4, 3] : []))
          .allowsHitTesting(false)
      }
      ForEach(map.nodes) { n in
        if let place = layout.places[n.id] {
          MapNodeView(node: n, fact: facts[n.id], role: highlight.role(n.id), z: geo.z)
            .onTapGesture(count: 2) { open(n.id) }
            .onTapGesture { select(n.id) }
            .position(geo.center(place))
            .id(n.id)
        }
      }
    }
    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    .animation(.easeInOut(duration: 0.45), value: layout)
    .animation(.easeOut(duration: 0.15), value: highlight)
  }

  // 배우는 순서: 위에 먼저 → 나중 화살표. 목차대로: 칸마다 항목 코드와 이름
  @ViewBuilder private var labels: some View {
    let z = geo.z
    let font = Font.system(size: 11.5 * z)
    switch arrangement {
    case .learning:
      Text("먼저 배울 것").font(font).foregroundStyle(.secondary)
        .offset(x: MapGeometry.padX * z, y: 4 * z)
      Text("나중에 배울 것").font(font).foregroundStyle(.secondary)
        .frame(width: max(0, geo.size.width - MapGeometry.padX * z), alignment: .trailing)
        .offset(y: 4 * z)
      Path { p in
        let y = 28 * z, x0 = MapGeometry.padX * z, x1 = geo.size.width - MapGeometry.padX * z
        p.move(to: CGPoint(x: x0, y: y))
        p.addLine(to: CGPoint(x: x1, y: y))
        p.move(to: CGPoint(x: x1 - 6 * z, y: y - 4 * z))
        p.addLine(to: CGPoint(x: x1, y: y))
        p.addLine(to: CGPoint(x: x1 - 6 * z, y: y + 4 * z))
      }
      .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
      .allowsHitTesting(false)
    case .syllabus:
      ForEach(Array(layout.headers.enumerated()), id: \.offset) { i, h in
        let text = headerText(h)
        HStack(alignment: .firstTextBaseline, spacing: 5 * z) {
          if let code = text.code { Text(code).font(.system(size: 11.5 * z, weight: .medium, design: .monospaced)) }
          Text(text.title).font(.system(size: 11.5 * z, weight: .medium)).lineLimit(2)
        }
        .foregroundStyle(.secondary)
        .frame(width: MapGeometry.nodeWidth * z, alignment: .leading)
        .offset(x: geo.columnX(i), y: 10 * z)
      }
    }
  }

  private func headerText(_ h: ConceptMap.Layout.Header) -> (code: String?, title: String) {
    switch h {
    case .outside: return (nil, "다른 과목 · 아직 없음")
    case .item(let item):
      let found = syllabus?.item(item)
      return (found?.code ?? item.uppercased(), found?.title ?? "")
    case .unplaced(let proposed):
      guard syllabus != nil else { return (nil, proposed ?? "목차 밖") }
      return (nil, proposed.map { "목차 밖 · \($0)" } ?? "목차 밖")
    }
  }

  // 선수 개념의 오른쪽 가운데 → 개념의 왼쪽 가운데. 같은 칸(목차대로)이면 오른쪽으로 돌아 개념의 오른쪽 가운데로.
  private var edgeItems: [EdgeItem] {
    let w = geo.node.width, h = geo.node.height
    return map.edges.compactMap { e -> EdgeItem? in
      guard let a = layout.places[e.from], let b = layout.places[e.to] else { return nil }
      let o1 = geo.origin(a), o2 = geo.origin(b)
      let start = CGPoint(x: o1.x + w, y: o1.y + h / 2)
      let forward = b.column > a.column
      let end = forward ? CGPoint(x: o2.x - 1, y: o2.y + h / 2) : CGPoint(x: o2.x + w + 1, y: o2.y + h / 2)
      let bend = forward ? 0 : (22 * geo.z + min(16 * geo.z, abs(end.y - start.y) * 0.05))
      return EdgeItem(
        id: "\(e.from)→\(e.to)", start: start, end: end, bend: bend, role: highlight.role(e), dashed: map.node(e.from)?.kind == .missing)
    }
    .sorted { $0.role.rawValue < $1.role.rawValue }
  }

  private func color(_ role: MapHighlight.Role) -> Color {
    switch role {
    case .dimmed: Color.secondary.opacity(0.14)
    case .plain: Color.secondary.opacity(0.45)
    case .descendant: Color.purple
    case .ancestor, .selected: Color.accentColor
    }
  }
}

// 선수 개념에서 개념으로 가는 화살표. 자리가 바뀌면 끝점이 움직이며 따라간다.
struct EdgeShape: Shape {
  var start: CGPoint
  var end: CGPoint
  // 같은 칸이면 오른쪽으로 부푸는 정도, 아니면 0
  var bend: CGFloat
  var arrow: CGFloat

  var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
    get { AnimatablePair(AnimatablePair(start.x, start.y), AnimatablePair(end.x, end.y)) }
    set {
      start = CGPoint(x: newValue.first.first, y: newValue.first.second)
      end = CGPoint(x: newValue.second.first, y: newValue.second.second)
    }
  }

  func path(in rect: CGRect) -> Path {
    var p = Path()
    let c1: CGPoint, c2: CGPoint
    if bend > 0 {
      c1 = CGPoint(x: start.x + bend, y: start.y)
      c2 = CGPoint(x: end.x + bend, y: end.y)
    } else {
      let dx = max(18, (end.x - start.x) / 2)
      c1 = CGPoint(x: start.x + dx, y: start.y)
      c2 = CGPoint(x: end.x - dx, y: end.y)
    }
    p.move(to: start)
    p.addCurve(to: end, control1: c1, control2: c2)
    // 화살촉: 끝점의 접선 방향
    let angle = atan2(end.y - c2.y, end.x - c2.x)
    for turn in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
      p.move(to: end)
      p.addLine(to: CGPoint(x: end.x + arrow * cos(angle + turn), y: end.y + arrow * sin(angle + turn)))
    }
    return p
  }
}

struct MapNodeView: View {
  let node: ConceptMap.Node
  let fact: MapFacts.Fact
  let role: MapHighlight.Role
  let z: CGFloat

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8 * z, style: .continuous)
    VStack(alignment: .leading, spacing: 2 * z) {
      meta
      Text(node.title)
        .font(.system(size: 12.5 * z, weight: .medium))
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .foregroundStyle(node.kind == .missing ? .secondary : .primary)
    }
    .padding(.horizontal, 10 * z)
    .padding(.vertical, 6 * z)
    .frame(width: MapGeometry.nodeWidth * z, height: MapGeometry.nodeHeight * z, alignment: .topLeading)
    .background(tint, in: shape)
    .overlay {
      shape.strokeBorder(border, style: StrokeStyle(lineWidth: role == .selected ? 2.5 : 1, dash: node.kind == .missing ? [4, 3] : []))
    }
    .overlay(alignment: .topTrailing) {
      if fact.isNew {
        Text("새로")
          .font(.system(size: 10 * z, weight: .semibold))
          .padding(.horizontal, 6 * z)
          .padding(.vertical, 1)
          .foregroundStyle(.white)
          .background(Color.accentColor, in: Capsule())
          .offset(x: -8 * z, y: -8 * z)
      }
    }
    .opacity(role == .dimmed ? 0.4 : 1)
    // 흐려도 바탕은 가린다 (뒤로 지나가는 화살표가 비치지 않게)
    .background(node.kind == .missing ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .controlBackgroundColor), in: shape)
    .contentShape(shape)
    .help(helpText)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder private var meta: some View {
    HStack(spacing: 5 * z) {
      switch node.kind {
      case .concept:
        if let code = fact.code { Text(code).font(.system(size: 10.5 * z, design: .monospaced)) }
        if let ko = fact.titleKo { Text(ko) }
      case .other:
        Text(fact.subjectName ?? "").fontWeight(.semibold).foregroundStyle(Color.teal)
        if let ko = fact.titleKo { Text(ko) }
      case .missing:
        Text("아직 없는 개념")
      }
      Spacer(minLength: 0)
      if node.kind == .concept {
        if fact.hasPage {
          Circle().fill(Color.accentColor).frame(width: 7 * z, height: 7 * z)
        } else {
          Circle().strokeBorder(Color.orange, lineWidth: 1.5 * z).frame(width: 7 * z, height: 7 * z)
        }
      }
    }
    .font(.system(size: 10.5 * z))
    .foregroundStyle(.secondary)
    .lineLimit(1)
  }

  private var tint: Color {
    switch role {
    case .ancestor: Color.accentColor.opacity(0.12)
    case .descendant: Color.purple.opacity(0.12)
    default: .clear
    }
  }

  private var border: Color {
    switch role {
    case .selected, .ancestor: return Color.accentColor
    case .descendant: return Color.purple
    case .plain, .dimmed:
      switch node.kind {
      case .concept: return Color(nsColor: .separatorColor)
      case .other: return Color.teal
      case .missing: return Color.secondary
      }
    }
  }

  private var helpText: String {
    let ko = fact.titleKo.map { " (\($0))" } ?? ""
    switch node.kind {
    case .concept: return node.title + ko + (fact.hasPage ? "" : " · 페이지 만드는 중")
    case .other: return node.title + ko + " · \(fact.subjectName ?? "")"
    case .missing: return node.title + " · 아직 없는 개념"
    }
  }
}

// 모눈 점. 지도와 함께 움직인다
struct DotGrid: View {
  let z: CGFloat

  var body: some View {
    Canvas { ctx, size in
      let step = 20 * z
      guard step >= 6 else { return }
      var dots = Path()
      var y = step
      while y < size.height {
        var x = step
        while x < size.width {
          dots.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
          x += step
        }
        y += step
      }
      ctx.fill(dots, with: .color(.secondary.opacity(0.18)))
    }
  }
}

struct MapLegend: View {
  var body: some View {
    let box = RoundedRectangle(cornerRadius: 3, style: .continuous)
    HStack(spacing: 14) {
      item("학습 페이지 있음") {
        box.strokeBorder(Color(nsColor: .separatorColor)).frame(width: 18, height: 11)
          .overlay(alignment: .topTrailing) { Circle().fill(Color.accentColor).frame(width: 5, height: 5).padding(2) }
      }
      item("페이지 만드는 중") {
        box.strokeBorder(Color(nsColor: .separatorColor)).frame(width: 18, height: 11)
          .overlay(alignment: .topTrailing) { Circle().strokeBorder(Color.orange, lineWidth: 1.2).frame(width: 5, height: 5).padding(2) }
      }
      item("아직 없는 개념") { box.strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 18, height: 11) }
      item("다른 과목") { box.strokeBorder(Color.teal).frame(width: 18, height: 11) }
      item("먼저 알아야 할 것") { Capsule().fill(Color.accentColor).frame(width: 18, height: 2) }
      item("다음 개념") { Capsule().fill(Color.purple).frame(width: 18, height: 2) }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func item(_ label: String, @ViewBuilder mark: () -> some View) -> some View {
    HStack(spacing: 5) {
      mark()
      Text(label).lineLimit(1).fixedSize()
    }
  }
}

// 고른 개념: 이름과 상태, 바로 앞 선수 개념, 바로 다음 개념, 학습 페이지 열기
struct MapDetail: View {
  let map: ConceptMap
  let facts: MapFacts
  let highlight: MapHighlight
  let select: (String) -> Void
  let open: (String) -> Void

  var body: some View {
    Group {
      if let id = highlight.selected, let node = map.node(id) {
        HStack(alignment: .top, spacing: 22) {
          head(node).frame(minWidth: 170, maxWidth: 250, alignment: .leading)
          column("먼저 알아야 할 것", tint: .accentColor, ids: map.prerequisites(of: id), note: prerequisiteNote(node))
            .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
          column("다음 개념", tint: .purple, ids: map.next(of: id), note: nextNote(id))
            .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
          action(node).frame(minWidth: 130, alignment: .trailing)
        }
      } else {
        VStack(alignment: .leading, spacing: 4) {
          Text("개념을 고르면 먼저 알아야 할 것과 다음 개념이 여기에 보여요.")
          Text("개념을 두 번 누르면 학습 페이지가 열려요. 빈 곳을 누르면 고른 것이 풀려요.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .frame(minHeight: 116, alignment: .top)
    .background(.background.secondary)
  }

  private func head(_ node: ConceptMap.Node) -> some View {
    let fact = facts[node.id]
    return VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        if node.kind != .missing, let code = fact.code { Text(code).font(.caption.monospaced()).foregroundStyle(.secondary) }
        Text(stateText(node))
          .font(.caption.weight(.medium))
          .padding(.horizontal, 7)
          .padding(.vertical, 1)
          .foregroundStyle(stateColor(node))
          .background(stateColor(node).opacity(0.12), in: Capsule())
        if fact.isNew {
          Text("새로").font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1).foregroundStyle(.white)
            .background(Color.accentColor, in: Capsule())
        }
        if let note = fact.note { Text(note).font(.caption).foregroundStyle(.orange) }
      }
      Text(node.title).font(.title3.weight(.semibold)).lineLimit(2)
      if let ko = fact.titleKo { Text(ko).font(.callout).foregroundStyle(.secondary) }
      Text(node.id).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(2)
    }
  }

  private func column(_ title: String, tint: Color, ids: [String], note: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
      if !ids.isEmpty {
        FlowLayout(spacing: 5) {
          ForEach(ids, id: \.self) { id in
            Button { select(id) } label: { Text(map.node(id)?.title ?? id).lineLimit(1) }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .tint(map.node(id)?.kind == .missing ? .secondary : tint)
          }
        }
      }
      Text(note).font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
  }

  @ViewBuilder private func action(_ node: ConceptMap.Node) -> some View {
    let fact = facts[node.id]
    switch node.kind {
    case .missing:
      Text("이 내용의 자료를 넣고 정리하면 생겨요").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
    case .concept, .other:
      if fact.hasPage {
        Button(fact.subjectName.map { "\($0) 학습 페이지 열기" } ?? "학습 페이지 열기") { open(node.id) }
          .buttonStyle(.borderedProminent)
      } else {
        Button("페이지 만드는 중") {}.disabled(true)
      }
    }
  }

  private func stateText(_ node: ConceptMap.Node) -> String {
    switch node.kind {
    case .missing: "아직 없는 개념"
    case .other: "\(facts[node.id].subjectName ?? "") 개념"
    case .concept: facts[node.id].hasPage ? "학습 페이지 있음" : "페이지 만드는 중"
    }
  }

  private func stateColor(_ node: ConceptMap.Node) -> Color {
    switch node.kind {
    case .missing: .secondary
    case .other: .teal
    case .concept: facts[node.id].hasPage ? .accentColor : .orange
    }
  }

  private func prerequisiteNote(_ node: ConceptMap.Node) -> String {
    switch node.kind {
    case .missing: return "아직 없는 개념이라 선수 개념을 알 수 없어요"
    case .other: return "\(facts[node.id].subjectName ?? "그 과목") 지도에서 볼 수 있어요"
    case .concept:
      let direct = map.prerequisites(of: node.id)
      if direct.isEmpty { return "먼저 알아야 할 개념이 없어요" }
      return "거슬러 올라가면 \(highlight.ancestors.count)개 · 가장 먼 것까지 \(map.depth(of: node.id))단계"
    }
  }

  private func nextNote(_ id: String) -> String {
    map.next(of: id).isEmpty ? "아직 이 개념 다음에 오는 개념이 없어요" : "이어지면 \(highlight.descendants.count)개"
  }
}

// 줄을 넘기며 늘어놓는다 (칩)
struct FlowLayout: Layout {
  var spacing: CGFloat = 5

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
    for s in subviews {
      let size = s.sizeThatFits(.unspecified)
      let w = min(size.width, width)
      if x > 0 && x + w > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += w + spacing
      rowHeight = max(rowHeight, size.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: min(widest, width), height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
    for s in subviews {
      let size = s.sizeThatFits(.unspecified)
      let w = min(size.width, bounds.width)
      if x > bounds.minX && x + w > bounds.maxX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: size.height))
      x += w + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
