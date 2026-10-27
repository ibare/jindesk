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
  // 오른쪽 칸(iPhone 은 목록 위)과 개념 지도에서 연 학습 페이지: 보기를 칸 바깥에 두고 다시 쓴다 (PageWebView)
  var kept = false

  // 찾기 상태(pageFind)는 PageBody 만 읽는다. 여기서 읽으면 찾을 말을 칠 때마다, 렌더러가 수를 알릴 때마다 이 body 가 다시 돌아
  // 페이지 조합(pageJSON: 페이지, 곁 층, 용어집, 코멘트, 목차를 읽는다)을 다시 한다
  var body: some View {
    PageBody(concept: concept.id, json: model.pageJSON(concept), kept: kept, onMessage: handle)
      .navigationTitle(concept.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { model.showPageFind(concept.id) } label: { Label("페이지에서 찾기", systemImage: "magnifyingglass") }
        }
      }
  }

  private func handle(_ message: JSONValue) {
    switch message["type"]?.stringValue {
    // 페이지 안 찾기: 찾은 곳 수와 지금 몇 번째
    case "find":
      model.pageFindReport(concept: concept.id, total: Int(message["total"]?.numberValue ?? 0), index: Int(message["index"]?.numberValue ?? 0))
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
}

// 학습 페이지 보기와 그 위의 찾기 막대 (DECISIONS.md 48). 페이지 JSON 은 바깥에서 만들어 받는다
private struct PageBody: View {
  @Environment(MobileModel.self) private var model
  let concept: String
  let json: String
  let kept: Bool
  let onMessage: (JSONValue) -> Void

  var body: some View {
    let find = model.pageFind?.concept == concept ? model.pageFind : nil
    PageWebView(json: json, data: model.data, kept: kept, find: find?.request, onMessage: onMessage)
      .ignoresSafeArea(edges: .bottom)
      .safeAreaInset(edge: .top, spacing: 0) {
        if find != nil { PageFindBar() }
      }
  }
}

// 학습 페이지 위의 찾기 막대: 찾을 말, 지금 / 모두, 이전·다음, 닫기 (맥의 찾기 막대와 같다)
struct PageFindBar: View {
  @Environment(MobileModel.self) private var model
  @State private var text = ""
  @FocusState private var focused: Bool

  var body: some View {
    let find = model.pageFind
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("페이지에서 찾기", text: $text)
        .focused($focused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.search)
        .onSubmit { model.pageFind?.step(1) }
      Text(find?.countLabel ?? "").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
      Button { model.pageFind?.step(-1) } label: { Image(systemName: "chevron.up") }.disabled((find?.total ?? 0) == 0)
      Button { model.pageFind?.step(1) } label: { Image(systemName: "chevron.down") }.disabled((find?.total ?? 0) == 0)
      Button("닫기") { model.pageFind = nil }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.bar)
    .onAppear {
      text = find?.query ?? ""
      if (find?.focus ?? 0) > 0 { focused = true }
    }
    .onChange(of: text) { model.pageFind?.setQuery(text) }
    // 찾기 단추로 오를 때만 칸이 커서를 받는다 (찾기 결과에서 다시 열어 0 으로 돌아갈 때 키보드를 띄우지 않는다)
    .onChange(of: model.pageFind?.focus) { old, new in if (new ?? 0) > (old ?? 0) { focused = true } }
    // iPad 두 칸에서는 막대가 열린 채 찾기 결과를 다른 말로 열면 이 막대가 그대로 남는다. 칸도 그 말로 (맥의 막대와 같다)
    .onChange(of: model.pageFind?.query) {
      if let q = model.pageFind?.query, q != text.trimmingCharacters(in: .whitespacesAndNewlines) { text = q }
    }
  }
}

struct PageWebView: UIViewRepresentable {
  let json: String
  let data: DataFolder?
  // 오른쪽 칸과 개념 지도에서 연 학습 페이지는 보기를 칸 바깥에 두고 다시 쓴다(둘이 함께 보이는 일은 없다). iPad 를 돌리면
  // 칸 나누기를 새로 만드는데(SplitLayout), 그때 페이지를 다시 그리지 않고 옮겨 붙여 펼친 한국어, 그림의 상태, 읽던 자리를 지킨다.
  var kept = false
  // 페이지 안 찾기의 요청 (없으면 표시를 걷는다)
  var find: FindRequest?
  let onMessage: (JSONValue) -> Void

  func makeCoordinator() -> Coordinator { kept ? Coordinator.kept(data: data) : Coordinator(data: data) }

  // 보기를 받침 위에 얹는다. 받침마다 그릴 페이지와 메시지 처리를 들고, 보기를 가진 받침의 것이 보인다.
  func makeUIView(context: Context) -> Base {
    let base = Base()
    base.backgroundColor = .clear
    base.coordinator = context.coordinator
    context.coordinator.adopt(base)
    return base
  }

  func updateUIView(_ base: Base, context: Context) {
    base.json = json
    base.find = find
    base.onMessage = onMessage
    context.coordinator.refresh(base)
  }

