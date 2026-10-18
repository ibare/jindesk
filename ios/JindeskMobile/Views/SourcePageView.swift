// 원래 자료의 쪽 (MOBILE.md 의 원래 자료의 쪽). 출처 칩으로 연 쪽의 이미지를 보이고 앞뒤 쪽으로 넘긴다. 확대해 볼 수 있다.
// 받아 둔 것에 없는 쪽은 그때 자료 버킷에서 받는다.
import JindeskKit
import SwiftUI

struct SourcePageView: View {
  @Environment(MobileModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State var peek: MobileModel.SourcePeek
  @State private var image: UIImage?
  @State private var error: String?

  var body: some View {
    NavigationStack {
      VStack(spacing: 12) {
        Group {
          if let image {
            ZoomableImage(image: image)
          } else if let error {
            ContentUnavailableView("쪽을 열지 못했습니다", systemImage: "exclamationmark.triangle", description: Text(error))
          } else {
            Rectangle().fill(Color(.secondarySystemBackground)).aspectRatio(16 / 9, contentMode: .fit).overlay(ProgressView())
          }
        }
        .frame(maxHeight: .infinity)
        HStack {
          Button("앞 쪽", systemImage: "chevron.left") { peek.page -= 1 }
            .disabled(peek.page <= 1)
          Spacer()
          Text("\(peek.page)쪽 / \(peek.total)쪽").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
          Spacer()
          Button("다음 쪽", systemImage: "chevron.right") { peek.page += 1 }
            .disabled(peek.page >= peek.total)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .padding(.horizontal)
      }
      .padding(.vertical)
      .navigationTitle(peek.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } }
      }
      .task(id: peek.page) { await load() }
    }
  }

  private func load() async {
    image = nil
    error = nil
    do {
      let url = try await model.pageImages.image(peek.source, page: peek.page)
      image = UIImage(contentsOfFile: url.path)
      if image == nil { error = "이미지를 읽지 못했습니다" }
    } catch {
      self.error = error.localizedDescription
    }
  }
}
