// 그림 블록이 돌아가는지 화면 밖 웹 보기에서 본다 (PAGES.md 의 그림 블록: 러너 검사).
// - 스크립트 오류가 없다
// - 정해진 시간(기본 3초) 안에 무언가 그려진다. 스냅숏이 배경색 한 가지가 아니다
// - 멈추지 않는다. 그 뒤에도 페이지가 응답한다
// - 처음 장면에서 보이는 글자끼리 겹치지 않는다
// 그림이 부른 바깥 파일은 이때 받아 library/vendor/ 에 둔다. 그림이 내용에 맞는지는 보지 않는다.
import AppKit
import JindeskKit
import WebKit

struct WebFigureChecker: FigureChecking {
  let renderer: URL
  var wait: Duration = .seconds(3)

  func check(html: String, vendor: VendorStore) async -> FigureCheckResult {
    await Self.run(html: html, vendor: vendor, renderer: renderer, wait: wait)
  }

  @MainActor
  static func run(html: String, vendor: VendorStore, renderer: URL, wait: Duration) async -> FigureCheckResult {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(RendererSchemeHandler(root: renderer, data: nil, checkPage: html), forURLScheme: FigureFrame.pageScheme)
    let vendorHandler = VendorSchemeHandler(store: vendor, download: true)
    configuration.setURLSchemeHandler(vendorHandler, forURLScheme: FigureFrame.vendorScheme)
    let messages = FigureMessages()
    configuration.userContentController.add(messages, name: "figure")

    let size = NSRect(x: 0, y: 0, width: 720, height: 560)
    let view = WKWebView(frame: size, configuration: configuration)
    // 창에 붙어 있어야 그려진다. 사용자가 보는 화면 밖에 둔다.
    let window = NSWindow(contentRect: size.offsetBy(dx: -12000, dy: -12000), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFrontRegardless()
    defer {
      view.stopLoading()
      configuration.userContentController.removeAllScriptMessageHandlers()
      window.orderOut(nil)
      window.contentView = nil
    }

    let navigation = NavigationWaiter()
    view.navigationDelegate = navigation
    view.load(URLRequest(url: URL(string: "\(FigureFrame.pageScheme)://check/frame.html")!))
    await navigation.finished(timeout: .seconds(15))
    try? await Task.sleep(for: wait)

    var errors = messages.errors
    if let failure = navigation.failure { errors.append("불러오지 못했습니다: \(failure)") }
    errors += vendorHandler.failures.map { "바깥 파일을 받지 못했습니다: \($0)" }
    let responsive = await respond(view, timeout: .seconds(3))
    let painted = responsive ? await paintedSomething(view) : false
    let overlaps = responsive ? await overlappingText(view) : []
    return FigureCheckResult(errors: errors, painted: painted, responsive: responsive, fetched: vendorHandler.fetched, overlaps: overlaps)
  }

  // 보이는 글자 상자(글자 줄, SVG 글자, KaTeX 수식 하나)끼리 작은 쪽 넓이의 30% 넘게 겹친 쌍
  static let overlapScript = """
    (function () {
      var boxes = [];
      function visible(el) {
        return !el.checkVisibility || el.checkVisibility({ opacityProperty: true, visibilityProperty: true });
      }
      function add(rect, text) {
        if (rect.width < 2 || rect.height < 2) return;
        boxes.push({ x: rect.left, y: rect.top, r: rect.right, b: rect.bottom, t: text });
      }
      document.querySelectorAll(".katex").forEach(function (k) {
        if (visible(k) && !k.parentElement.closest(".katex")) add(k.getBoundingClientRect(), k.textContent);
      });
      document.querySelectorAll("svg text").forEach(function (t) {
        if (visible(t) && t.textContent.trim()) add(t.getBoundingClientRect(), t.textContent);
      });
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      var node;
      while ((node = walker.nextNode())) {
        var el = node.parentElement;
        if (!node.textContent.trim() || !el || el.closest(".katex, svg, script, style") || !visible(el)) continue;
        var range = document.createRange();
        range.selectNodeContents(node);
        Array.prototype.forEach.call(range.getClientRects(), function (rect) { add(rect, node.textContent); });
      }
      var out = [];
      for (var i = 0; i < boxes.length && out.length < 5; i++) {
        for (var j = i + 1; j < boxes.length && out.length < 5; j++) {
          var a = boxes[i], b = boxes[j];
          var w = Math.min(a.r, b.r) - Math.max(a.x, b.x), h = Math.min(a.b, b.b) - Math.max(a.y, b.y);
          if (w <= 0 || h <= 0) continue;
          var small = Math.min((a.r - a.x) * (a.b - a.y), (b.r - b.x) * (b.b - b.y));
          if (w * h > 0.3 * small) out.push(JSON.stringify(a.t.trim().slice(0, 40)) + " ↔ " + JSON.stringify(b.t.trim().slice(0, 40)));
        }
      }
      return out;
    })()
    """

  @MainActor
  static func overlappingText(_ view: WKWebView) async -> [String] {
    (try? await view.evaluateJavaScript(overlapScript) as? [String]) ?? []
  }

  // 정해진 시간 안에 스크립트가 답하는가 (멈춘 그림은 답하지 않는다)
  @MainActor
  static func respond(_ view: WKWebView, timeout: Duration) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let once = Once(continuation)
      view.evaluateJavaScript("1 + 1") { _, error in once.resume(error == nil) }
      Task { @MainActor in
        try? await Task.sleep(for: timeout)
        once.resume(false)
      }
    }
  }

  // 스냅숏이 한 가지 색이 아닌가
  @MainActor
  static func paintedSomething(_ view: WKWebView) async -> Bool {
    guard let image = try? await view.takeSnapshot(configuration: nil),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return false }
    let w = 96
    let h = max(1, Int(Double(w) * Double(cg.height) / Double(max(cg.width, 1))))
    guard
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return false }
    let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    let r0 = Int(pixels[0]), g0 = Int(pixels[1]), b0 = Int(pixels[2])
    var different = 0
    for i in 0..<(w * h) {
      let p = i * 4
      if abs(Int(pixels[p]) - r0) + abs(Int(pixels[p + 1]) - g0) + abs(Int(pixels[p + 2]) - b0) > 24 { different += 1 }
    }
    return different > 8
  }
}

@MainActor
final class Once {
  private var continuation: CheckedContinuation<Bool, Never>?

  init(_ continuation: CheckedContinuation<Bool, Never>) {
    self.continuation = continuation
  }

  func resume(_ value: Bool) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}

// 블록 틀의 공통 부품이 알리는 오류 (renderer/parts/parts.js)
@MainActor
final class FigureMessages: NSObject, WKScriptMessageHandler {
  private(set) var errors: [String] = []

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any], body["type"] as? String == "error" else { return }
    let text = (body["message"] as? String) ?? "script error"
    if !errors.contains(text) { errors.append(String(text.prefix(300))) }
  }
}

@MainActor
final class NavigationWaiter: NSObject, WKNavigationDelegate {
  private(set) var failure: String?
  private var done = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func finished(timeout: Duration) async {
    if done { return }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      waiters.append(c)
      Task { @MainActor in
        try? await Task.sleep(for: timeout)
        if !self.done { self.failure = self.failure ?? "\(timeout) 안에 다 불러오지 못했습니다" }
        self.finish()
      }
    }
  }

  private func finish() {
    done = true
    for w in waiters { w.resume() }
    waiters = []
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failure = error.localizedDescription
    finish()
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    failure = error.localizedDescription
    finish()
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    failure = "웹 보기 프로세스가 끝났습니다 (메모리나 멈춤)"
    finish()
  }
}
