// 그림 블록 (PAGES.md 의 그림 블록, DECISIONS.md 18·19).
// 에이전트가 HTML 조각을 쓰고, 러너는 블록 틀에 넣어 돌아가는지만 본다. 그림이 부르는 바깥 라이브러리는 그때 받아
// library/vendor/<호스트>/<경로> 에 두고, 보일 때는 https:// 주소를 앱 전용 주소(jindesk-vendor://)로 바꿔 받아 둔 사본을 돌려준다.
import Foundation

public enum FigureFrame {
  public static let partsVersion = 1
  public static let vendorScheme = "jindesk-vendor"
  public static let pageScheme = "jindesk-page"

  // 그림 코드의 https:// 주소를 받아 둔 사본의 주소로 바꾼다
  public static func rewrite(_ code: String) -> String {
    code.replacingOccurrences(of: "https://", with: "\(vendorScheme)://")
  }

  // 블록 틀: 테마 색, KaTeX, 공통 부품, 그림 조각
  public static func compose(_ fragment: String) -> String {
    let csp = [
      "default-src 'none'",
      "script-src 'unsafe-inline' 'unsafe-eval' \(pageScheme): \(vendorScheme): blob:",
      "style-src 'unsafe-inline' \(pageScheme): \(vendorScheme):",
      "img-src data: blob: \(pageScheme): \(vendorScheme):",
      "font-src data: \(pageScheme): \(vendorScheme):",
      "connect-src \(pageScheme): \(vendorScheme):",
      "worker-src blob: \(vendorScheme):",
    ].joined(separator: "; ")
    let base = "\(pageScheme)://app"
    return """
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="\(csp)">
      <link rel="stylesheet" href="\(base)/katex/katex.min.css">
      <link rel="stylesheet" href="\(base)/parts/parts.css">
      <script src="\(base)/katex/katex.min.js"></script>
      <script src="\(base)/parts/parts.js"></script>
      </head>
      <body>
      <div id="figure">
      \(rewrite(fragment))
      </div>
      </body>
      </html>
      """
  }
}

// 그림 블록이 돌아가는지 본 결과
public struct FigureCheckResult: Sendable, Equatable {
  public var errors: [String]
  // 정해진 시간 안에 무언가 그려졌다 (스냅숏이 배경색 한 가지가 아니다)
  public var painted: Bool
  // 그 뒤에도 페이지가 응답한다
  public var responsive: Bool
  // 이번에 받아 둔 바깥 파일 주소
  public var fetched: [String]

  public init(errors: [String] = [], painted: Bool, responsive: Bool, fetched: [String] = []) {
    self.errors = errors
    self.painted = painted
    self.responsive = responsive
    self.fetched = fetched
  }

  public var problems: [String] {
    var out = errors.prefix(5).map { "스크립트 오류: \($0)" }
    if !painted { out.append("3초 안에 아무것도 그려지지 않았습니다") }
    if !responsive { out.append("그린 뒤 페이지가 응답하지 않습니다 (멈춤)") }
    return out
  }
}

// 그림 블록을 화면 밖 웹 보기에서 돌려 본다. 앱이 WebKit 으로 만들어 설정에 넣는다 (엔진은 화면 코드에 의존하지 않는다).
public protocol FigureChecking: Sendable {
  func check(html: String, vendor: VendorStore) async -> FigureCheckResult
}

// 그림이 부른 바깥 파일의 사본 (library/vendor/). 기록이라 고치지 않고, 같은 주소는 한 번만 받는다.
// vendor/index.jsonl 에 주소, 파일, 형식, 해시, 받은 때를 덧붙인다.
public struct VendorStore: Sendable {
  public let root: URL
  public static let sizeLimit = 40 * 1024 * 1024

  public init(_ data: DataFolder) {
    root = data.library.appending(path: "vendor")
  }

  public init(root: URL) {
    self.root = root
  }

  var index: URL { root.appending(path: "index.jsonl") }

  // https://<호스트>/<경로>?<질의> → vendor/<호스트>/<경로> (질의가 있으면 해시를 붙인다, 끝이 / 이면 index)
  public func file(for url: URL) -> URL? {
    guard let host = url.host?.lowercased(), !host.isEmpty, !host.contains("..") else { return nil }
    // URL.path 는 끝의 / 를 떼므로 percentEncoded 판을 쓴다
    var path = url.path(percentEncoded: false)
    if path.isEmpty || path.hasSuffix("/") { path += "index" }
    let parts = path.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." && !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    var last = parts.last!
    if let q = url.query, !q.isEmpty { last += "@q-" + String(Hash.sha256(Data(q.utf8)).prefix(8)) }
    var out = root.appending(path: host)
    for p in parts.dropLast() { out = out.appending(path: p) }
    return out.appending(path: last)
  }

  // 받아 둔 사본과 형식
  public func lookup(_ url: URL) -> (data: Data, type: String)? {
    guard let file = file(for: url), let data = try? Data(contentsOf: file) else { return nil }
    return (data, types()[file.path.replacingOccurrences(of: root.path + "/", with: "")] ?? Self.guessType(file))
  }

  func types() -> [String: String] {
    guard let lines = try? JSONLines.read(index) else { return [:] }
    var out: [String: String] = [:]
    for v in lines.values { if let f = v["file"]?.stringValue, let t = v["type"]?.stringValue { out[f] = t } }
    return out
  }

  // 받아서 남긴다. 이미 있으면 그것을 돌려준다.
  public func fetch(_ url: URL) async throws -> (data: Data, type: String) {
    if let hit = lookup(url) { return hit }
    guard url.scheme == "https", let file = file(for: url) else { throw ToolError("받을 수 없는 주소입니다: \(url.absoluteString)") }
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw ToolError("받지 못했습니다 (\((response as? HTTPURLResponse)?.statusCode ?? 0)): \(url.absoluteString)")
    }
    guard data.count <= Self.sizeLimit else { throw ToolError("너무 큽니다: \(url.absoluteString)") }
    let type = (http.value(forHTTPHeaderField: "Content-Type") ?? Self.guessType(file)).split(separator: ";").first.map {
      String($0).trimmingCharacters(in: .whitespaces)
    } ?? "application/octet-stream"
    if !FileOps.exists(file) {
      try FileOps.writeAtomic(data, to: file)
      let rel = file.path.replacingOccurrences(of: root.path + "/", with: "")
      let line: JSONValue = .object([
        "v": .number(1), "url": .string(url.absoluteString), "file": .string(rel), "type": .string(type), "sha256": .string(Hash.short(data)),
        "at": .string(Clock.isoLocal()),
      ])
      try FileOps.appendLine(JSONText.line(line), to: index)
    }
    return (data, type)
  }

  static func guessType(_ file: URL) -> String {
    switch file.pathExtension.lowercased() {
    case "js", "mjs": "text/javascript"
    case "css": "text/css"
    case "json": "application/json"
    case "wasm": "application/wasm"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    case "woff2": "font/woff2"
    case "woff": "font/woff"
    case "ttf": "font/ttf"
    default: "text/javascript"
    }
  }

  // jindesk-vendor://<호스트>/<경로> → https://<호스트>/<경로>
  public static func original(_ url: URL) -> URL? {
    guard url.scheme == FigureFrame.vendorScheme, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    c.scheme = "https"
    return c.url
  }
}
