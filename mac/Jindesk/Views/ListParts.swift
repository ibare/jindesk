import AppKit
import JindeskKit
import SwiftUI

// 목록 칸이 함께 쓰는 부품 (DECISIONS.md 32)

extension Color {
  // 앱 아이콘의 리본 색. 7일 안에 정리된 개념의 점, 멈춘 일
  static let ribbon = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.886, green: 0.333, blue: 0.247, alpha: 1) : NSColor(srgbRed: 0.776, green: 0.231, blue: 0.153, alpha: 1)
    })
}

// 개념 이름 두 줄: 영어 이름의 콜론 앞, 한국어 이름의 콜론 앞
struct ConceptNames: View {
  let title: String
  let titleKo: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(TitleParts(title).head).font(.system(size: 13, weight: .semibold)).lineLimit(1)
      if let titleKo { Text(TitleParts(titleKo).head).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
    }
  }
}

// 개념 줄 오른쪽의 상태: 페이지·한국어, 메모 수, 7일 안에 정리됨
struct RowBadges: View {
  var note: String?
  var comments = 0
  var isNew = false
  var selected = false

  var body: some View {
    HStack(spacing: 7) {
      if let note {
        Text(note).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
          .padding(.horizontal, 6).padding(.vertical, 1)
          .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
      }
      if comments > 0 {
        HStack(spacing: 2) {
          Image(systemName: "pencil").font(.system(size: 10, weight: .medium))
          Text("\(comments)").font(.system(size: 11)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .help("메모 \(comments)")
      }
      if isNew {
        Circle().fill(Color.ribbon).frame(width: 6, height: 6)
          .overlay(Circle().stroke(Color.white, lineWidth: selected ? 1.5 : 0))
          .help("7일 안에 정리됨")
      }
    }
    .fixedSize()
  }
}

// 묶음의 머리 글 (단원, 할 일, 넣은 자료)
struct ListLabel: View {
  let text: String
  var trailing: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
      Spacer(minLength: 6)
      if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit() }
    }
  }
}

// 자료 한 장을 뜻하는 작은 그림 (글줄이 있는 쪽)
struct SourceThumb: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      ForEach([1.0, 0.8, 1.0, 0.6], id: \.self) { w in
        Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 18 * w, height: 2)
      }
    }
    .frame(width: 30, height: 36, alignment: .center)
    .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.2)))
    .accessibilityHidden(true)
  }
}

// 개념 지도 카드의 작은 그림: 선수 개념으로 이은 점 넷
struct MapGlyph: View {
  var body: some View {
    Canvas { ctx, size in
      let s = min(size.width / 28, size.height / 32)
      let p = [CGPoint(x: 14, y: 4), CGPoint(x: 14, y: 12), CGPoint(x: 8, y: 21), CGPoint(x: 20, y: 28)].map { CGPoint(x: $0.x * s, y: $0.y * s) }
      var lines = Path()
      for (a, b) in [(0, 1), (1, 2), (1, 3), (2, 3)] {
        lines.move(to: p[a])
        lines.addLine(to: p[b])
      }
      ctx.opacity = 0.65
      ctx.stroke(lines, with: .foreground, style: StrokeStyle(lineWidth: 1.2))
      ctx.opacity = 1
      for q in p { ctx.fill(Path(ellipseIn: CGRect(x: q.x - 2.6 * s, y: q.y - 2.6 * s, width: 5.2 * s, height: 5.2 * s)), with: .foreground) }
    }
    .frame(width: 28, height: 32)
    .accessibilityHidden(true)
  }
}

// 카드 바탕 (오늘의 할 일과 넣은 자료)
struct CardBackground: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
  }
}

extension View {
  func card() -> some View { modifier(CardBackground()) }
}

// 고른 줄의 바탕: 고르면 강조색, 마우스를 올리면 옅게
struct RowHighlight: ViewModifier {
  let selected: Bool
  @State private var hovering = false

  func body(content: Content) -> some View {
    content
      .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
      .background(
        RoundedRectangle(cornerRadius: 7).fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.05 : 0))))
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
  }
}

extension View {
  func rowHighlight(_ selected: Bool) -> some View { modifier(RowHighlight(selected: selected)) }
}

// 빈 목록
struct EmptyList: View {
  let icon: String
  let title: String
  let detail: String

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
      Text(title).font(.system(size: 13.5, weight: .semibold))
      Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 32)
    .padding(.top, 56)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}
