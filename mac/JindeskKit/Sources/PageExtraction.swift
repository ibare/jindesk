// 쪽 나누기 (JOBS.md 의 자료 넣기). 쪽마다 글자층을 뽑고 쪽 이미지를 그린다.
// - 글자층은 PDFKit 으로 뽑는다. 글자층이 짧은 쪽은 Vision 글자 인식도 돌려 더 긴 쪽을 쓴다.
// - 글자층은 검색과 출처 대조에 쓴다. 수식과 그림 속 글자는 깨지므로 뜻은 에이전트가 쪽 이미지로 읽는다 (DECISIONS.md 22).
// - 앞 쪽의 글자를 모두 담고 더해 가는 쪽이 이어지면 묶는다 (슬라이드 애니메이션을 단계마다 내보낸 PDF).
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

public struct PageText: Sendable, Equatable {
  public let page: Int
  public let text: String
  // pdfkit, vision, none
  public let by: String
}

public struct ExtractedPages: Sendable, Equatable {
  public let texts: [PageText]
  public let buildUps: [[Int]]
  public var count: Int { texts.count }
}

public enum PageExtractor {
  // 글자층이 이보다 짧은 쪽은 Vision 글자 인식도 돌린다
  public static let ocrBelow = 200
  // 쪽 이미지의 긴 변 (픽셀)
  public static let maxSide: CGFloat = 1600

  public struct Failure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
  }

  // PDF 또는 사진(JPEG, PNG)의 쪽마다 글자층을 뽑고, 쪽 이미지를 imagesDir/0001.png … 로 쓴다.
  public static func extract(
    document: URL, imagesDir: URL, ocrBelow: Int = ocrBelow, progress: @Sendable (Int, Int) async -> Void = { _, _ in }
  ) async throws -> ExtractedPages {
    try FileOps.makeDirectory(imagesDir)
    if document.pathExtension.lowercased() == "pdf" {
      guard let pdf = PDFDocument(url: document) else { throw Failure(message: "PDF 를 열지 못했습니다: \(document.lastPathComponent)") }
      if pdf.isLocked { throw Failure(message: "암호가 걸린 PDF 입니다: \(document.lastPathComponent)") }
      var texts: [PageText] = []
      // 이어 채운 쪽은 PDF 글자층으로 찾는다. Vision 글자는 그림 속 글자까지 읽어 쪽마다 달라지기 때문이다.
      var layers: [String] = []
      for i in 0..<pdf.pageCount {
        try Task.checkCancellation()
        guard let page = pdf.page(at: i) else { continue }
        let n = i + 1
        let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        layers.append(layer)
        guard let image = PageRenderer.render(page, maxSide: maxSide) else { throw Failure(message: "\(n)쪽을 그리지 못했습니다") }
        try PageRenderer.writePNG(image, to: imagesDir.appending(path: SourceFolder.pageName(n) + ".png"))
        var text = PageText(page: n, text: layer, by: layer.isEmpty ? "none" : "pdfkit")
        if layer.count < ocrBelow, let recognized = try? TextRecognizer.recognize(image), recognized.count > layer.count {
          text = PageText(page: n, text: recognized, by: "vision")
        }
        texts.append(text)
        await progress(n, pdf.pageCount)
      }
      return ExtractedPages(texts: texts, buildUps: BuildUps.runs(layers))
    }
    // 사진은 한 쪽이다. 글자층은 Vision 으로만 만든다.
    guard let image = PageRenderer.render(imageAt: document, maxSide: maxSide) else {
      throw Failure(message: "이미지를 열지 못했습니다: \(document.lastPathComponent)")
    }
    try PageRenderer.writePNG(image, to: imagesDir.appending(path: SourceFolder.pageName(1) + ".png"))
    let recognized = (try? TextRecognizer.recognize(image)) ?? ""
    await progress(1, 1)
    return ExtractedPages(texts: [PageText(page: 1, text: recognized, by: recognized.isEmpty ? "none" : "vision")], buildUps: [])
  }
}

public enum PageRenderer {
  // PDF 쪽을 긴 변 maxSide 로 그린다. 쪽의 회전을 따른다. 바탕은 흰색이다.
  public static func render(_ page: PDFPage, maxSide: CGFloat) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    let size = page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
    guard size.width > 0, size.height > 0 else { return nil }
    let scale = maxSide / max(size.width, size.height)
    let width = Int((size.width * scale).rounded())
    let height = Int((size.height * scale).rounded())
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: scale, y: scale)
    ctx.concatenate(page.transform(for: .mediaBox))
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
  }

  // 사진을 긴 변 maxSide 이하로 줄인다. EXIF 의 방향을 따른다.
  public static func render(imageAt url: URL, maxSide: CGFloat) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: Int(maxSide),
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  public static func writePNG(_ image: CGImage, to url: URL) throws {
    try write(image, to: url, type: .png)
  }

  public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
    try write(image, to: url, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
  }

  static func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) throws {
    try FileOps.makeDirectory(url.deletingLastPathComponent())
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
      throw PageExtractor.Failure(message: "이미지 파일을 만들지 못했습니다: \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw PageExtractor.Failure(message: "이미지 파일을 쓰지 못했습니다: \(url.lastPathComponent)") }
  }
}

// Vision 글자 인식 (영어와 한국어)
public enum TextRecognizer {
  public static func recognize(_ image: CGImage) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US", "ko-KR"]
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: image).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// 앞 쪽의 낱말을 모두 담고 더해 가는 쪽들의 묶음. 그런 쪽이 없으면 빈 목록이다.
// 더한 낱말은 끝이 아니라 가운데에 끼어들 수도 있다 (빈칸에 답이 채워지는 슬라이드).
public enum BuildUps {
  // 이보다 낱말이 적은 쪽(제목만 있는 쪽 등)은 묶지 않는다
  static let minimumWords = 6

  public static func runs(_ texts: [String]) -> [[Int]] {
    let words = texts.map { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
    var runs: [[Int]] = []
    var current: [Int] = []
    for i in words.indices.dropFirst() {
      let a = words[i - 1]
      let b = words[i]
      // 같은 제목으로 시작하고(앞 세 낱말), 앞 쪽의 낱말이 순서대로 모두 들어 있다
      let linked = a.count >= minimumWords && b.count >= a.count && Array(a.prefix(3)) == Array(b.prefix(3)) && isSubsequence(a, of: b)
      if linked {
        if current.isEmpty { current = [i] }
        current.append(i + 1)
      } else {
        if current.count > 1 { runs.append(current) }
        current = []
      }
    }
    if current.count > 1 { runs.append(current) }
    return runs
  }

  static func isSubsequence(_ a: [String], of b: [String]) -> Bool {
    var j = b.startIndex
    for word in a {
      guard let found = b[j...].firstIndex(of: word) else { return false }
      j = b.index(after: found)
    }
    return true
  }
}
