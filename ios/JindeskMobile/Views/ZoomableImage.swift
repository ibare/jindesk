// 쪽 이미지를 확대해 본다 (DECISIONS.md 31): 두 손가락으로 벌려 4배까지, 두 번 눌러 2배와 맞춤을 오간다.
// 사진 앱처럼 UIScrollView 의 확대를 쓴다. 이미지가 바뀌면 맞춤(1배)으로 돌아간다.
import SwiftUI
import UIKit

struct ZoomableImage: UIViewRepresentable {
  let image: UIImage

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> UIScrollView {
    let scroll = UIScrollView()
    scroll.minimumZoomScale = 1
    scroll.maximumZoomScale = 4
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    scroll.bouncesZoom = true
    scroll.delegate = context.coordinator
    let view = UIImageView(image: image)
    view.contentMode = .scaleAspectFit
    view.frame = scroll.bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    scroll.addSubview(view)
    context.coordinator.imageView = view
    let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
    doubleTap.numberOfTapsRequired = 2
    scroll.addGestureRecognizer(doubleTap)
    #if DEBUG
      // 화면 확인: 확대한 채로 연다 (-pageZoom 2)
      let start = UserDefaults.standard.double(forKey: "pageZoom")
      if start > 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { scroll.setZoomScale(start, animated: false) } }
    #endif
    return scroll
  }

  func updateUIView(_ scroll: UIScrollView, context: Context) {
    guard let view = context.coordinator.imageView, view.image !== image else { return }
    scroll.setZoomScale(1, animated: false)
    view.image = image
  }

  @MainActor
  final class Coordinator: NSObject, UIScrollViewDelegate {
    weak var imageView: UIImageView?

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
      guard let scroll = gesture.view as? UIScrollView else { return }
      if scroll.zoomScale > 1 {
        scroll.setZoomScale(1, animated: true)
      } else {
        let point = gesture.location(in: imageView)
        let size = CGSize(width: scroll.bounds.width / 2, height: scroll.bounds.height / 2)
        scroll.zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
      }
    }
  }
}