  // 화면에 붙거나 떨어질 때 다시 쓰는 보기를 어디에 둘지 다시 정한다
  final class Base: UIView {
    weak var coordinator: Coordinator?
    var json = ""
    var find: FindRequest?
    var onMessage: (JSONValue) -> Void = { _ in }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      coordinator?.place()
    }
  }

  struct WeakBase {
    weak var base: Base?
  }

  @MainActor
  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private static var keptOne: Coordinator?

    static func kept(data: DataFolder?) -> Coordinator {
      if let keptOne { return keptOne }
      let made = Coordinator(data: data)
      keptOne = made
      return made
    }

    let view: WKWebView
    var onMessage: (JSONValue) -> Void = { _ in }
    private var pending: String?
    private var ready = false
    private var shown: String?
    // 페이지 안 찾기: 보낼 요청과 마지막으로 보낸 요청 (nil 이면 페이지에 표시가 없다)
    private var find: FindRequest?
    private var findSent: UUID?
    // 이 보기를 쓰는 받침들 (만든 차례). 돌려서 칸을 새로 만들 때 SwiftUI 가 화면에 붙이지 않는 받침을 더 만들기도 하므로,
    // 마지막에 만든 받침이 아니라 화면에 붙은 받침 가운데 마지막에 만든 것이 보기를 갖는다.
    private var bases: [WeakBase] = []

    init(data: DataFolder?) {
      let configuration = WKWebViewConfiguration()
      let renderer = Bundle.main.resourceURL!.appending(path: "renderer")
      configuration.setURLSchemeHandler(RendererSchemeHandler(root: renderer, data: data), forURLScheme: FigureFrame.pageScheme)
      // 그림 블록의 바깥 라이브러리: 받아 둔 사본만 돌려준다
      if let data { configuration.setURLSchemeHandler(VendorSchemeHandler(store: VendorStore(data)), forURLScheme: FigureFrame.vendorScheme) }
      configuration.websiteDataStore = .nonPersistent()
      view = WKWebView(frame: .zero, configuration: configuration)
      super.init()
      // 보기가 이 객체를 붙들면 서로 붙들어 풀리지 않으므로 약하게 잇는다
      configuration.userContentController.add(WeakHandler(self), name: "jindesk")
      view.navigationDelegate = self
      view.isOpaque = false
      view.backgroundColor = .clear
      view.scrollView.backgroundColor = .clear
      view.load(URLRequest(url: Self.pageURL))
    }

    static let pageURL = URL(string: "\(FigureFrame.pageScheme)://app/page.html")!

    func adopt(_ base: Base) {
      bases.removeAll { $0.base == nil }
      bases.append(WeakBase(base: base))
      place()
    }

    // 보기를 화면에 붙은 받침 가운데 마지막에 만든 것에 둔다. 화면에 붙은 받침이 없으면 지금 자리에 둔다(처음이면 새 받침).
    func place() {
      bases.removeAll { $0.base == nil }
      let live = bases.compactMap(\.base)
      guard let target = live.last(where: { $0.window != nil }) ?? (view.superview == nil ? live.last : nil) else { return }
      if view.superview !== target {
        view.frame = target.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        target.addSubview(view)
      }
      refresh(target)
    }

    // 보기를 가진 받침의 페이지를 그린다. 보기를 갖지 않은 받침(빠지는 옛 페이지)은 그리지 않는다.
    func refresh(_ base: Base) {
      guard view.superview === base, !base.json.isEmpty else { return }
      onMessage = base.onMessage
      // 찾기 요청을 먼저 받아 두어야, 다시 그린 뒤 같은 요청을 keep 으로 다시 건다
      find = base.find
      show(base.json)
      flushFind()
    }

    func show(_ json: String) {
      guard ready else {
        pending = json
        return
      }
      guard json != shown else { return }
      shown = json
      view.evaluateJavaScript("window.jindesk.render(\(json))")
      // 다시 그리면 찾기 표시가 사라진다. 이미 보낸 요청이면 지금 곳을 지킨 채 다시 건다
      if let find, findSent == find.id { view.evaluateJavaScript(find.script(keep: true)) }
    }

    // 새 찾기 요청을 보내거나, 요청이 없어졌으면 표시를 걷는다
    func flushFind() {
      guard ready, shown != nil else { return }
      if let find {
        guard findSent != find.id else { return }
        findSent = find.id
        view.evaluateJavaScript(find.script())
      } else if findSent != nil {
        findSent = nil
        view.evaluateJavaScript(FindRequest.clear)
      }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard let body = message.body as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: body),
        let value = try? JSONValue.parse(data)
      else { return }
      if value["type"]?.stringValue == "ready" {
        ready = true
        if let pending { show(pending) }
        pending = nil
        flushFind()
        return
      }
      onMessage(value)
    }

    // 렌더러 밖으로 나가는 이동은 막는다. 그림 블록의 iframe 은 같은 주소 체계다.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
      action.request.url?.scheme == FigureFrame.pageScheme ? .allow : .cancel
    }

    // OS 가 웹 콘텐츠 프로세스만 끝내면(메모리 압박, 무거운 그림, 오래 뒤에 둠) 보기가 빈 채로 남는다.
    // 다시 쓰는 보기는 앱이 끝날 때까지 하나이므로, 렌더러를 다시 불러 보이던 페이지를 다시 그린다.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      ready = false
      pending = shown ?? pending
      shown = nil
      findSent = nil
      webView.load(URLRequest(url: Self.pageURL))
    }
  }

  // 렌더러의 메시지를 Coordinator 로 넘긴다. WKUserContentController 는 받는 쪽을 강하게 붙든다.
  final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: Coordinator?

    init(_ target: Coordinator) {
      self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      target?.userContentController(controller, didReceive: message)
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
