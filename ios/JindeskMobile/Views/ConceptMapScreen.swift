// 과목 개념 지도 (MOBILE.md 의 과목 개념 지도, DECISIONS.md 29). 맥의 지도를 폰 폭에 맞춘 세로 흐름이다.
// 배우는 순서(먼저)는 선수 개념의 겹마다 위에서 아래로 단계를 두고, 목차대로는 목차 항목마다 묶는다. 한 묶음 안은 두 줄이다.
// 처음에는 선을 흐리게 다 그리고, 개념을 누르면 앞 길(파랑)과 뒤 길(보라)만 진하게 하고 아래 시트에 바로 앞·바로 다음을 보인다.
import JindeskKit
import SwiftUI

struct ConceptMapScreen: View {
  @Environment(MobileModel.self) private var model
  let subject: String
  @AppStorage("mapArrangement") private var arrangement = ConceptMap.Arrangement.learning.rawValue
  @AppStorage("mapShowOthers") private var showOthers = true

  // 고른 개념과 지도에서 연 학습 페이지는 모델에 있다 (돌려서 칸을 새로 만들어도 남는다)
  private var selected: String? { model.mapSelected }

  var body: some View {
    @Bindable var model = model
    let map = model.conceptMap(subject, showOthers: showOthers)
    let bands = Self.bands(map, arrangement: ConceptMap.Arrangement(rawValue: arrangement) ?? .learning, syllabus: model.syllabi[subject], model: model)
    let chain = selected.map { (anc: map.ancestors(of: $0), desc: map.descendants(of: $0)) }
    VStack(spacing: 0) {
      header(map)
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            ForEach(bands, id: \.title) { band in
              VStack(alignment: .leading, spacing: 6) {
                Text(band.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                  ForEach(band.ids, id: \.self) { id in
                    if let node = map.node(id) {
                      MapNodeView(node: node, info: model.nodeInfo(node), state: state(id, chain))
                        .id(id)
                        .anchorPreference(key: NodeFrames.self, value: .bounds) { [id: $0] }
                        .onTapGesture { if node.kind != .missing { model.mapSelected = id } }
                    }
                  }
                }
              }
            }
          }
          .padding(12)
          .padding(.bottom, selected == nil ? 12 : 300)
          .backgroundPreferenceValue(NodeFrames.self) { frames in
            GeometryReader { geo in
              EdgesView(map: map, rects: frames.mapValues { geo[$0] }, chain: chain, selected: selected)
            }
          }
          .contentShape(Rectangle())
          .onTapGesture { model.mapSelected = nil }
        }
        .background(DotGrid())
        .onChange(of: model.mapSelected) {
          guard let selected else { return }
          withAnimation { proxy.scrollTo(selected, anchor: UnitPoint(x: 0.5, y: 0.2)) }
        }
        // "개념 지도에서 보기"로 열었거나 칸을 새로 만들었으면 고른 개념으로 스크롤한다
        .onAppear {
          guard let selected else { return }
          DispatchQueue.main.async { proxy.scrollTo(selected, anchor: UnitPoint(x: 0.5, y: 0.2)) }
        }
      }
      .overlay(alignment: .bottom) {
        if let id = selected, let node = map.node(id) {
          MapSheet(map: map, node: node, info: model.nodeInfo(node), select: { model.mapSelected = $0 }, open: { model.mapPage = $0 })
            .transition(.move(edge: .bottom))
        }
      }
    }
    .navigationTitle("\(model.subjectName(subject)) 개념 지도")
    .navigationBarTitleDisplayMode(.inline)
    // 지도에서 연 학습 페이지도 오른쪽 칸의 페이지와 같은 보기를 다시 쓴다 (둘이 함께 보이는 일은 없다)
    .navigationDestination(item: $model.mapPage) { id in
      if let c = model.concept(id) {
        ConceptPage(
          concept: c,
          onOpenConcept: { model.mapPage = $0 },
          onOpenMap: { focus in
            model.mapPage = nil
            model.mapSelected = focus
          },
          kept: true)
      }
    }
    .animation(.easeOut(duration: 0.2), value: model.mapSelected)
  }

  private func header(_ map: ConceptMap) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("개념 \(map.conceptCount) · 선수 연결 \(map.linkCount) · 아직 없는 개념 \(map.missingCount)")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Picker("배치", selection: $arrangement) {
          Text("배우는 순서").tag(ConceptMap.Arrangement.learning.rawValue)
          Text("목차대로").tag(ConceptMap.Arrangement.syllabus.rawValue)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        Spacer()
        Toggle("다른 과목", isOn: $showOthers).toggleStyle(.button).controlSize(.small)
      }
      HStack(spacing: 12) {
        Legend(kind: .page)
        Legend(kind: .waiting)
        Legend(kind: .missing)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  private func state(_ id: String, _ chain: (anc: Set<String>, desc: Set<String>)?) -> MapNodeView.State {
    guard let chain, let selected else { return .plain }
    if id == selected { return .selected }
    if chain.anc.contains(id) { return .before }
    if chain.desc.contains(id) { return .after }
    return .dim
  }

  struct Band {
    let title: String
    let ids: [String]
  }

  // 맥과 같은 배치에서 칸(column)을 위에서 아래 묶음으로, 칸 안의 높이(row) 차례를 묶음 안의 차례로 쓴다
  static func bands(_ map: ConceptMap, arrangement: ConceptMap.Arrangement, syllabus: Syllabus?, model: MobileModel) -> [Band] {
    let layout = map.layout(arrangement, syllabus: syllabus)
    var byColumn: [Int: [(String, Double)]] = [:]
    for (id, place) in layout.places { byColumn[place.column, default: []].append((id, place.row)) }
    return (0..<layout.columns).compactMap { column in
      guard let items = byColumn[column], !items.isEmpty else { return nil }
      let ids = items.sorted { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }.map(\.0)
      let title: String
      if arrangement == .syllabus, column < layout.headers.count {
        switch layout.headers[column] {
        case .outside: title = "다른 과목 · 아직 없는 개념"
        case .item(let item):
          let code = item.uppercased()
          let name = syllabus?.flat.first { ItemPath.dir($0.item.code) == ItemPath.dir(item) }?.item.title
          title = name.map { "\(code)  \($0)" } ?? code
        case .unplaced(let name): title = "목차 밖" + (name.map { " · \($0)" } ?? "")
        }
      } else {
        title = "\(column + 1)단계" + (column == 0 ? " · 먼저 배울 것" : "")
      }
      return Band(title: title, ids: ids)
    }
  }
}

