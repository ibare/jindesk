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
      if message["type"]?.stringValue == "error" {
        FileHandle.standardError.write(Data("렌더러 오류: \(message["message"]?.stringValue ?? "")\n".utf8))
      }
      if message["type"]?.stringValue == "openSource", let source = message["source"]?.stringValue, let page = message["page"]?.numberValue {
        model.peek = SourcePeek(source: source, page: Int(page))
      }
      if message["type"]?.stringValue == "openConcept", let id = message["id"]?.stringValue, model.concept(id) != nil {
        model.selection = .concept(id)
        model.revealInList = id
      }
      // 앞뒤 개념 지도의 "개념 지도에서 보기": 과목 지도를 이 개념을 고른 채 연다
      if message["type"]?.stringValue == "openMap", let id = message["concept"]?.stringValue, let cid = ConceptID(id) {
        model.mapFocus = id
        model.selection = .map(cid.subject)
      }
      if message["type"]?.stringValue == "comment", let unit = message["unit"]?.stringValue, let text = message["text"]?.stringValue,
        let kind = message["kind"]?.stringValue.flatMap(CommentKind.init(rawValue:))
      {
        let rev = message["rev"]?.numberValue.map { Int($0) } ?? 1
        let quote = message["quote"]?.stringValue ?? ""
        let concept = concept.id
        Task { try? await model.addComment(concept: concept, unit: unit, rev: rev, quote: quote, kind: kind, text: text) }
      }
      if message["type"]?.stringValue == "deleteComment", let id = message["id"]?.stringValue { try? model.deleteComment(id) }
      if message["type"]?.stringValue == "openRegen", let unit = message["unit"]?.stringValue {
        let ops = (message["ops"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(DirectiveOp.init(rawValue:)) }
        model.regenTarget = RegenTarget(
          concept: concept.id, unit: unit, rev: message["rev"]?.numberValue.map { Int($0) } ?? 1, ops: ops, quote: message["quote"]?.stringValue ?? "",
          fromComment: message["fromComment"]?.stringValue, note: message["note"]?.stringValue)
      }
      if message["type"]?.stringValue == "acceptDirective", let id = message["id"]?.stringValue { Task { await model.acceptDirective(id) } }
      if message["type"]?.stringValue == "keepDirective", let id = message["id"]?.stringValue { model.keepDirective(id) }
      // 레퍼런스는 기본 브라우저로 연다 (학습 페이지 안에서는 네트워크를 쓰지 않는다)
      if message["type"]?.stringValue == "openURL", let text = message["url"]?.stringValue, let url = URL(string: text), url.scheme == "https" {
        NSWorkspace.shared.open(url)
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
    case "candidate":
      // 다시 만들기의 그림 후보 (records/regen/<작업 id>/figures/<파일>)
      let parts = url.path.split(separator: "/").map(String.init)
      guard let data, parts.count == 2, JobID.isValid(parts[0]), !parts[1].contains(".."),
        let code = FileOps.readIfExists(data.record(JobKind.regen.rawValue, parts[0]).appending(path: "figures/\(parts[1])"))
      else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
      Self.respond(task, url: url, data: Data(FigureFrame.compose(code).utf8), type: "text/html")
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

// 다시 만들기 시트: 방식 고르기, 메모, "놓이는 곳 · 그대로인 것 · 검사" 설명
struct RegenSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let target: RegenTarget
  @State private var op: DirectiveOp = .easy
  @State private var note = ""
  @State private var error: String?
  @State private var busy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("다시 만들기").font(.headline)
      Text("“\(TexText.plain(target.quote))”").font(.callout).foregroundStyle(.secondary).lineLimit(3)
      Picker("방식", selection: $op) {
        ForEach(target.ops, id: \.self) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      Text(op.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Text("하고 싶은 말 (적지 않아도 됩니다)").font(.caption)
      TextEditor(text: $note).font(.body).frame(minHeight: 70).border(.quaternary)
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(busy ? "보내는 중…" : "요청") {
          busy = true
          Task {
            do {
              try await model.requestRegen(target, op: op, note: note)
              dismiss()
            } catch {
              self.error = error.localizedDescription
            }
            busy = false
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(busy)
      }
    }
    .padding(18)
    .frame(width: 520)
    .onAppear {
      op = target.ops.first ?? .easy
      note = target.note ?? ""
    }
  }
}

// 쪽 이미지를 확대해 본다 (DECISIONS.md 31): 트랙패드로 벌리거나 두 번 눌러 2배, 단추로 1.5배씩. 1배는 칸에 맞춘 크기다.
struct ZoomablePage: View {
  let image: NSImage
  @Binding var zoom: CGFloat
  @GestureState private var pinch: CGFloat = 1
  static let range: ClosedRange<CGFloat> = 1...4

  static func clamp(_ z: CGFloat) -> CGFloat { min(max(z, range.lowerBound), range.upperBound) }

  var body: some View {
    GeometryReader { geo in
      let fit = Self.fit(image.size, in: geo.size)
      let scale = Self.clamp(zoom * pinch)
      ScrollView([.horizontal, .vertical]) {
        Image(nsImage: image).resizable().interpolation(.high)
          .frame(width: fit.width * scale, height: fit.height * scale)
          .frame(minWidth: geo.size.width, minHeight: geo.size.height)
      }
      .scrollIndicators(scale > 1 ? .automatic : .hidden)
      .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }.onEnded { value in zoom = Self.clamp(zoom * value.magnification) })
      .onTapGesture(count: 2) { withAnimation { zoom = zoom > 1 ? 1 : 2 } }
    }
  }

  static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
    guard size.width > 0, size.height > 0 else { return box }
    let s = min(box.width / size.width, box.height / size.height)
    return CGSize(width: size.width * s, height: size.height * s)
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
  @State private var zoom: CGFloat = 1

  var body: some View {
    let source = model.library.source(peek.source)
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(source.map(SourceRow.title) ?? peek.source).font(.headline)
          Text("\(peek.page)쪽 / \(source?.meta.pages ?? 0)쪽").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("축소", systemImage: "minus.magnifyingglass") { withAnimation { zoom = ZoomablePage.clamp(zoom / 1.5) } }
          .disabled(zoom <= ZoomablePage.range.lowerBound)
          .keyboardShortcut("-", modifiers: .command)
        Button("확대", systemImage: "plus.magnifyingglass") { withAnimation { zoom = ZoomablePage.clamp(zoom * 1.5) } }
          .disabled(zoom >= ZoomablePage.range.upperBound)
          .keyboardShortcut("=", modifiers: .command)
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
          ZoomablePage(image: image, zoom: $zoom)
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
      zoom = 1
      guard let source, let url = await model.pageImage(source, page: peek.page) else { return }
      image = NSImage(contentsOf: url)
    }
  }
}
