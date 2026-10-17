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
    PageWebView(json: json) { message in
      if message["type"]?.stringValue == "openSource", let source = message["source"]?.stringValue, let page = message["page"]?.numberValue {
        model.peek = SourcePeek(source: source, page: Int(page))
      }
    }
  }
}

struct PageWebView: NSViewRepresentable {
  let json: String
  let onMessage: (JSONValue) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onMessage: onMessage) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(RendererSchemeHandler(root: AppPaths.renderer), forURLScheme: RendererSchemeHandler.scheme)
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

    // 렌더러 밖으로 나가는 이동은 막는다
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
      action.request.url?.scheme == RendererSchemeHandler.scheme ? .allow : .cancel
    }
  }
}

// jindesk-page://app/<경로> → 앱 번들의 renderer/<경로>
final class RendererSchemeHandler: NSObject, WKURLSchemeHandler {
  static let scheme = "jindesk-page"
  let root: URL

  init(root: URL) {
    self.root = root.standardizedFileURL
  }

  static let types: [String: String] = [
    "html": "text/html", "js": "text/javascript", "css": "text/css", "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf",
    "png": "image/png", "svg": "image/svg+xml", "json": "application/json",
  ]

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
    let file = root.appending(path: String(url.path.drop { $0 == "/" })).standardizedFileURL
    guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
      return task.didFailWithError(URLError(.fileDoesNotExist))
    }
    let type = Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type, "Content-Length": String(data.count)])!
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
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