struct NodeFrames: PreferenceKey {
  static let defaultValue: [String: Anchor<CGRect>] = [:]
  static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
    value.merge(nextValue()) { $1 }
  }
}

// 노드: 맥의 지도와 같은 표시 (목차 코드, 한국어 이름, 영어 이름, 페이지 점, 아직 없는 개념은 점선, 다른 과목은 청록, 새로)
struct MapNodeView: View {
  enum State { case plain, selected, before, after, dim }
  let node: ConceptMap.Node
  let info: MobileModel.NodeInfo
  let state: State

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 4) {
        if let subject = info.subject { Text(subject).fontWeight(.bold).foregroundStyle(Color.teal) }
        if let code = info.code { Text(code).monospaced() }
        Text(node.kind == .missing ? "아직 없는 개념" : (info.ko ?? "")).lineLimit(1)
      }
      .font(.system(size: 10))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      Text(node.title)
        .font(.system(size: 12, weight: node.kind == .missing ? .regular : .medium))
        .foregroundStyle(node.kind == .missing ? .secondary : .primary)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.leading, 8)
    .padding(.trailing, 18)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
    .background(background, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border, style: StrokeStyle(lineWidth: state == .selected ? 2 : (state == .before || state == .after ? 1.5 : 1), dash: node.kind == .missing ? [4, 3] : [])))
    .overlay(alignment: .topTrailing) {
      if node.kind == .concept {
        Circle()
          .strokeBorder(info.hasPage ? Color.accentColor : Color.orange, lineWidth: 1.4)
          .background(Circle().fill(info.hasPage ? Color.accentColor : Color.clear))
          .frame(width: 7, height: 7)
          .padding(8)
      }
    }
    .overlay(alignment: .topTrailing) {
      if info.isNew {
        Text("새로").font(.system(size: 9)).padding(.horizontal, 5).background(Color.accentColor.opacity(0.15), in: Capsule())
          .foregroundStyle(Color.accentColor).offset(x: -6, y: -7)
      }
    }
    .opacity(state == .dim ? 0.3 : 1)
    .contentShape(Rectangle())
  }

  private var background: Color {
    switch state {
    case .selected: Color.accentColor.opacity(0.14)
    default: node.kind == .missing ? Color(.secondarySystemBackground) : Color(.systemBackground)
    }
  }

  private var border: Color {
    switch state {
    case .selected, .before: Color.accentColor
    case .after: Color.purple
    default:
      if case .other = node.kind { Color.teal } else { Color(.separator) }
    }
  }
}

