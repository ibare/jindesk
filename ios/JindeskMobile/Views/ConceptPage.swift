// 학습 페이지: 맥과 같은 번들 렌더러가 WKWebView 안에서 그린다 (PAGES.md 의 렌더러, MOBILE.md 의 렌더러).
// 렌더러는 앱 전용 주소(jindesk-page://)로 앱 번들과 받아 둔 사본에서만 불러오고 네트워크를 쓰지 않는다. 읽기 전용이다.
import JindeskKit
import SwiftUI
import WebKit

struct ConceptPage: View {
  @Environment(MobileModel.self) private var model
  @Environment(\.openURL) private var openURL
  let concept: Concept
  // 과목 지도에서 연 페이지는 옮겨 가기와 지도 열기를 그 지도 안에서 한다
  var onOpenConcept: ((String) -> Void)?
  var onOpenMap: ((String) -> Void)?

  var body: some View {
    @Bindable var model = model
    PageWebView(json: model.pageJSON(concept), data: model.data) { message in
      switch message["type"]?.stringValue {
      case "openConcept":
        if let id = message["id"]?.stringValue {
          if let onOpenConcept { onOpenConcept(id) } else { model.open(id) }
        }
      // "개념 지도에서 보기": 과목 지도를 이 개념을 고른 채 연다
      case "openMap":
        if let id = message["concept"]?.stringValue {
          if let onOpenMap { onOpenMap(id) } else { model.openMap(focus: id) }
        }
      case "openSource":
        if let source = message["source"]?.stringValue, let page = message["page"]?.numberValue {
          model.openSource(source, page: Int(page))
        }
      // 레퍼런스는 Safari 로 연다 (학습 페이지 안에서는 네트워크를 쓰지 않는다)
      case "openURL":
        if let text = message["url"]?.stringValue, let url = URL(string: text), url.scheme == "https" { openURL(url) }
      case "error":
        print("렌더러 오류: \(message["message"]?.stringValue ?? "")")
      default:
        break
      }
    }
    .ignoresSafeArea(edges: .bottom)
    .navigationTitle(concept.title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct PageWebView: UIViewRepresentable {
  let json: String
  let data: DataFolder?
  let onMessage: (JSONValue) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onMessage: onMessage) }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    let renderer = Bundle.main.resourceURL!.appending(path: "renderer")
    configuration.setURLSchemeHandler(RendererSchemeHandler(root: renderer, data: data), forURLScheme: FigureFrame.pageScheme)
    // 그림 블록의 바깥 라이브러리: 받아 둔 사본만 돌려준다
    if let data { configuration.setURLSchemeHandler(VendorSchemeHandler(store: VendorStore(data)), forURLScheme: FigureFrame.vendorScheme) }
    configuration.userContentController.add(context.coordinator, name: "jindesk")
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.isOpaque = false
    view.backgroundColor = .clear
    view.scrollView.backgroundColor = .clear
    context.coordinator.view = view
    context.coordinator.pending = json
    view.load(URLRequest(url: URL(string: "\(FigureFrame.pageScheme)://app/page.html")!))
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {
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
      action.request.url?.scheme == FigureFrame.pageScheme ? .allow : .cancel
    }
  }
}

// jindesk-page://app/<경로> → 앱 번들의 renderer/<경로>
// jindesk-page://figure/<코드 경로>?c=<개념 id> → 받아 둔 개념 폴더의 그림 코드를 블록 틀에 넣은 것
// 맥 앱의 RendererSchemeHandler 에서 폰 앱이 쓰는 것만 남겼다 (그림 검사기와 다시 만들기 후보는 없다).
final class RendererSchemeHandler: NSObject, WKURLSchemeHandler {
  let root: URL
  let data: DataFolder?

  init(root: URL, data: DataFolder?) {
    self.root = root.standardizedFileURL
    self.data = data
  }

  static let types: [String: String] = [
    "html": "text/html", "js": "text/javascript", "css": "text/css", "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf",
    "png": "image/png", "svg": "image/svg+xml", "json": "application/json",
  ]

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
    if url.host == "figure" {
      guard let data, let concept = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "c" })?.value,
        let cid = ConceptID(concept)
      else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
      let folder = data.conceptDir(cid).standardizedFileURL
      let file = folder.appending(path: String(url.path.drop { $0 == "/" })).standardizedFileURL
      guard file.path.hasPrefix(folder.path + "/figures/"), let code = FileOps.readIfExists(file) else {
        return task.didFailWithError(URLError(.fileDoesNotExist))
      }
      return Self.respond(task, url: url, data: Data(FigureFrame.compose(code).utf8), type: "text/html")
    }
    let file = root.appending(path: String(url.path.drop { $0 == "/" })).standardizedFileURL
    guard file.path.hasPrefix(root.path + "/"), let bytes = try? Data(contentsOf: file) else {
      return task.didFailWithError(URLError(.fileDoesNotExist))
    }
    Self.respond(task, url: url, data: bytes, type: Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream")
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

// jindesk-vendor://<호스트>/<경로> → 받아 둔 library/vendor/ 의 사본. 없는 파일을 받지는 않는다.
final class VendorSchemeHandler: NSObject, WKURLSchemeHandler {
  let store: VendorStore

  init(store: VendorStore) {
    self.store = store
  }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url, let original = VendorStore.original(url), let hit = store.lookup(original) else {
      return task.didFailWithError(URLError(.fileDoesNotExist))
    }
    RendererSchemeHandler.respond(task, url: url, data: hit.data, type: hit.type)
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
