// 그림 이미지 복사 (PAGES.md 의 그림 이미지 복사): 웹 보기가 그림 블록 자리로 만든 PDF 를 PNG 로 바꾼다.
// 화면 찍기(takeSnapshot)는 화면에 보이는 곳만 그려 화면보다 긴 블록의 아래가 비므로, 화면 밖까지 그리는 PDF 를 거친다. 맥과 폰이 함께 쓴다.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FigureImage {
  // PDF 의 쪽들을 위에서 아래로 이어 scale 배 픽셀의 PNG 하나로 만든다
  public static func png(pdf: Data, scale: CGFloat) -> Data? {
    guard let provider = CGDataProvider(data: pdf as CFData), let doc = CGPDFDocument(provider), doc.numberOfPages > 0 else { return nil }
    let pages = (1...doc.numberOfPages).compactMap { doc.page(at: $0) }
    let boxes = pages.map { $0.getBoxRect(.mediaBox) }
    let width = Int(((boxes.map(\.width).max() ?? 0) * scale).rounded())
    let height = Int((boxes.map(\.height).reduce(0, +) * scale).rounded())
    guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // CoreGraphics 는 아래가 원점이다. 첫 쪽이 맨 위에 오게 아래에서부터 거꾸로 쌓는다
    var y = CGFloat(height)
    for (page, box) in zip(pages, boxes) {
      y -= box.height * scale
      context.saveGState()
      context.translateBy(x: 0, y: y)
      context.scaleBy(x: scale, y: scale)
      context.translateBy(x: -box.minX, y: -box.minY)
      context.drawPDFPage(page)
      context.restoreGState()
    }
    guard let image = context.makeImage() else { return nil }
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? out as Data : nil
  }
}
