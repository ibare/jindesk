import JindeskKit
import SwiftUI
import WebKit

// 학습 페이지: WKWebView 안에서 번들 렌더러(Contents/Resources/renderer)가 그린다 (PAGES.md 의 렌더러).
// 렌더러는 앱 전용 주소(jindesk-page://)로 앱 번들에서만 불러오고 네트워크를 쓰지 않는다.
struct ConceptPageView: View {
  @Environment(AppModel.self) private var model
  let concept: Concept

  var body: some View {
    let json = model.pageJSON(concept)
    PageWebView(json: json, data: model.data) { message in
      if message["type"]?.stringValue == "openSource", let source = message["source"]?.stringValue, let page = message["page"]?.numberValue {
        model.peek = SourcePeek(source: source, page: Int(page))
      }
    }
  }
}

struct PageWebView: NSViewRepresentable {
  let json: String
  let data: DataFolder?
  let onMessage: (JSONValue) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onMessage: onMessage) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(RendererSchemeHandler(root: AppPaths.renderer, data: data), forURLScheme: RendererSchemeHandler.scheme)
    // 그림 블록의 바깥 라이브러리: 받아 둔 사본만 돌려준다 (보는 동안에는 네트워크를 쓰지 않는다)
    if let data { configuration.setURLSchemeHandler(VendorSchemeHandler(store: VendorStore(data), download: false), forURLScheme: FigureFrame.vendorScheme) }
    configuration.userContentController.add(context.coordinator, name: "jindesk")
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.setValue(false, forKey: "drawsBackground")
    context.coordinator.view = view
    context.coordinator.pending = json
    view.load(URLRequest(url: URL(string: "\(RendererSchemeHandler.scheme)://app/page.html")!))
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    context.coordinator.onMessage = onMessage
    context.coordinator.show(json)
  }

  @MainActor
  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onMessage: (JSONValue) -> Void
    weak var view: WKWebView?
    var pending: String?
    private var ready = false
    private var shown: String?

    init(onMessage: @escaping (JSONValue) -> Void) {
      self.onMessage = onMessage
    }

    func show(_ json: String) {
      guard ready else {
        pending = json
        return
      }
      guard json != shown else { return }
      shown = json
      view?.evaluateJavaScript("window.jindesk.render(\(json))")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard let body = message.body as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: body),
        let value = try? JSONValue.parse(data)
      else { return }
      if value["type"]?.stringValue == "ready" {
        ready = true
        if let pending { show(pending) }
        pending = nil
        return
      }
      onMessage(value)
    }

    // 렌더러 밖으로 나가는 이동은 막는다. 그림 블록의 iframe 은 같은 주소 체계다.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
      action.request.url?.scheme == RendererSchemeHandler.scheme ? .allow : .cancel
    }
  }
}

// jindesk-page://app/<경로> → 앱 번들의 renderer/<경로>
// jindesk-page://figure/<코드 경로>?c=<개념 id> → 개념 폴더의 그림 코드를 블록 틀에 넣은 것
// jindesk-page://check/frame.html → 그림 검사기가 돌려 볼 블록 틀 (검사기가 넣는다)
final class RendererSchemeHandler: NSObject, WKURLSchemeHandler {
  static let scheme = FigureFrame.pageScheme
  let root: URL
  let data: DataFolder?
  let checkPage: String?

  init(root: URL, data: DataFolder?, checkPage: String? = nil) {
    self.root = root.standardizedFileURL
    self.data = data
    self.checkPage = checkPage
  }

