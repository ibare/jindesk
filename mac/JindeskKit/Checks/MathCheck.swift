// 수식 검사: 앱 번들의 KaTeX 를 JavaScriptCore 로 돌려 파싱한다 (PAGES.md 의 글 블록).
// 렌더러가 그리는 KaTeX 와 같은 파일이므로, 여기서 통과한 수식은 화면에서도 그려진다.
import Foundation
import JavaScriptCore

public final class MathChecker: @unchecked Sendable {
  private let lock = NSLock()
  private let context: JSContext
  private let check: JSValue

  // katex.min.js 를 읽지 못하면 nil
  public init?(katex: URL) {
    guard let source = try? String(contentsOf: katex, encoding: .utf8), let context = JSContext() else { return nil }
    context.evaluateScript(source)
    let fn = context.evaluateScript(
      """
      (function (tex, display) {
        try {
          katex.renderToString(tex, { displayMode: display, throwOnError: true, strict: "ignore", trust: false, maxExpand: 200 });
          return "";
        } catch (e) {
          return String(e && e.message ? e.message : e);
        }
      })
      """)
    guard let fn, !fn.isUndefined, context.exception == nil, context.objectForKeyedSubscript("katex")?.isUndefined == false else { return nil }
    self.context = context
    check = fn
  }

  // 틀렸으면 KaTeX 의 오류 글, 맞으면 nil
  public func problem(_ tex: String, display: Bool) -> String? {
    lock.withLock {
      guard let r = check.call(withArguments: [tex, display])?.toString() else { return "수식을 검사하지 못했습니다" }
      return r.isEmpty ? nil : r
    }
  }

  // 글 속의 수식 (\( … \), \[ … \])을 모두 본다
  public func problems(inText text: String, field: String) -> [String] {
    TexText.segments(text).compactMap { s in
      problem(s.tex, display: s.display).map { "\(field): 수식을 그릴 수 없습니다 (\(s.display ? "\\[" : "\\(")\(FileOps.prefix(s.tex, 80))…): \($0)" }
    }
  }
}
