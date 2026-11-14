import Foundation
import JavaScriptCore
import Testing

// 마크다운 복사 (PAGES.md 의 마크다운 복사): 렌더러(renderer/page.js)가 단위 하나를 마크다운으로 바꾼다.
// DOM 없이 JavaScriptCore 로 렌더러를 불러 window.jindesk.markdown 을 부른다. 단위는 페이지 조합(PageComposer)이 넘기는 모양이다.
@Suite struct RendererCopyTests {
  // window.jindesk 의 함수 하나를 부른다
  static func call(_ name: String, _ arguments: [Any]) throws -> String {
    let context = try #require(JSContext())
    var error: String?
    context.exceptionHandler = { _, e in error = e?.toString() }
    context.evaluateScript("var window = { addEventListener: function () {} }; var document = { addEventListener: function () {} };")
    context.evaluateScript(try String(contentsOf: repoRoot.appending(path: "renderer/page.js"), encoding: .utf8))
    let result = context.evaluateScript("window.jindesk.\(name)")?.call(withArguments: arguments)
    #expect(error == nil, "\(error ?? "")")
    return try #require(result?.toString())
  }

  static func markdown(_ unit: [String: Any], answer: Bool = false) throws -> String {
    try call("markdown", [unit, ["answer": answer]])
  }

  @Test func 문단은_원문_표기에_수식만_달러로_바꾼다() throws {
    let text = """
      Without **air resistance**, the *horizontal* velocity stays constant and \\(a = g\\).
      The range is
      \\[ R = \\frac{v^2 \\sin 2\\theta}{g} \\]

      - first point with \\( t \\)
      • second point
      """
    let md = try Self.markdown(["id": "p1", "kind": "para", "prov": "source", "text": text, "ko": "공기 저항이 없으면", "src": [["label": "slides · 12"]]])
    #expect(
      md == """
        Without **air resistance**, the *horizontal* velocity stays constant and $a = g$.
        The range is
        $$R = \\frac{v^2 \\sin 2\\theta}{g}$$

        - first point with $t$
        - second point
        """)
    // 한국어와 출처 칩, 자료 표시는 넣지 않는다
    #expect(!md.contains("공기"))
    #expect(!md.contains("slides"))
    #expect(!md.contains("자료"))
  }

  @Test func 수식_밖의_달러는_수식으로_읽히지_않게_쓴다() throws {
    let md = try Self.markdown(["id": "p2", "kind": "para", "text": "A ticket costs $5, so \\(n\\) tickets cost $5n."])
    #expect(md == "A ticket costs \\$5, so $n$ tickets cost \\$5n.")
  }

  @Test func 강조_상자는_이름표를_굵게_단다() throws {
    let md = try Self.markdown(["id": "n3", "kind": "note", "note": "misconception", "text": "Mass is not weight."])
    #expect(md == "**Common mistake**\n\nMass is not weight.")
  }

  @Test func 풀이_단계는_수식과_이유다() throws {
    let md = try Self.markdown(["id": "s5", "kind": "step", "parent": "b4", "tex": " x = v_0 t ", "text": "Horizontal velocity is constant."])
    #expect(md == "$$x = v_0 t$$\n\nHorizontal velocity is constant.")
  }

  @Test func 그림은_제목과_설명이다() throws {
    let unit: [String: Any] = [
      "id": "b2", "kind": "block", "figure": ["src": "jindesk-page://figure/figures/b2-r1.html?c=x", "title": "Launch at different angles"],
      "caption": "Complementary angles land at the same place.", "ko": "여각은 같은 곳에 떨어진다.",
    ]
    #expect(try Self.markdown(unit) == "**Figure: Launch at different angles**\n\nComplementary angles land at the same place.")
  }

  @Test func 확인_문제의_답은_펼쳐_두었을_때만_넣는다() throws {
    let unit: [String: Any] = [
      "id": "c6", "kind": "check", "prov": "added", "text": "Find \\(t\\) when \\(h = 0\\).", "answer": "\\(t = 2\\) s", "solution": "Set \\(h = 0\\) and solve.",
    ]
    #expect(try Self.markdown(unit) == "**Check**\n\nFind $t$ when $h = 0$.")
    #expect(try Self.markdown(unit, answer: true) == "**Check**\n\nFind $t$ when $h = 0$.\n\n**Answer:** $t = 2$ s\n\nSet $h = 0$ and solve.")
  }

  // 페이지 전체 (DECISIONS.md 51): 영어 제목과, 단위 끝에 복사 단추가 있는 단위에 수식 블록, 풀이 블록 제목, 이유가 없는 단계의 수식을 더해 페이지 차례대로
  @Test func 페이지_전체는_제목과_단위와_수식_블록과_풀이_제목을_차례대로_잇는다() throws {
    let page: [String: Any] = [
      "concept": "physics/a.1/projectile-motion", "title": "Projectile motion", "titleKo": "투사체 운동",
      "units": [
        ["id": "p1", "kind": "para", "text": "Gravity gives \\(g\\).", "ko": "중력은 g 를 준다."],
        // 수식 블록과 풀이 블록 제목에는 단위 단추가 없지만 페이지 복사에는 넣는다
        ["id": "b2", "kind": "block", "tex": " v = u + at "],
        ["id": "b3", "kind": "block", "derivation": ["title": "Find the range for \\(\\theta = 45^\\circ\\)"]],
        ["id": "s4", "kind": "step", "parent": "b3", "tex": "x = u t", "text": "Constant velocity."],
        ["id": "s5", "kind": "step", "parent": "b3", "tex": "R = 20"],
        ["id": "n6", "kind": "note", "note": "key-idea", "text": "Solve each direction separately."],
        // 설명이 없는 그림에는 단추가 없다
        ["id": "b7", "kind": "block", "figure": ["src": "x", "title": "Paths"], "caption": "Compare the paths."],
        ["id": "b8", "kind": "block", "figure": ["src": "y", "title": "No caption"]],
        ["id": "c9", "kind": "check", "text": "Find \\(t\\).", "answer": "2 s"],
        ["id": "c10", "kind": "check", "text": "Find \\(R\\).", "answer": "20 m"],
        // 풀이 블록 밖에 떨어진 단계는 그리지 않는다
        ["id": "s11", "kind": "step", "parent": "b3", "tex": "y = 0", "text": "Lands."],
      ],
    ]
    let md = try Self.call("pageMarkdown", [page, ["c10"]])
    #expect(
      md == [
        "# Projectile motion",
        "Gravity gives $g$.",
        "$$v = u + at$$",
        "**Worked solution: Find the range for $\\theta = 45^\\circ$**",
        "$$x = u t$$\n\nConstant velocity.",
        // 이유가 없는 단계도 수식은 넣는다
        "$$R = 20$$",
        "**Key idea**\n\nSolve each direction separately.",
        "**Figure: Paths**\n\nCompare the paths.",
        "**Check**\n\nFind $t$.",
        "**Check**\n\nFind $R$.\n\n**Answer:** 20 m",
      ].joined(separator: "\n\n"))
    #expect(!md.contains("투사체") && !md.contains("중력"))
  }
}
