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

  // 맥과 폰이 보는 쪽 이미지의 긴 변 (DECISIONS.md 31)
  public static let viewSide: CGFloat = 2000

  public static func viewImage(_ folder: SourceFolder, page: Int, folders: AppFolders) -> URL {
    folders.viewImages(folder.id).appending(path: SourceFolder.pageName(page) + ".heic")
  }

  // 보기용 쪽 이미지(HEIC, 긴 변 2000)를 없는 쪽만 그린다. 원본(또는 바꾼 PDF)이 로컬에 있어야 한다.
  // PDF 는 한 번만 열고, 쓰다 꺼져도 반쪽 파일이 남지 않게 임시 파일에 쓰고 이름을 바꾼다.
  // only 를 주면 그 쪽만 그린다 (쪽 보기)
  public static func makeViewImages(_ folder: SourceFolder, pages: Int, folders: AppFolders, only: Int? = nil) throws {
    let missing = (only.map { [$0] } ?? Array(1...max(pages, 1))).filter { !FileOps.exists(viewImage(folder, page: $0, folders: folders)) }
    guard !missing.isEmpty else { return }
    guard let document = folder.renderable else { throw ToolError("\(folder.id) 의 원본이 없습니다") }
    let pdf = document.pathExtension.lowercased() == "pdf" ? PDFDocument(url: document) : nil
    for n in missing {
      try Task.checkCancellation()
      let image: CGImage?
      if let pdf {
        image = pdf.page(at: n - 1).flatMap { PageRenderer.render($0, maxSide: viewSide) }
      } else {
        image = n == 1 ? PageRenderer.render(imageAt: document, maxSide: viewSide) : nil
      }
      guard let image else { throw ToolError("\(folder.id) 의 \(n)쪽을 그리지 못했습니다") }
      let target = viewImage(folder, page: n, folders: folders)
      let temp = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).tmp")
      try PageRenderer.writeHEIC(image, to: temp)
      FileOps.remove(target)
      try FileOps.move(temp, to: target)
    }
  }

  public static func text(_ folder: SourceFolder, page: Int) -> String {
    FileOps.readIfExists(folder.pageText(page))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}