// 선: 선수 개념의 아래 가운데에서 다음 개념의 위 가운데로. 같은 줄이면 옆으로 잇는다.
struct EdgesView: View {
  let map: ConceptMap
  let rects: [String: CGRect]
  let chain: (anc: Set<String>, desc: Set<String>)?
  let selected: String?

  var body: some View {
    Canvas { context, _ in
      for edge in map.edges {
        guard let a = rects[edge.from], let c = rects[edge.to] else { continue }
        var color = Color.secondary.opacity(0.35)
        var width: CGFloat = 1.1
        if let chain, let selected {
          if (edge.to == selected || chain.anc.contains(edge.to)) && chain.anc.contains(edge.from) {
            color = .accentColor
            width = 1.8
          } else if (edge.from == selected || chain.desc.contains(edge.from)) && chain.desc.contains(edge.to) {
            color = .purple
            width = 1.8
          } else {
            continue
          }
        }
        let (path, end, direction) = Self.path(from: a, to: c)
        context.stroke(path, with: .color(color), lineWidth: width)
        context.fill(Self.arrow(at: end, direction: direction), with: .color(color))
      }
    }
    .allowsHitTesting(false)
  }

  static func path(from a: CGRect, to c: CGRect) -> (Path, CGPoint, CGVector) {
    var p = Path()
    if c.minY >= a.maxY - 2 {
      let s = CGPoint(x: a.midX, y: a.maxY), e = CGPoint(x: c.midX, y: c.minY)
      let dy = max(14, (e.y - s.y) / 2)
      p.move(to: s)
      p.addCurve(to: e, control1: CGPoint(x: s.x, y: s.y + dy), control2: CGPoint(x: e.x, y: e.y - dy))
      return (p, e, CGVector(dx: 0, dy: 1))
    }
    if c.maxY <= a.minY + 2 {
      let s = CGPoint(x: a.midX, y: a.minY), e = CGPoint(x: c.midX, y: c.maxY)
      p.move(to: s)
      p.addCurve(to: e, control1: CGPoint(x: s.x, y: s.y - 18), control2: CGPoint(x: e.x, y: e.y + 18))
      return (p, e, CGVector(dx: 0, dy: -1))
    }
    let right = c.minX >= a.maxX - 2
    let s = CGPoint(x: right ? a.maxX : a.minX, y: a.midY), e = CGPoint(x: right ? c.minX : c.maxX, y: c.midY)
    p.move(to: s)
    p.addCurve(to: e, control1: CGPoint(x: s.x + (right ? 6 : -6), y: s.y), control2: CGPoint(x: e.x + (right ? -6 : 6), y: e.y))
    return (p, e, CGVector(dx: right ? 1 : -1, dy: 0))
  }