  static let types: [String: String] = [
    "html": "text/html", "js": "text/javascript", "css": "text/css", "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf",
    "png": "image/png", "svg": "image/svg+xml", "json": "application/json",
  ]

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
    switch url.host {
    case "figure":
      guard let data, let concept = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "c" })?.value,
        let cid = ConceptID(concept)
      else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
      let folder = data.conceptDir(cid).standardizedFileURL
      let file = folder.appending(path: String(url.path.drop { $0 == "/" })).standardizedFileURL
      guard file.path.hasPrefix(folder.path + "/figures/"), let code = FileOps.readIfExists(file) else {
        return task.didFailWithError(URLError(.fileDoesNotExist))
      }
      Self.respond(task, url: url, data: Data(FigureFrame.compose(code).utf8), type: "text/html")
    case "check":
      guard let checkPage else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
      Self.respond(task, url: url, data: Data(checkPage.utf8), type: "text/html")
    default:
      let file = root.appending(path: String(url.path.drop { $0 == "/" })).standardizedFileURL
      guard file.path.hasPrefix(root.path + "/"), let bytes = try? Data(contentsOf: file) else {
        return task.didFailWithError(URLError(.fileDoesNotExist))
      }
      Self.respond(task, url: url, data: bytes, type: Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream")
    }
  }

  // 그림 블록은 따로 떨어진 출처(sandbox)에서 돈다. 글꼴과 모듈을 불러갈 수 있게 모든 출처에 연다.
  static func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, type: String) {
    let headers = ["Content-Type": type, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"]
    task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
    task.didReceive(data)
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

// jindesk-vendor://<호스트>/<경로> → library/vendor/ 의 사본. 그림 검사 때만(download) 없는 파일을 https 로 받아 남긴다.
final class VendorSchemeHandler: NSObject, WKURLSchemeHandler {
  let store: VendorStore
  let download: Bool
  // 이번에 받은 주소 (검사 결과에 적는다)
  private(set) var fetched: [String] = []
  private(set) var failures: [String] = []
  private var stopped: Set<ObjectIdentifier> = []

  init(store: VendorStore, download: Bool) {
    self.store = store
    self.download = download
  }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url, let original = VendorStore.original(url) else { return task.didFailWithError(URLError(.badURL)) }
    if let hit = store.lookup(original) {
      return RendererSchemeHandler.respond(task, url: url, data: hit.data, type: hit.type)
    }
    guard download else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
    let store = store
    let id = ObjectIdentifier(task)
    Task { @MainActor in
      do {
        let got = try await store.fetch(original)
        self.fetched.append(original.absoluteString)
        guard !self.stopped.contains(id) else { return }
        RendererSchemeHandler.respond(task, url: url, data: got.data, type: got.type)
      } catch {
        self.failures.append("\(original.absoluteString): \(error.localizedDescription)")
        guard !self.stopped.contains(id) else { return }
        task.didFailWithError(error)
      }
    }
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
    stopped.insert(ObjectIdentifier(task))
  }
}

// 출처 칩을 눌렀을 때 여는 원래 자료의 쪽
struct SourcePeek: Identifiable, Equatable {
  let source: String
  var page: Int
  var id: String { "\(source)#\(page)" }
}

struct SourcePeekSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State var peek: SourcePeek
  @State private var image: NSImage?

  var body: some View {
    let source = model.library.source(peek.source)
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(source.map(SourceRow.title) ?? peek.source).font(.headline)
          Text("\(peek.page)쪽 / \(source?.meta.pages ?? 0)쪽").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("앞 쪽", systemImage: "chevron.left") { peek.page -= 1 }
          .disabled(peek.page <= 1)
          .keyboardShortcut(.leftArrow, modifiers: [])
        Button("다음 쪽", systemImage: "chevron.right") { peek.page += 1 }
          .disabled(peek.page >= (source?.meta.pages ?? 1))
          .keyboardShortcut(.rightArrow, modifiers: [])
      }
      .labelStyle(.iconOnly)
      Group {
        if let image {
          Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
          Rectangle().fill(Color.secondary.opacity(0.08)).aspectRatio(16 / 9, contentMode: .fit).overlay(ProgressView().controlSize(.small))
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
      HStack {
        Button("자료 보기") {
          model.selection = .source(peek.source)
          dismiss()
        }
        Spacer()
        Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(18)
    .frame(minWidth: 720, idealWidth: 860, minHeight: 520)
    .task(id: peek.page) {
      image = nil
      guard let source, let url = await model.pageImage(source, page: peek.page) else { return }
      image = NSImage(contentsOf: url)
    }
  }
}
