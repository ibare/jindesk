import AppKit
import JindeskKit
import SwiftUI

// 자료와 나란히 (PAGES.md 의 학습 페이지의 도움, DECISIONS.md 34): 지금 읽는 단위의 근거 쪽을 학습 페이지 옆에 보인다.
// 근거는 학습 페이지 단위의 주장 출처이고, 없으면 그 단위가 온 원문 단위의 주장 출처다. 보충한 글이나 확인 문제에는 근거 쪽이 없다.
struct SourceSidePane: View {
  @Environment(AppModel.self) private var model
  let concept: Concept
  // 렌더러가 알린 단위 (아직 없으면 근거가 있는 첫 단위)
  let unit: String?
  @State private var shown: SourcePeek?
  @State private var image: NSImage?

  struct Ref {
    let text: String
    let src: [String]
  }

  var body: some View {
    let refs = Self.refs(model, concept, unit)
    let cited = UnitDigest.pages(refs.flatMap(\.src))
    let current = shown ?? cited.first.flatMap { g in g.pages.first.map { SourcePeek(source: g.source, page: $0) } }
    VStack(alignment: .leading, spacing: 14) {
      if let current, let source = model.library.source(current.source) {
        HStack(alignment: .center, spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(SourceRow.title(source)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text("\(current.page)쪽 / \(source.meta.pages)쪽").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
          }
          Spacer(minLength: 0)
          Button("앞 쪽", systemImage: "chevron.left") { shown = SourcePeek(source: current.source, page: current.page - 1) }
            .disabled(current.page <= 1)
          Button("다음 쪽", systemImage: "chevron.right") { shown = SourcePeek(source: current.source, page: current.page + 1) }
            .disabled(current.page >= source.meta.pages)
          Button("크게 보기", systemImage: "arrow.up.left.and.arrow.down.right") { model.peek = current }
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        Group {
          if let image {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
          } else {
            Rectangle().fill(Color.secondary.opacity(0.08)).aspectRatio(16 / 9, contentMode: .fit).overlay(ProgressView().controlSize(.small))
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        .task(id: current.id) {
          image = nil
          guard let url = await model.pageImage(source, page: current.page) else { return }
          image = NSImage(contentsOf: url)
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("이 문단의 근거 쪽").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
          FlowLayout(spacing: 6) {
            ForEach(cited, id: \.source) { g in
              ForEach(g.pages, id: \.self) { p in
                let on = current.source == g.source && current.page == p
                Button("\(p)") { shown = SourcePeek(source: g.source, page: p) }
                  .buttonStyle(.plain)
                  .font(.system(size: 12, weight: on ? .semibold : .regular).monospacedDigit())
                  .foregroundStyle(on ? Color.white : Color.secondary)
                  .padding(.horizontal, 9)
                  .frame(height: 22)
                  .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor : Color.clear))
                  .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Color.clear : Color.primary.opacity(0.22)))
              }
            }
          }
          ForEach(Array(refs.enumerated()), id: \.offset) { _, r in
            let pages = UnitDigest.pages(r.src).flatMap(\.pages).map(String.init).joined(separator: ", ")
            Text("\(TexText.display(r.text)) ← \(pages)쪽").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
        }
      } else {
        ContentUnavailableView(
          "근거 쪽이 없는 단위예요", systemImage: "doc.text.magnifyingglass", description: Text("보충한 글이나 확인 문제에는 원래 자료의 쪽이 없습니다. 문단으로 내려가면 그 근거 쪽이 나옵니다."))
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.background)
    .onChange(of: unit) { shown = nil }
  }

  // 단위의 근거 주장. unit 이 없으면 근거가 있는 첫 단위
  static func refs(_ model: AppModel, _ concept: Concept, _ unit: String?) -> [Ref] {
    guard let data = model.data, let page = Page.load(ConceptFolder(concept.cid, in: data)) else { return [] }
    func of(_ u: PageUnit) -> [Ref] {
      if !u.claims.isEmpty { return u.claims.map { Ref(text: $0.text, src: $0.src) } }
      let origin = u.from.split(separator: "@").first.map(String.init)
      return (concept.units.first { $0.id == origin }?.claims ?? []).map { Ref(text: $0.text, src: $0.src) }
    }
    if let unit, let u = page.units.first(where: { $0.id == unit }) { return of(u) }
    return page.units.lazy.map(of).first { !$0.isEmpty } ?? []
  }
}