  static func arrow(at tip: CGPoint, direction d: CGVector) -> Path {
    let size: CGFloat = 5
    let back = CGPoint(x: tip.x - d.dx * size, y: tip.y - d.dy * size)
    let side = CGVector(dx: -d.dy * size * 0.6, dy: d.dx * size * 0.6)
    var p = Path()
    p.move(to: tip)
    p.addLine(to: CGPoint(x: back.x + side.dx, y: back.y + side.dy))
    p.addLine(to: CGPoint(x: back.x - side.dx, y: back.y - side.dy))
    p.closeSubpath()
    return p
  }
}

// 고른 개념: 목차 코드와 이름, 페이지 상태, 바로 앞·바로 다음, 거슬러 올라가는 수와 이어지는 수, 학습 페이지 열기
struct MapSheet: View {
  let map: ConceptMap
  let node: ConceptMap.Node
  let info: MobileModel.NodeInfo
  let select: (String) -> Void
  let open: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Capsule().fill(Color(.separator)).frame(width: 36, height: 4).frame(maxWidth: .infinity)
      HStack(spacing: 6) {
        if let subject = info.subject { Text(subject) }
        if let code = info.code { Text(code).monospaced() }
        if node.kind == .concept {
          Text(info.hasPage ? "학습 페이지 있음" : "페이지 만드는 중")
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((info.hasPage ? Color.accentColor : Color.orange).opacity(0.15), in: Capsule())
            .foregroundStyle(info.hasPage ? Color.accentColor : Color.orange)
        }
        if info.isNew { Text("새로").foregroundStyle(Color.accentColor) }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      Text(node.title).font(.headline)
      if let ko = info.ko { Text(ko).font(.subheadline).foregroundStyle(.secondary) }
      chips("먼저 알아야 할 것", color: .accentColor, ids: map.prerequisites(of: node.id))
      chips("이어서 배울 것", color: .purple, ids: map.next(of: node.id))
      Text("거슬러 올라가면 \(map.ancestors(of: node.id).count)개 · 이어지면 \(map.descendants(of: node.id).count)개")
        .font(.caption2).foregroundStyle(.secondary)
      Button {
        open(node.id)
      } label: {
        Text("학습 페이지 열기").fontWeight(.semibold).frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!info.hasPage)
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .padding(.bottom, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
    .shadow(color: .black.opacity(0.12), radius: 12, y: -4)
  }

  private func chips(_ caption: String, color: Color, ids: [String]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(color)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          if ids.isEmpty { Text("없음").font(.caption).foregroundStyle(.secondary) }
          ForEach(ids, id: \.self) { id in
            let n = map.node(id)
            Button(n?.title ?? id) { select(id) }
              .font(.caption)
              .buttonStyle(.bordered)
              .controlSize(.small)
              .disabled(n?.kind == .missing)
          }
        }
      }
    }
  }
}

struct Legend: View {
  enum Kind { case page, waiting, missing }
  let kind: Kind

  var body: some View {
    HStack(spacing: 4) {
      switch kind {
      case .page: Circle().fill(Color.accentColor).frame(width: 7, height: 7)
      case .waiting: Circle().strokeBorder(Color.orange, lineWidth: 1.4).frame(width: 7, height: 7)
      case .missing: RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 12, height: 8)
      }
      Text(kind == .page ? "학습 페이지 있음" : kind == .waiting ? "만드는 중" : "아직 없는 개념")
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }
}

// 지도 바탕의 점 무늬 (맥과 같다)
struct DotGrid: View {
  var body: some View {
    Canvas { context, size in
      let step: CGFloat = 14
      var y: CGFloat = 0
      while y < size.height {
        var x: CGFloat = 0
        while x < size.width {
          context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(Color(.separator).opacity(0.5)))
          x += step
        }
        y += step
      }
    }
    .background(Color(.secondarySystemBackground))
    .ignoresSafeArea()
  }
}
