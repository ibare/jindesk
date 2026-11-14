import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import JindeskKit

// 그림 이미지 복사 (PAGES.md 의 그림 이미지 복사): 웹 보기가 만든 PDF 를 PNG 로 바꾼다
@Suite struct FigureImageTests {
  // 쪽마다 한 색으로 칠한 PDF
  static func pdf(_ pages: [(CGSize, CGColor)]) -> Data {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: pages[0].0)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    for (size, color) in pages {
      var page = CGRect(origin: .zero, size: size)
      context.beginPage(mediaBox: &page)
      context.setFillColor(color)
      context.fill(page)
      context.endPage()
    }
    context.closePDF()
    return data as Data
  }

  // 위에서부터 센 픽셀 (x, y) 의 RGB
  static func pixel(_ png: Data, _ x: Int, _ y: Int) -> [UInt8] {
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
      data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return Array(bytes[0..<3])
  }

  static func size(_ png: Data) -> (Int, Int) {
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
    return (image.width, image.height)
  }

  @Test func 화면_배율의_픽셀로_그린다() throws {
    let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    let png = try #require(FigureImage.png(pdf: Self.pdf([(CGSize(width: 120, height: 40), red)]), scale: 2))
    #expect(Self.size(png) == (240, 80))
    #expect(Self.pixel(png, 10, 10) == [255, 0, 0])
  }

  @Test func 여러_쪽이면_첫_쪽을_위로_이어_붙인다() throws {
    let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    let png = try #require(FigureImage.png(pdf: Self.pdf([(CGSize(width: 100, height: 50), red), (CGSize(width: 80, height: 30), blue)]), scale: 1))
    #expect(Self.size(png) == (100, 80))
    #expect(Self.pixel(png, 5, 5) == [255, 0, 0])
    #expect(Self.pixel(png, 5, 70) == [0, 0, 255])
  }

  @Test func PDF_가_아니면_만들지_않는다() {
    #expect(FigureImage.png(pdf: Data("not a pdf".utf8), scale: 2) == nil)
  }
}
