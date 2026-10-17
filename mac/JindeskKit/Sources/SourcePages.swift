// 쪽 이미지는 캐시에 있다. 캐시를 지웠으면 원본(또는 바꾼 PDF)에서 다시 그린다.
import Foundation
import PDFKit

public enum SourcePages {
  public static func image(_ folder: SourceFolder, page: Int, folders: AppFolders) throws -> URL {
    let url = folders.pageImages(folder.id).appending(path: SourceFolder.pageName(page) + ".png")
    if FileOps.exists(url) { return url }
    guard let document = folder.renderable else { throw ToolError("\(folder.id) 의 원본이 없습니다") }
    if document.pathExtension.lowercased() == "pdf" {
      guard let pdf = PDFDocument(url: document), let p = pdf.page(at: page - 1), let image = PageRenderer.render(p, maxSide: PageExtractor.maxSide) else {
        throw ToolError("\(folder.id) 의 \(page)쪽을 그리지 못했습니다")
      }
      try PageRenderer.writePNG(image, to: url)
    } else {
      guard page == 1, let image = PageRenderer.render(imageAt: document, maxSide: PageExtractor.maxSide) else {
        throw ToolError("\(folder.id) 의 \(page)쪽을 그리지 못했습니다")
      }
      try PageRenderer.writePNG(image, to: url)
    }
    return url
  }

  public static func text(_ folder: SourceFolder, page: Int) -> String {
    FileOps.readIfExists(folder.pageText(page))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}
