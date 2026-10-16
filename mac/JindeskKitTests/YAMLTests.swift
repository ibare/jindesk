import Foundation
import Testing
@testable import JindeskKit

@Suite struct YAMLTests {
  @Test func YAML_1_2_core_규칙으로_해석한다() throws {
    let value = try YAML.parse(
      """
      a: yes
      b: no
      c: 010
      d: 0o17
      e: "12:30"
      f: ~
      g: 1.5
      h: true
      i: "true"
      """)
    #expect(value["a"] == .string("yes"))
    #expect(value["b"] == .string("no"))
    #expect(value["c"] == .int(10))
    #expect(value["d"] == .int(15))
    #expect(value["e"] == .string("12:30"))
    #expect(value["f"] == .null)
    #expect(value["g"] == .double(1.5))
    #expect(value["h"] == .bool(true))
    // 따옴표로 쓴 값은 늘 문자열이다
    #expect(value["i"] == .string("true"))
  }

  @Test func meta_schema_yaml_을_DATA_md_의_모양_그대로_쓴다() {
    let file = SchemaFile(
      schema: 3, created: "2026-09-01T20:10:00+09:00", lastOpenedBy: AppVersion(app: "0.4.0", build: "41"),
      history: [
        .init(from: 1, to: 2, app: "0.2.0", at: "2026-09-20T21:00:00+09:00", kind: "code", backup: "Jindesk-마이그레이션-1-2.zip"),
        .init(from: 2, to: 3, app: "0.4.0", at: "2026-10-12T19:30:00+09:00", kind: "code+agent", backup: "Jindesk-마이그레이션-2-3.zip"),
      ])
    #expect(
      YAML.stringify(file.yaml) == """
        kind: "schema"
        v: 1
        schema: 3
        created: "2026-09-01T20:10:00+09:00"
        last_opened_by: { app: "0.4.0", build: "41" }
        history:
          - { from: 1, to: 2, app: "0.2.0", at: "2026-09-20T21:00:00+09:00", kind: "code", backup: "Jindesk-마이그레이션-1-2.zip" }
          - { from: 2, to: 3, app: "0.4.0", at: "2026-10-12T19:30:00+09:00", kind: "code+agent", backup: "Jindesk-마이그레이션-2-3.zip" }

        """)
  }

  @Test func 여러_줄_글은_블록으로_맵_목록은_블록으로_작은_맵은_한_줄로_쓴다() {
    let unit: YAMLMap = [
      "id": "p1",
      "rev": 2,
      "text": "Without air resistance, no force acts horizontally.\nSolve the two directions separately \\(g\\).\n",
      "conditions": ["no air resistance"],
      "claims": [["id": "c1", "text": "no horizontal force", "src": ["20260903-3fa2c1d0#p12"]]],
    ]
    let block = YAMLMap([("type", "figure"), ("v", 1), ("code", "figures/b2-r1.html")], style: .block)
    let page: YAMLMap = ["kind": "page", "v": 1, "units": [.map(unit), ["id": "b2", "block": .map(block)]], "empty": [], "none": .map([:])]
    #expect(
      YAML.stringify(page) == """
        kind: "page"
        v: 1
        units:
          - id: "p1"
            rev: 2
            text: |
              Without air resistance, no force acts horizontally.
              Solve the two directions separately \\(g\\).
            conditions: ["no air resistance"]
            claims:
              - { id: "c1", text: "no horizontal force", src: ["20260903-3fa2c1d0#p12"] }
          - id: "b2"
            block:
              type: "figure"
              v: 1
              code: "figures/b2-r1.html"
        empty: []
        none: {}

        """)
  }

  @Test(arguments: [
    "한 줄", "no", "12:30", "010", "", "  앞 공백", "끝 공백  ", "따옴표 \" 와 \\ 백슬래시", "탭\t글자", "\r 캐리지", "#샵", "- 줄표", "a: b",
    "끝 줄바꿈 하나\n", "끝 줄바꿈 없음\n둘째 줄", "끝 줄바꿈 둘\n\n", "\n앞 빈 줄", "  들여 쓴\n  둘째 줄\n", "\n  빈 줄 뒤 들여쓰기", "   \n공백만 있는 첫 줄",
    "\n", "\n\n", "가운데\n\n빈 줄\n", "\\frac{1}{2} 와 \\(x\\)\n",
  ])
  func 어떤_글이든_쓴_뒤_다시_읽으면_같다(text: String) throws {
    let map: YAMLMap = ["kind": "t", "v": 1, "text": .string(text), "list": [.string(text), "x"], "nested": ["inner": .string(text)]]
    let parsed = try YAML.parse(YAML.stringify(map))
    #expect(parsed["text"] == .string(text))
    #expect(parsed["list"] == [.string(text), "x"])
    #expect(parsed["nested"]?["inner"] == .string(text))
  }

  @Test func 같은_값은_늘_같은_바이트이고_NFC_로_쓴다() throws {
    // "한" 을 자모로 풀어 쓴 글 (NFD)
    let decomposed = "한".decomposedStringWithCanonicalMapping
    #expect(decomposed.unicodeScalars.count == 3)
    let out = YAML.stringify(["kind": "t", "v": 1, "word": .string(decomposed)])
    #expect(out == "kind: \"t\"\nv: 1\nword: \"한\"\n")
    #expect(out.unicodeScalars.contains("\u{D55C}"))
    // 정수 모양의 실수는 실수로 남는다
    #expect(YAML.stringify(["num": .double(5)]) == "num: 5.0\n")
    #expect(try YAML.parse("num: 5.0\n")["num"] == .double(5))
  }

  @Test func 키는_맨_글자로_쓰고_다른_타입으로_읽힐_키는_따옴표로_쓴다() throws {
    let out = YAML.stringify(["p1": 1, "yes": 2, "ahl-5.12": 3, "한글 키": 4])
    #expect(out == "p1: 1\n\"yes\": 2\nahl-5.12: 3\n\"한글 키\": 4\n")
    let back = try YAML.parse(out)
    #expect(back.map?.keys == ["p1", "yes", "ahl-5.12", "한글 키"])
  }
}

@Suite struct JSONTextTests {
  @Test func 기록_JSON_은_키를_정렬하고_2칸_들여쓴다() {
    let value: JSONValue = .object(["b": .number(1), "a": .array([.string("x"), .number(1.5)]), "c": .object([:])])
    #expect(JSONText.record(value) == "{\n  \"a\": [\n    \"x\",\n    1.5\n  ],\n  \"b\": 1,\n  \"c\": {}\n}\n")
    #expect(JSONText.line(value) == #"{"a":["x",1.5],"b":1,"c":{}}"#)
  }
}
