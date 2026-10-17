// 자료 바꾸기 (JOBS.md 의 자료 넣기).
// - PPT, PPTX, KEY: Keynote 로 PDF 를 만든다. 빌드 단계는 마지막 모습만 내보낸다. Keynote 가 없으면 LibreOffice.
// - DOC, DOCX, PAGES: Pages 로 PDF 를 만든다. Pages 가 없으면 LibreOffice.
// - HEIC: JPEG 로 바꾼다.
// - PDF, JPEG, PNG: 그대로 둔다.
// Keynote 와 Pages 는 osascript 로 다룬다. 학생 맥에서 처음 한 번 "Jindesk 가 Keynote 를 제어하려고 한다" 허용 창이 뜬다.
import CoreServices
import Foundation

public enum SourceFormat: Sendable, Equatable {
  case pdf, image, heic, presentation, document
  case unsupported(String)

  public init(_ url: URL) {
    switch url.pathExtension.lowercased() {
    case "pdf": self = .pdf
    case "jpg", "jpeg", "png": self = .image
    case "heic", "heif": self = .heic
    case "ppt", "pptx", "key": self = .presentation
    case "doc", "docx", "pages": self = .document
    case let ext: self = .unsupported(ext)
    }
  }

  public var isSupported: Bool {
    if case .unsupported = self { false } else { true }
  }
}

public struct Converted: Sendable, Equatable {
  // 자료 폴더 안의 파일 이름 (source.pdf, source.jpg)
  public let file: String
  public let by: String
  public let appVersion: String?
}

public enum Converter {
  public struct Failure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
  }

  static let keynote = "com.apple.iWork.Keynote"
  static let pages = "com.apple.iWork.Pages"

  // 원본을 쪽을 나눌 수 있는 모양으로 바꾼다. 바꿀 필요가 없으면 nil.
  public static func convert(_ original: URL, format: SourceFormat, into folder: URL, soffice: String?, environment: [String: String]) async throws
    -> Converted?
  {
    switch format {
    case .pdf, .image, .unsupported:
      return nil
    case .heic:
      guard let image = PageRenderer.render(imageAt: original, maxSide: 8000) else { throw Failure(message: "HEIC 사진을 열지 못했습니다") }
      try PageRenderer.writeJPEG(image, to: folder.appending(path: "source.jpg"))
      return Converted(file: "source.jpg", by: "imageio", appVersion: nil)
    case .presentation, .document:
      let target = folder.appending(path: "source.pdf")
      let bundleID = format == .presentation ? keynote : pages
      if let app = appURL(bundleID) {
        try await exportWithIWork(app: bundleID == keynote ? "Keynote" : "Pages", input: original, output: target, environment: environment)
        return Converted(file: "source.pdf", by: bundleID == keynote ? "keynote" : "pages", appVersion: version(of: app))
      }
      guard let soffice else {
        throw Failure(message: "\(format == .presentation ? "Keynote" : "Pages") 도 LibreOffice 도 없어 PDF 로 바꾸지 못했습니다")
      }
      try await exportWithLibreOffice(soffice, input: original, output: target, environment: environment)
      return Converted(file: "source.pdf", by: "libreoffice", appVersion: nil)
    }
  }

  static func appURL(_ bundleID: String) -> URL? {
    (LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL])?.first
  }

  static func version(of app: URL) -> String? {
    Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }

  // Keynote 나 Pages 로 열어 PDF 로 내보낸다. 앱이 꺼져 있었으면 끝난 뒤 다시 끈다.
  static func exportWithIWork(app: String, input: URL, output: URL, environment: [String: String]) async throws {
    let properties = app == "Keynote" ? " with properties {PDF image quality:Best, all stages:false, skipped slides:false}" : ""
    let script = """
      on run argv
        set inPath to item 1 of argv
        set outPath to item 2 of argv
        set wasRunning to application "\(app)" is running
        tell application "\(app)"
          set theDoc to open (POSIX file inPath)
          export theDoc to (POSIX file outPath) as PDF\(properties)
          close theDoc saving no
          if not wasRunning then quit
        end tell
      end run
      """
    let result = try await ChildProcess.run(
      ChildSpec(executable: "/usr/bin/osascript", arguments: ["-", input.path, output.path], environment: environment, stdin: .data(Data(script.utf8))),
      timeout: .seconds(300))
    guard result.succeeded, FileOps.exists(output) else {
      throw Failure(message: "\(app) 로 PDF 를 만들지 못했습니다: \(result.summary)")
    }
  }

  static func exportWithLibreOffice(_ soffice: String, input: URL, output: URL, environment: [String: String]) async throws {
    let outDir = output.deletingLastPathComponent().appending(path: ".soffice-\(UUID().uuidString.prefix(6))")
    defer { FileOps.remove(outDir) }
    let result = try await ChildProcess.run(
      ChildSpec(executable: soffice, arguments: ["--headless", "--convert-to", "pdf", "--outdir", outDir.path, input.path], environment: environment),
      timeout: .seconds(300))
    let made = outDir.appending(path: input.deletingPathExtension().lastPathComponent + ".pdf")
    guard result.succeeded, FileOps.exists(made) else { throw Failure(message: "LibreOffice 로 PDF 를 만들지 못했습니다: \(result.summary)") }
    try FileManager.default.moveItem(at: made, to: output)
  }
}
