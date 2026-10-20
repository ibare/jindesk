import Foundation
import PDFKit
import Testing
@testable import JindeskKit

let repoKatex = repoRoot.appending(path: "renderer/katex/katex.min.js")

extension URL {
  // 부모 폴더를 만들고 자기를 돌려준다 (시험에서 파일을 바로 쓸 때)
  func creatingParent() throws -> URL {
    try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
    return self
  }
}

@Suite struct VendorStoreTests {
  @Test func 주소를_vendor_경로로_바꾸고_질의는_해시로_가른다() {
    let store = VendorStore(root: URL(fileURLWithPath: "/v"))
    #expect(store.file(for: URL(string: "https://cdn.jsdelivr.net/npm/d3@7.9.0/+esm")!)?.path == "/v/cdn.jsdelivr.net/npm/d3@7.9.0/+esm")
    #expect(store.file(for: URL(string: "https://unpkg.com/x/")!)?.path == "/v/unpkg.com/x/index")
    let q = store.file(for: URL(string: "https://a.com/lib.js?v=2")!)?.lastPathComponent ?? ""
    #expect(q.hasPrefix("lib.js@q-") && q.count == "lib.js@q-".count + 8)
    #expect(store.file(for: URL(string: "https://a.com/../../etc/passwd")!)?.path == "/v/a.com/etc/passwd")
    #expect(VendorStore.original(URL(string: "jindesk-vendor://cdn.jsdelivr.net/npm/d3@7")!)?.absoluteString == "https://cdn.jsdelivr.net/npm/d3@7")
  }

  @Test func 블록_틀은_https_주소를_받아_둔_사본의_주소로_바꾼다() {
    let html = FigureFrame.compose(#"<script type="module">import * as d3 from "https://cdn.jsdelivr.net/npm/d3@7.9.0/+esm";</script>"#)
    #expect(html.contains("jindesk-vendor://cdn.jsdelivr.net/npm/d3@7.9.0/+esm"))
    #expect(!html.contains("https://"))
    #expect(html.contains("jindesk-page://app/parts/parts.js"))
  }
}

@Suite struct TextCheckTests {
  @Test func 한글과_한자_일본어를_가린다() {
    #expect(TextChecks.hasHangul("log 는"))
    #expect(!TextChecks.hasHangul("logarithm"))
    #expect(TextChecks.hasHanOrKana("指数"))
    #expect(TextChecks.hasHanOrKana("ログ"))
    #expect(!TextChecks.hasHanOrKana("로그와 log"))
    #expect(TextChecks.englishProblems("The base 밑", field: "f").count == 1)
    #expect(TextChecks.koreanProblems("밑은 a 다", field: "f").isEmpty)
    #expect(TextChecks.koreanProblems("the base", field: "f").count == 1)
  }

  @Test func 원래_자료가_있어야_통하는_말을_찾는다() {
    #expect(!TextChecks.materialPhrases("As shown on the slide, the base is 2.").isEmpty)
    #expect(!TextChecks.materialPhrases("See the diagram above.").isEmpty)
    #expect(!TextChecks.materialPhrases("This appears on slide 3.").isEmpty)
    #expect(TextChecks.materialPhrases("The graph of \\(y = 2^x\\) passes through \\((0, 1)\\).").isEmpty)
  }

  @Test func 글_속_수식을_나누고_숫자를_뽑는다() {
    let s = "If \\(a^2 = 9\\) then \\[a = \\pm 3\\] for 1,000 cases and 2.5 more"
    #expect(TexText.segments(s).map(\.tex) == ["a^2 = 9", "a = \\pm 3"])
    #expect(TexText.segments(s).map(\.display) == [false, true])
    #expect(TexText.numbers(s) == ["1000", "2.5"])
    #expect(!TexText.strip(s).contains("pm"))
  }

  @Test func KaTeX_로_수식을_파싱한다() throws {
    let math = try #require(MathChecker(katex: repoKatex))
    #expect(math.problem("\\frac{a}{b} + \\log_2 8", display: false) == nil)
    #expect(math.problem("\\frac{a}{b", display: false) != nil)
    #expect(math.problem("\\notacommand x", display: true) != nil)
    #expect(math.problems(inText: "ok \\(x^2\\) bad \\(\\frac{1}{\\)", field: "body").count == 1)
  }

  @Test func 뜻_해시는_줄_끝_공백과_끝_줄바꿈에_흔들리지_않는다() {
    let a = ConceptUnit(id: "u1", text: "Line one  \nLine two\n", conditions: [], claims: [])
    let b = ConceptUnit(id: "u1", text: "Line one\nLine two", conditions: [], claims: [])
    let c = ConceptUnit(id: "u1", text: "Line one\nLine three", conditions: [], claims: [])
    #expect(a.hash == b.hash)
    #expect(a.hash != c.hash)
  }
}

@Suite struct GlossaryTests {
  @Test func 표기만_다른_용어는_다른_이름으로_넣고_한국어가_다르면_알린다() {
    var g = Glossary(terms: [GlossaryTerm(en: "logarithm", ko: "로그", subjects: ["math"])])
    let r = g.merge([("Logarithm", "로그"), ("exponent", "지수"), ("log-arithm", "대수")], subject: "math")
    #expect(r.added == ["exponent"])
    #expect(r.aliased == ["Logarithm", "log-arithm"])
    #expect(r.conflicts.count == 1)
    #expect(g.term("LOGARITHM")?.ko == "로그")
  }

  @Test func 다른_과목에만_달린_용어는_한국어가_다르면_이_과목에_묶지_않는다() {
    var g = Glossary(terms: [GlossaryTerm(en: "reflection", ko: "대칭이동", subjects: ["extended-mathematics"])])
    let r = g.merge([("reflection", "성찰")], subject: "spanish")
    #expect(r.conflicts.count == 1)
    #expect(g.term("reflection")?.subjects == ["extended-mathematics"])
    #expect(g.of(subject: "spanish").terms.isEmpty)
    // 한국어가 같으면 이 과목에도 쓴다
    _ = g.merge([("reflection", "대칭이동")], subject: "physics")
    #expect(g.term("reflection")?.subjects == ["extended-mathematics", "physics"])
  }
}

@Suite struct ReadingCheckTests {
  func meta(pages: Int, buildUps: [[Int]] = []) -> SourceMeta {
    SourceMeta(
      id: "20261017-aaaabbbb", original: .init(name: "x.pdf", bytes: 1, sha256: "aaaabbbbccccdddd"), received: "2026-10-17T10:00:00+09:00", converted: nil,
      pages: pages, textLayer: .init(by: "pdfkit", pagesWithText: pages, ocrPages: []), buildUps: buildUps)
  }

  func write(_ out: URL, _ rel: String, _ value: Any) throws {
    let url = out.appending(path: rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let s = value as? String { try s.write(to: url, atomically: true, encoding: .utf8) } else {
      try JSONSerialization.data(withJSONObject: value).write(to: url)
    }
  }

  // 묶음 하나의 결과: out/bundle.json, out/sources/<자료 id>.json, out/report.md
  func basics(_ out: URL, sources: [String: Any] = [:], bundle: Any = ["title": "Laws of indices"]) throws {
    try write(out, "bundle.json", bundle)
    try write(out, "report.md", "# Laws of indices\n\n지수 법칙 자료다.\n")
    for (id, value) in sources { try write(out, "sources/\(id).json", value) }
  }

  let slides = "20261017-aaaabbbb"
  let worksheet = "20261017-ccccdddd"

  func meta(_ id: String, pages: Int) -> SourceMeta {
    SourceMeta(
      id: id, original: .init(name: "\(id).pdf", bytes: 1, sha256: id), received: "2026-10-17T10:00:00+09:00", converted: nil, pages: pages,
      textLayer: .init(by: "pdfkit", pagesWithText: pages, ocrPages: []), buildUps: [])
  }

  @Test func 맞는_엔트리는_받고_틀린_엔트리는_까닭과_함께_뺀다() throws {
    let out = TempPlace().root.appending(path: "out")
    try basics(out, sources: [slides: ["title": "Laws of indices", "kind": "lecture slides", "assessment": false, "skipped_pages": [["page": 1, "reason": "표지"]]]])
    try write(
      out, "entries/good.json",
      ["slug": "laws-of-indices", "title": "Laws of indices", "body": "Add exponents: \\(a^m a^n = a^{m+n}\\).", "claims": [["text": "\\(a^m a^n = a^{m+n}\\)", "pages": [2]]]])
    try write(out, "entries/korean.json", ["title": "지수 법칙", "body": "x", "claims": [["text": "y", "pages": [2]]]])
    try write(out, "entries/badpage.json", ["title": "Zero exponent", "body": "\\(a^0 = 1\\)", "claims": [["text": "\\(a^0 = 1\\)", "pages": [9]]]])
    try write(out, "entries/slide.json", ["title": "Negative exponent", "body": "As shown on the slide, \\(a^{-1}\\).", "claims": [["text": "c", "pages": [2]]]])
    let checked = SourceReading.check(out: out, sources: [meta(pages: 3)], math: MathChecker(katex: repoKatex))
    #expect(checked.problems.isEmpty)
    #expect(checked.entries.map(\.slug) == ["laws-of-indices"])
    #expect(Set(checked.rejected.map(\.file)) == ["korean.json", "badpage.json", "slide.json"])
    #expect(checked.notes[slides]?.skipped == [1])
    #expect(checked.bundleTitle == "Laws of indices")
  }

  @Test func 묶음의_엔트리는_주장마다_자료와_쪽을_달고_자료마다_쪽을_모은다() throws {
    let out = TempPlace().root.appending(path: "out")
    let note: [String: Any] = ["title": "T", "kind": "worksheet", "assessment": false, "skipped_pages": []]
    try basics(out, sources: [slides: note, worksheet: note])
    try write(
      out, "entries/quartiles.json",
      [
        "slug": "quartiles", "title": "Quartiles", "body": "The quartiles split ordered data into four equal parts.",
        "claims": [["text": "The median splits the data in half.", "source": slides, "pages": [3]], ["text": "The upper quartile of 1, 2, 3, 4, 5, 6, 7 is 6.", "source": worksheet, "pages": [5]]],
        "pages": [slides: [3, 4]],
      ])
    // 자료를 빠뜨리거나 읽을 자료 표에 없는 자료를 쓰면 그 엔트리만 뺀다
    try write(out, "entries/nosource.json", ["title": "Range", "body": "b", "claims": [["text": "c", "pages": [1]]]])
    try write(out, "entries/other.json", ["title": "Mode", "body": "b", "claims": [["text": "c", "source": "20261001-99998888", "pages": [1]]]])
    let checked = SourceReading.check(out: out, sources: [meta(slides, pages: 10), meta(worksheet, pages: 6)], math: nil)
    #expect(checked.problems.isEmpty, "\(checked.problems)")
    let q = try #require(checked.entries.first)
    #expect(q.sources == [slides, worksheet])
    #expect(q.pages == [slides: [3, 4], worksheet: [5]])
    #expect(Set(checked.rejected.map(\.file)) == ["nosource.json", "other.json"])
    // 자료마다 결과가 있어야 한다
    FileOps.remove(out.appending(path: "sources/\(worksheet).json"))
    #expect(SourceReading.check(out: out, sources: [meta(slides, pages: 10), meta(worksheet, pages: 6)], math: nil).problems.contains { $0.contains(worksheet) })
  }

  @Test func 예제도_자료와_쪽을_달아야_한다() throws {
    let out = TempPlace().root.appending(path: "out")
    let note: [String: Any] = ["title": "T", "kind": "worksheet", "assessment": false, "skipped_pages": []]
    try basics(out, sources: [slides: note, worksheet: note])
    let claim: [String: Any] = ["text": "\\(\\log(ab) = \\log a + \\log b\\)", "source": slides, "pages": [3]]
    try write(
      out, "entries/good.json",
      ["title": "Laws of logarithms", "body": "b", "claims": [claim], "examples": [["text": "\\(\\log 2 + \\log 7 = \\log 14\\)", "source": worksheet, "pages": [1, 2]]]])
    try write(out, "entries/plain.json", ["title": "Laws again", "body": "b", "claims": [claim], "examples": ["\\(\\log 6 - \\log 3 = \\log 2\\)"]])
    try write(out, "entries/nopage.json", ["title": "Laws third", "body": "b", "claims": [claim], "examples": [["text": "x", "source": worksheet, "pages": [9]]]])
    let checked = SourceReading.check(out: out, sources: [meta(slides, pages: 10), meta(worksheet, pages: 2)], math: nil)
    #expect(checked.entries.map(\.file) == ["good.json"])
    #expect(Set(checked.rejected.map(\.file)) == ["plain.json", "nopage.json"])
    let good = try #require(checked.entries.first)
    // 예제의 쪽도 그 자료의 쪽에 든다
    #expect(good.pages == [slides: [3], worksheet: [1, 2]])
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let placed = try SourceReading.place([good], subject: "math", data: t.data, jobID: "j", provenance: [:])
    #expect(placed[0].examples == [EntryExample(text: "\\(\\log 2 + \\log 7 = \\log 14\\)", src: ["\(worksheet)#p1", "\(worksheet)#p2"])])
    // 예제의 출처도 엔트리의 출처라 개념 정리가 주장으로 쓸 수 있다
    #expect(placed[0].refs.contains("\(worksheet)#p2"))
    #expect(try Entry.parse(try String(contentsOf: t.data.entryFile(placed[0].id), encoding: .utf8)) == placed[0])
  }

  @Test func 시험에_떨어진_엔트리는_버리지_않고_보류로_넣는다() throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let out = t.root.appending(path: "out")
    try basics(out, sources: [slides: ["title": "T", "kind": "worksheet", "assessment": false, "skipped_pages": []]])
    try write(out, "entries/tree.json", ["slug": "tree-diagrams", "title": "Tree diagrams", "item": "Probability", "body": "b", "claims": [["text": "c", "pages": [2]]]])
    let checked = SourceReading.check(out: out, sources: [meta(pages: 3)], math: nil)
    let placed = try SourceReading.place(
      checked.entries, held: ["tree.json": "학생 독자 시험 실패: 무엇을 곱하는지 모른다"], subject: "math", data: t.data, jobID: "j", provenance: [:])
    #expect(placed.first?.held?.hasPrefix("학생 독자 시험 실패") == true)
    let reread = try Entry.parse(try String(contentsOf: t.data.entryFile(placed[0].id), encoding: .utf8))
    #expect(reread == placed[0])
    #expect(ConceptCuration.heldEntries(t.data, subject: "math").map(\.entry.id) == [placed[0].id])
  }

  @Test func 요약과_엔트리가_없으면_작업_전체가_틀린다() throws {
    let out = TempPlace().root.appending(path: "out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let checked = SourceReading.check(out: out, sources: [meta(pages: 2)], math: nil)
    // bundle.json, sources/<자료 id>.json, report.md, 엔트리
    #expect(checked.problems.count == 4)
  }

  @Test func 자료가_밝힌_학습_목표를_뽑고_없는_쪽은_틀린다() throws {
    let out = TempPlace().root.appending(path: "out")
    try basics(
      out,
      sources: [
        slides: [
          "title": "Laws of indices", "kind": "lecture slides", "assessment": false, "skipped_pages": [["page": 1, "reason": "학습 목표"]],
          "outcomes": [["text": "Can multiply powers with the same base.", "pages": [1]], ["text": "Can explain the zero exponent.", "pages": [9]]],
        ]
      ])
    try write(
      out, "entries/good.json",
      ["slug": "laws-of-indices", "title": "Laws of indices", "body": "Add exponents: \\(a^m a^n = a^{m+n}\\).", "claims": [["text": "\\(a^m a^n = a^{m+n}\\)", "pages": [2]]]])
    let checked = SourceReading.check(out: out, sources: [meta(pages: 3)], math: nil)
    #expect(checked.notes[slides]?.outcomes.map(\.text) == ["Can multiply powers with the same base.", "Can explain the zero exponent."])
    #expect(checked.problems == ["out/sources/\(slides).json outcomes[1].pages: 없는 쪽입니다 (9)"])
  }

  @Test func 개념이_없는_자료는_모든_쪽을_까닭과_함께_건너뛰면_엔트리가_없어도_된다() throws {
    let out = TempPlace().root.appending(path: "out")
    try basics(out, sources: [slides: ["title": "Unit plan", "kind": "unit plan", "assessment": false, "skipped_pages": [["page": 1, "reason": "단원 계획"]]]])
    #expect(SourceReading.check(out: out, sources: [meta(pages: 2)], math: nil).problems.count == 1)
    try basics(
      out, sources: [slides: ["title": "Unit plan", "kind": "unit plan", "assessment": false, "skipped_pages": [["page": 1, "reason": "단원 계획"], ["page": 2, "reason": "평가 일정"]]]])
    #expect(SourceReading.check(out: out, sources: [meta(pages: 2)], math: nil).problems.isEmpty)
  }

  @Test func 읽은_쪽을_세고_이어_채운_묶음은_마지막_쪽으로_센다() {
    let c = Coverage.make(
      meta: meta(pages: 6, buildUps: [[2, 3, 4]]), read: ["input/pages/0001.png", "input/pages/0004.png", "input/index.md"], cited: [4], skipped: [6])
    #expect(c.read == [1, 4])
    #expect(c.unread == [5])
  }
}

@Suite struct CurationCheckTests {
  func entry(_ id: String, refs: [String]) -> Entry {
    Entry(
      id: id, subject: "math", item: nil, itemProposed: "Exponents", title: "T", sources: [EntrySource(source: "20261017-aaaabbbb", pages: [1])],
      claims: [EntryClaim(text: "c", src: refs)], symbols: [], examples: [], misconceptions: [], body: "b", recorded: "", provenance: YAMLMap([]))
  }

  func existing() -> Concept {
    Concept(
      cid: ConceptID(subject: "math", item: "unplaced", slug: "laws-of-indices"), title: "Laws of indices", itemProposed: "Exponents", occurrences: [],
      symbols: [], nextID: 3,
      units: [
        ConceptUnit(id: "u1", text: "Old one", conditions: [], claims: [UnitClaim(id: "c1", text: "x", src: ["20261010-11112222#p3"])]),
        ConceptUnit(id: "u2", text: "Old two", conditions: [], claims: []),
      ], provenance: YAMLMap([]))
  }

  func input() -> ConceptCuration.Input {
    ConceptCuration.Input(
      subject: "math", entries: [("e01", entry("math/unplaced/a", refs: ["20261017-aaaabbbb#p1"])), ("e02", entry("math/unplaced/b", refs: ["20261017-aaaabbbb#p2"]))],
      concepts: [("k01", existing())], conceptHashes: [:])
  }

  func plan(_ value: Any) throws -> URL {
    let out = TempPlace().root.appending(path: "out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value).write(to: out.appending(path: "plan.json"))
    return out
  }

  @Test func 엔트리가_빠지거나_새_출처를_만들거나_기존_단위를_까닭_없이_빼면_틀린다() throws {
    let out = try plan([
      "concepts": [
        [
          "concept": "k01", "entries": ["e01"],
          "units": [["id": "u1", "text": "Old one", "claims": [["text": "x", "src": ["20261010-11112222#p3"]]]], ["id": NSNull(), "text": "New", "claims": [["text": "y", "src": ["20261017-aaaabbbb#p7"]]]]],
        ]
      ], "held": [],
    ])
    let c = ConceptCuration.check(out: out, input: input(), math: nil)
    #expect(c.plan == nil)
    #expect(c.problems.contains { $0.contains("e02") })
    #expect(c.problems.contains { $0.contains("#p7") })
    #expect(c.problems.contains { $0.contains("u2") })
  }

  @Test func 맞는_계획을_반영하면_기존_id_를_지키고_새_단위에_id_를_붙인다() throws {
    let out = try plan([
      "concepts": [
        [
          "concept": "k01", "entries": ["e01"],
          "units": [
            ["id": "u1", "text": "Old one, revised", "claims": [["text": "x", "src": ["20261010-11112222#p3"]]]],
            ["id": NSNull(), "text": "New from e01", "claims": [["text": "y", "src": ["20261017-aaaabbbb#p1"]]]],
          ],
          "removed_units": [["id": "u2", "reason": "u1 에 합쳤다"]],
        ],
        ["concept": NSNull(), "slug": "laws-of-indices", "title": "Zero exponent", "entries": ["e02"], "units": [["id": NSNull(), "text": "\\(a^0 = 1\\)", "claims": [["text": "z", "src": ["20261017-aaaabbbb#p2"]]]]]],
      ],
      "held": [],
    ])
    let input = input()
    let c = ConceptCuration.check(out: out, input: input, math: MathChecker(katex: repoKatex))
    #expect(c.problems.isEmpty)
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let written = try ConceptCuration.apply(try #require(c.plan), input: input, data: t.data, provenance: ["job": "j"])
    #expect(written[0].units.map(\.id) == ["u1", "u3"])
    #expect(written[0].nextID == 4)
    #expect(written[0].occurrences.map(\.entry) == ["math/unplaced/a"])
    // 같은 slug 의 새 개념은 뒤에 수를 붙인다
    #expect(written[1].id == "math/unplaced/laws-of-indices-2")
    #expect(written[1].units.map(\.id) == ["u1"])
    let reread = try Concept.read(ConceptFolder(written[1].cid, in: t.data).concept)
    #expect(reread == written[1])
  }
}

extension CurationCheckTests {
  // 엔트리 하나를 여러 개념이 나눠 쓴다 (DECISIONS.md 38)
  @Test func 엔트리_하나를_여러_개념이_나눠_쓰고_빠진_주장은_부드럽게_알린다() throws {
    let big = Entry(
      id: "math/unplaced/logs", subject: "math", item: nil, itemProposed: "Logarithms", title: "Logarithms", sources: [EntrySource(source: "20261017-aaaabbbb", pages: [1, 2, 3])],
      claims: [EntryClaim(text: "definition", src: ["20261017-aaaabbbb#p1"]), EntryClaim(text: "product law", src: ["20261017-aaaabbbb#p2"]), EntryClaim(text: "change of base", src: ["20261017-aaaabbbb#p3"])],
      symbols: [], examples: [], misconceptions: [], body: "b", recorded: "", provenance: YAMLMap([]))
    let input = ConceptCuration.Input(subject: "math", entries: [("e01", big)], concepts: [], conceptHashes: [:])
    func unit(_ text: String, _ page: Int) -> [String: Any] { ["id": NSNull(), "text": text, "claims": [["text": text, "src": ["20261017-aaaabbbb#p\(page)"]]]] }
    let split = try plan([
      "concepts": [
        ["concept": NSNull(), "slug": "definition-of-a-logarithm", "title": "Definition of a logarithm", "entries": ["e01"], "units": [unit("A logarithm is an index.", 1)]],
        ["concept": NSNull(), "slug": "laws-of-logarithms", "title": "Laws of logarithms", "entries": ["e01"], "units": [unit("The product law.", 2)]],
      ], "held": [],
    ])
    let c = ConceptCuration.check(out: split, input: input, math: nil)
    #expect(c.problems.isEmpty, "\(c.problems)")
    // 바꾸는 밑 공식(3쪽)이 어디에도 남지 않았다: 실패가 아니라 부드러운 문제다
    #expect(c.soft.count == 1 && c.soft[0].contains("change of base"))
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let written = try ConceptCuration.apply(try #require(c.plan), input: input, data: t.data, provenance: ["job": "j"])
    #expect(written.allSatisfy { $0.occurrences.map(\.entry) == ["math/unplaced/logs"] })
    // 개념과 보류에 함께 두면 틀린다
    let both = try plan([
      "concepts": [["concept": NSNull(), "slug": "a", "title": "A", "entries": ["e01"], "units": [unit("x", 1)]]],
      "held": [["entry": "e01", "reason": "일부만 개념이다"]],
    ])
    #expect(ConceptCuration.check(out: both, input: input, math: nil).problems.contains { $0.contains("개념과 보류에 함께") })
  }

  @Test func 너무_커진_개념을_나누면_옮긴_단위가_원래_출처를_쓰고_출현_목록이_따라간다() throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    // 기존 개념 k01 에 들어 있던 엔트리
    let old = Entry(
      id: "math/unplaced/old", subject: "math", item: nil, itemProposed: nil, title: "Old", sources: [EntrySource(source: "20261010-11112222", pages: [3])],
      claims: [EntryClaim(text: "x", src: ["20261010-11112222#p3"])], symbols: [], examples: [], misconceptions: [], body: "b", recorded: "", provenance: YAMLMap([]))
    try FileOps.write(old.markdown, to: t.data.entryFile(old.id))
    var k01 = existing()
    k01.occurrences = [Occurrence(entry: old.id, source: old.source, pages: [3])]
    let input = ConceptCuration.Input(
      subject: "math", entries: [("e01", entry("math/unplaced/a", refs: ["20261017-aaaabbbb#p1"])), ("e02", entry("math/unplaced/b", refs: ["20261017-aaaabbbb#p2"]))],
      concepts: [("k01", k01)], conceptHashes: [:])
    let out = try plan([
      "concepts": [
        [
          "concept": "k01", "entries": ["e01"],
          "units": [["id": "u2", "text": "Old two"], ["id": NSNull(), "text": "New", "claims": [["text": "y", "src": ["20261017-aaaabbbb#p1"]]]]],
          "removed_units": [["id": "u1", "reason": "definition-of-x 로 옮김"]],
        ],
        [
          "concept": NSNull(), "slug": "definition-of-x", "title": "Definition of x", "entries": ["e02"],
          "units": [
            ["id": NSNull(), "text": "Old one", "claims": [["text": "x", "src": ["20261010-11112222#p3"]]]],
            ["id": NSNull(), "text": "More", "claims": [["text": "z", "src": ["20261017-aaaabbbb#p2"]]]],
          ],
        ],
      ],
      "held": [],
    ])
    let c = ConceptCuration.check(out: out, input: input, math: nil)
    #expect(c.problems.isEmpty, "\(c.problems)")
    let written = try ConceptCuration.apply(try #require(c.plan), input: input, data: t.data, provenance: ["job": "j"])
    #expect(written[0].occurrences.map(\.entry) == ["math/unplaced/a"])
    #expect(Set(written[1].occurrences.map(\.entry)) == ["math/unplaced/b", "math/unplaced/old"])
  }
}

@Suite struct PageBuildTests {
  let concept = Concept(
    cid: ConceptID(subject: "math", item: "unplaced", slug: "laws-of-indices"), title: "Laws of indices", itemProposed: nil, occurrences: [], symbols: [],
    nextID: 3,
    units: [
      ConceptUnit(id: "u1", text: "One \\(a^m a^n = a^{m+n}\\)", conditions: [], claims: [UnitClaim(id: "c1", text: "x", src: ["20261017-aaaabbbb#p1"])]),
      ConceptUnit(id: "u2", text: "Two", conditions: [], claims: []),
    ], provenance: YAMLMap([]))

  func out(_ value: Any) throws -> URL {
    let out = TempPlace().root.appending(path: "out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value).write(to: out.appending(path: "page.json"))
    return out
  }

  @Test func 원문_단위마다_문단이_하나씩_있어야_한다() throws {
    let o = try out(["title_ko": "지수 법칙", "units": [["kind": "para", "from": "u1"], ["kind": "block", "from": "u1", "block": ["type": "figure"]]]])
    let c = PageBuild.check(out: o, concept: concept, math: nil)
    #expect(c.problems.contains { $0.contains("u2") })
    #expect(c.problems.contains { $0.contains("block.file") })
  }

  @Test func 풀이_블록은_단계마다_풀이_단위가_되고_계산이_틀리면_검사에서_걸린다() throws {
    let steps: [[String: Any]] = [
      ["tex": "2^x = 17", "why": "Start."], ["tex": "x = \\log_2 17", "why": "Log form.", "expr": "log(17, 2)"],
      ["tex": "x \\approx 4.09", "why": "Round.", "expr": "4.09"],
    ]
    let block: [String: Any] = ["type": "derivation", "title": "Solve \\(2^x = 17\\)", "steps": steps, "check": ["equation": "2^x = 17", "solution": ["x": "log(17, 2)"]]]
    let o = try out([
      "title_ko": "지수 법칙",
      "units": [
        ["kind": "para", "from": "u1"], ["kind": "block", "from": "u1", "block": block], ["kind": "para", "from": "u2"],
        ["kind": "check", "from": "u2", "question": "Find \\(\\log_2 8\\).", "answer": "3", "verify": ["expr": "log(8, 2)", "equals": "3"]],
      ],
    ])
    let c = PageBuild.check(out: o, concept: concept, math: MathChecker(katex: repoKatex))
    #expect(c.problems.isEmpty, "\(c.problems)")
    let built = PageBuild.assemble(try #require(c.draft), concept: concept, old: nil, provenance: ["job": "j"])
    #expect(built.page.units.map(\.id) == ["p1", "b2", "s3", "s4", "s5", "p6", "q7"])
    #expect(built.page.units[2].parent == "b2" && built.page.units[4].parent == "b2")
    #expect(built.page.units[6].prov == "added")

    var wrong = steps
    wrong[2]["expr"] = "4.2"
    let o2 = try out(["title_ko": "지수 법칙", "units": [["kind": "para", "from": "u1"], ["kind": "para", "from": "u2"], ["kind": "block", "from": "u1", "block": ["type": "derivation", "title": "T", "steps": wrong]]]])
    #expect(PageBuild.check(out: o2, concept: concept, math: nil).problems.contains { $0.contains("값이 다릅니다") })
  }

  @Test func 그림_블록은_조각_파일이_있어야_하고_다시_만들어도_코드가_같으면_판을_지킨다() throws {
    let o = try out([
      "title_ko": "지수 법칙",
      "units": [
        ["kind": "para", "from": "u1"], ["kind": "para", "from": "u2"],
        ["kind": "block", "from": "u1", "block": ["type": "figure", "file": "g.html", "title": "Graph"], "caption": "Drag it."],
        ["kind": "block", "from": "u2", "block": ["type": "figure", "file": "missing.html", "title": "그래프"]],
      ],
    ])
    try "<svg></svg>".write(to: o.appending(path: "figures/g.html").creatingParent(), atomically: true, encoding: .utf8)
    let bad = PageBuild.check(out: o, concept: concept, math: nil)
    #expect(bad.problems.count == 1)
    #expect(bad.problems.first?.contains("missing.html") == true)

    let o2 = try out([
      "title_ko": "지수 법칙",
      "units": [["kind": "para", "from": "u1"], ["kind": "para", "from": "u2"], ["kind": "block", "from": "u1", "block": ["type": "figure", "file": "g.html", "title": "Graph"], "caption": "Drag it."]],
    ])
    try "<svg></svg>".write(to: o2.appending(path: "figures/g.html").creatingParent(), atomically: true, encoding: .utf8)
    let draft = try #require(PageBuild.check(out: o2, concept: concept, math: nil).draft)
    let first = PageBuild.assemble(draft, concept: concept, old: nil, provenance: ["job": "j1"])
    #expect(first.figures.map(\.path) == ["figures/b3-r1.html"])
    let again = PageBuild.assemble(draft, concept: concept, old: first.page, provenance: ["job": "j2"])
    #expect(again.page.units[2].rev == 1)
    #expect(again.page.units[2].block?["code"]?.string == "figures/b3-r1.html")
    #expect(again.history.isEmpty)
  }

  @Test func 다시_만들면_같은_자리의_단위는_id_를_지키고_바뀐_것만_판을_올린다() throws {
    let o = try out([
      "title_ko": "지수 법칙",
      "units": [
        ["kind": "para", "from": "u1"], ["kind": "block", "from": "u1", "block": ["type": "math", "tex": "a^m a^n = a^{m+n}"]],
        ["kind": "note", "from": "u1", "note": "misconception", "prov": "source", "text": "\\(a^m + a^n\\) is not \\(a^{m+n}\\)."], ["kind": "para", "from": "u2"],
      ],
    ])
    let c = PageBuild.check(out: o, concept: concept, math: MathChecker(katex: repoKatex))
    #expect(c.problems.isEmpty)
    let first = PageBuild.assemble(try #require(c.draft), concept: concept, old: nil, provenance: ["job": "j1"])
    #expect(first.page.units.map(\.id) == ["p1", "b2", "n3", "p4"])
    #expect(first.page.units[0].text == concept.units[0].text)
    #expect(first.page.units[3].prov == "added")
    #expect(first.history.isEmpty)

    // u2 의 글이 바뀌고 상자가 빠진 새 원문
    var changed = concept
    changed.units[1] = ConceptUnit(id: "u2", text: "Two, revised", conditions: [], claims: [])
    let draft = PageBuild.Draft(
      titleKo: "지수 법칙", units: [.init(kind: .para, from: "u1", prov: "source", text: nil, note: nil, tex: nil), .init(kind: .para, from: "u2", prov: "source", text: nil, note: nil, tex: nil)])
    let second = PageBuild.assemble(draft, concept: changed, old: first.page, provenance: ["job": "j2"])
    #expect(second.page.units.map(\.id) == ["p1", "p4"])
    #expect(second.page.units.map(\.rev) == [1, 2])
    #expect(second.page.nextID == 5)
    #expect(second.history.count == 3)
    #expect(PageBuild.needsPage(changed, page: first.page, version: nil))
    #expect(!PageBuild.needsPage(changed, page: second.page, version: nil))
  }

  @Test func 다시_만들어도_요구로_더한_단위는_제자리에_남고_새_판_풀이는_단계와_함께_옮긴다() {
    let h1 = "u1@\(concept.units[0].hash)", h2 = "u2@\(concept.units[1].hash)"
    func unit(_ id: String, _ kind: PageUnitKind, _ from: String, _ d: [String] = [], block: YAMLMap? = nil, rev: Int = 1) -> PageUnit {
      var u = PageUnit(id: id, rev: rev, kind: kind, from: from, prov: "source", text: kind == .step || kind == .check ? id : nil, block: block)
      u.directives = d
      return u
    }
    let deriv: YAMLMap = ["type": "derivation", "v": 1, "title": "T"]
    let old = Page(
      concept: concept.id, titleKo: "지수 법칙", nextID: 11,
      units: [
        unit("p1", .para, h1), unit("b2", .block, h1, ["d1"], block: deriv, rev: 2),
        unit("s3", .step, h1, ["d1"], block: ["tex": "1", "parent": "b2"]), unit("s4", .step, h1, ["d1"], block: ["tex": "2", "parent": "b2"]),
        unit("s5", .step, h1, ["d1"], block: ["tex": "3", "parent": "b2"]), unit("p6", .para, h2),
        unit("b7", .block, h2, ["d2"], block: deriv), unit("s8", .step, h2, ["d2"], block: ["tex": "4", "parent": "b7"]),
        unit("q9", .check, h2, ["d2"], block: ["type": "check", "answer": "1"]), unit("q10", .check, h1, block: ["type": "check", "answer": "2"]),
      ], provenance: [:])
    let draft = PageBuild.Draft(
      titleKo: "지수 법칙",
      units: [
        .init(kind: .para, from: "u1", prov: "source"), .init(kind: .block, from: "u1", prov: "source", spec: deriv),
        .init(kind: .step, from: "u1", prov: "source", text: "a", spec: ["tex": "9"]), .init(kind: .step, from: "u1", prov: "source", text: "b", spec: ["tex": "8"]),
        .init(kind: .para, from: "u2", prov: "source"), .init(kind: .check, from: "u2", prov: "added", text: "new", spec: ["type": "check", "answer": "3"]),
        .init(kind: .check, from: "u1", prov: "added", text: "q10", spec: ["type": "check", "answer": "2"]),
      ])
    let built = PageBuild.assemble(draft, concept: concept, old: old, provenance: ["job": "j"], living: ["d1", "d2"], inserting: ["d2"])
    #expect(built.page.units.map(\.id) == ["p1", "b2", "s3", "s4", "s5", "p6", "b7", "s8", "q9", "q11", "q10"])
    #expect(built.page.units.first { $0.id == "s5" }?.parent == "b2")
    #expect(built.page.units.first { $0.id == "s8" }?.parent == "b7")
    #expect(built.recheck.isEmpty)
  }
}

@Suite struct OutcomeTestTests {
  @Test func 해당하는데_해내지_못하거나_연습할_문제가_없는_목표만_문제로_돌려준다() {
    let goals = [OutcomeTest.Goal(key: "o1", text: "Can calculate standard deviation."), OutcomeTest.Goal(key: "o2", text: "Can explain how changes affect it.")]
    let verdicts = [
      OutcomeTest.Verdict(key: "o1", applies: true, met: true, practiced: true, missing: ""),
      OutcomeTest.Verdict(key: "o2", applies: true, met: false, practiced: false, missing: "값이 바뀔 때의 설명이 없다."),
      OutcomeTest.Verdict(key: "o3", applies: false, met: false, practiced: false, missing: ""),
    ]
    #expect(OutcomeTest.unmet(verdicts, goals: goals).count == 1)
    #expect(OutcomeTest.unmet(verdicts, goals: goals).first?.contains("Can explain how changes affect it.") == true)
    #expect(OutcomeTest.unpracticed(verdicts, goals: goals).count == 1)
    #expect(OutcomeTest.prompt(text: "x", goals: goals, level: "an IB student in MYP 10", subject: "Extended Math").contains("o2: Can explain"))
  }
}

@Suite struct LanguageAcquisitionTests {
  @Test func 과목_이름으로_언어_습득_과목과_목표_언어를_알아본다() {
    #expect(LanguageAcquisition.target(of: "Spanish") == "Spanish")
    #expect(LanguageAcquisition.target(of: "spanish") == "Spanish")
    #expect(LanguageAcquisition.target(of: "Español") == "Spanish")
    #expect(LanguageAcquisition.target(of: "French ab initio") == "French")
    #expect(LanguageAcquisition.target(of: "Language Acquisition: Spanish") == "Spanish")
    #expect(LanguageAcquisition.target(of: "English B") == "English")
    #expect(LanguageAcquisition.target(of: "Language B") == LanguageAcquisition.unnamed)
    #expect(LanguageAcquisition.target(of: "language-acquisition") == LanguageAcquisition.unnamed)
    // 영어와 문학 과목, 내용 과목은 언어 습득 과목이 아니다
    // 한자·가나·한글로 쓰는 언어는 아직 다루지 않는다
    for name in [
      "English", "Language and Literature", "Language A: Literature", "Spanish A: Literature", "Spanish A", "French A", "Physics", "Extended Mathematics",
      "Individuals and Societies", "Mandarin B", "Japanese ab initio", "Chinese", "Korean B",
    ] {
      #expect(LanguageAcquisition.target(of: name) == nil, "\(name)")
    }
  }

  @Test func 언어_습득_과목이면_요청과_판정자에게_알린다() {
    let t = TempPlace()
    func lead(_ subject: String) -> SourceSummary {
      let meta = SourceMeta(
        id: "20261020-aaaa0000", original: .init(name: "x.pdf", bytes: 1, sha256: "s"), received: "r", converted: nil, pages: 1,
        textLayer: .init(by: "pdfkit", pagesWithText: 1, ocrPages: []), buildUps: [])
      let labels = SourceLabels(grade: "MYP 5", subject: subject, level: nil)
      return SourceSummary(folder: SourceFolder(id: meta.id, in: t.data), meta: meta, labels: SourceLabelsFile(source: meta.id, labels: labels, memo: nil, syllabusBasis: false))
    }
    let bundle = SourceBundle(id: "20261020-bbbb0000", created: "r", sources: ["20261020-aaaa0000"])
    let spanish = SourceReading.requestMarkdown(bundle, targets: [lead("Spanish")], earlier: [], earlierEntries: [])
    #expect(spanish.contains("- 과목 갈래: 언어 습득 (목표 언어: Spanish)"))
    #expect(!SourceReading.requestMarkdown(bundle, targets: [lead("Physics")], earlier: [], earlierEntries: []).contains("과목 갈래"))

    let item = [ReaderTest.Item(key: "u1", text: "*Ayer comí paella.* (Yesterday I ate paella.)")]
    #expect(ReaderTest.prompt(item, level: "an IB student in MYP 5", subject: "Spanish").contains("Spanish 를 배우는 중"))
    #expect(!ReaderTest.prompt(item, level: "an IB student in MYP 5", subject: "Physics").contains("언어 습득"))

    let goals = [OutcomeTest.Goal(key: "o1", text: "Explain why recycling matters.")]
    let verdicts = [OutcomeTest.Verdict(key: "o1", applies: true, met: false, practiced: false, missing: "x")]
    #expect(OutcomeTest.prompt(text: "x", goals: goals, level: "an IB student in MYP 5", subject: "Spanish").contains("Spanish 로 해낼 수 있으면"))
    #expect(OutcomeTest.prompt(text: "x", goals: goals, level: "an IB student in MYP 5", subject: "Physics").contains("왜 그런지"))
    #expect(OutcomeTest.unmet(verdicts, goals: goals, subject: "Spanish").first?.contains("주제 내용의 까닭") == true)
    #expect(OutcomeTest.unpracticed(verdicts, goals: goals, subject: "Spanish").first?.contains("활용, 문장 만들기") == true)
    #expect(OutcomeTest.unpracticed(verdicts, goals: goals).first?.contains("계산만 시키지 않는다") == true)
  }
}

@Suite struct TranslationCheckTests {
  @Test func 수식_숫자_남은_영어_어휘를_본다() {
    let g = Glossary(terms: [GlossaryTerm(en: "exponent", ko: "지수")])
    let en = "Add the exponents when you multiply: \\(a^m a^n = a^{m+n}\\) for 2 cases."
    #expect(Translation.unitProblems(en: en, ko: "곱할 때는 지수를 더한다: \\(a^m a^n = a^{m+n}\\). 경우는 2가지다.", glossary: g).isEmpty)
    #expect(Translation.unitProblems(en: en, ko: "곱할 때는 지수를 더한다: \\(a^m a^n\\). 경우는 2가지다.", glossary: g).contains { $0.contains("수식") })
    #expect(Translation.unitProblems(en: en, ko: "곱할 때는 지수를 더한다: \\(a^m a^n = a^{m+n}\\). 경우는 3가지다.", glossary: g).contains { $0.contains("숫자") })
    #expect(Translation.unitProblems(en: en, ko: "곱할 때는 거듭제곱 수를 더한다: \\(a^m a^n = a^{m+n}\\). 2가지.", glossary: g).contains { $0.contains("exponent") })
    #expect(Translation.leftoverEnglish("지수는 (exponent of the base here now) 이다") == nil)
    #expect(Translation.leftoverEnglish("그래서 add the exponents when you multiply them 이다") != nil)
    #expect(Translation.leftoverEnglish("화면 아래에 SELECT, DELETE, TYPE, TOOL, MODIFY, DRAW 명령이 있다") == nil)
  }

  @Test func 영어_단위에_그대로_나온_외국어_예문은_남은_영어로_세지_않는다() {
    let g = Glossary()
    let en = "Use *ir a* + infinitive for plans: *Mañana voy a reciclar el papel y el cartón.* Another example: *Me gusta mucho la comida de mi abuela.* (I really like my grandmother's food.)"
    let ko = "계획은 *ir a* + 동사원형으로 말한다: *Mañana voy a reciclar el papel y el cartón.* 다른 예: *Me gusta mucho la comida de mi abuela.* (나는 할머니의 음식을 정말 좋아한다.)"
    #expect(Translation.unitProblems(en: en, ko: ko, glossary: g).isEmpty)
    // 가운데의 약어와 괄호를 덜어 내도 영어 단위와 맞춰 본다
    let quoted = "*¿Puedes comparar las habilidades del estudiante IB con las de tu familia (ATL skills)?*"
    #expect(Translation.leftoverEnglish("질문 예: \(quoted) (네 가족의 것과 견줄 수 있는가?)", en: "A question: \(quoted) (Can you compare them?)") == nil)
    // 영어 단위에 없는 외국어 글이나, 옮기지 않은 영어 설명은 그대로 잡는다
    #expect(Translation.leftoverEnglish("예: *Me gusta mucho la comida de mi abuela* 이다") != nil)
    let untranslated = "계획은 use ir a plus the infinitive to talk about plans 로 말한다: *Mañana voy a reciclar el papel y el cartón.*"
    #expect(Translation.leftoverEnglish(untranslated, en: en + " Use ir a plus the infinitive to talk about plans.") != nil)
  }

  @Test func 다른_과목의_용어로는_막지_않는다() {
    let g = Glossary(terms: [GlossaryTerm(en: "reflection", ko: "대칭이동", subjects: ["extended-mathematics"]), GlossaryTerm(en: "skill", ko: "기술")])
    let en = "*La reflexión* means reflection: a skill you practise in class."
    let ko = "*La reflexión* 은 성찰을 뜻한다. 수업에서 연습하는 기술이다."
    #expect(Translation.unitProblems(en: en, ko: ko, glossary: g).contains { $0.contains("reflection") })
    #expect(Translation.unitProblems(en: en, ko: ko, glossary: g.of(subject: "spanish")).isEmpty)
    #expect(g.of(subject: "extended-mathematics").terms.count == 2)
  }

  @Test func 고쳐_쓴_뒤에는_어휘와_다른_뜻으로_쓴_낱말로_막지_않는다() throws {
    let g = Glossary(terms: [GlossaryTerm(en: "mean", ko: "평균")])
    let unit = PageUnit(id: "q1", rev: 1, kind: .check, from: "u1@x", prov: "added", text: "Find the standard deviation and state what it means in context.")
    let out = TempPlace().root.appending(path: "out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["units": ["q1": "표준편차를 구하고, 그 값이 맥락에서 무엇을 뜻하는지 밝혀라."]]).write(to: out.appending(path: "layers.json"))
    // 처음에는 알려서 고쳐 쓰게 하고, 고쳐 쓴 뒤에는 받는다 (기록에 남긴다)
    #expect(Translation.check(out: out, targets: [unit], glossary: g).accepted.isEmpty)
    let relaxed = Translation.check(out: out, targets: [unit], glossary: g, strictTerms: false)
    #expect(relaxed.accepted["q1"] != nil)
    #expect(relaxed.termNotes["q1"]?.count == 1)
  }
}

// 가짜 claude 로 자료 넣기 → 자료 읽기 → 개념 정리 → 학습 페이지 → 번역을 끝까지 돌린다.
// 가짜는 작업 공간의 input/ 을 보고 그 작업의 out/ 을 쓰고, stream-json 결과 줄을 낸다.
@MainActor
@Suite struct PipelineRunTests {
  static let fakeClaude = #"""
    #!/usr/bin/python3 -I
    # 시험용 가짜 claude. 작업 공간의 input/ 을 보고 out/ 을 쓴다. 30초 넘게 돌면 스스로 끝난다.
    import glob, json, os, re, signal, sys
    signal.alarm(30)
    cwd = os.getcwd()
    def emit(o): print(json.dumps(o), flush=True)
    def out(rel, text):
        p = os.path.join(cwd, "out", rel); os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(text)
    def read(rel):
        p = os.path.join(cwd, "input", rel)
        return open(p).read() if os.path.exists(p) else ""
    def tool(path): emit({"type": "assistant", "session_id": "fake", "message": {"content": [{"type": "tool_use", "name": "Read", "input": {"file_path": path}}]}})
    if "--json-schema" in sys.argv:
        # 학생 독자 시험과 격리 검증: 모두 통과
        print(json.dumps({"type": "result", "subtype": "success", "structured_output": {"items": [], "verdict": "pass", "problems": [], "outcomes": []}, "total_cost_usd": 0}))
        sys.exit(0)
    emit({"type": "system", "subtype": "init", "session_id": "fake"})
    req = read("request.md")
    if "# 자료 나누기 요청" in req:
        # 쪽 글자에 "Class N of M" 이 있는 쪽에서 수업이 시작한다. 둘 이상이면 나눈다 (첫 수업은 1쪽부터).
        items = []
        for d in sorted(glob.glob(cwd + "/input/sources/*")):
            parts = re.split(r"^## (\d+)쪽$", open(d + "/text.md").read(), flags=re.M)
            bodies = {int(parts[i]): parts[i + 1] for i in range(1, len(parts) - 1, 2)}
            starts = [n for n in sorted(bodies) if re.search(r"Class \d+ of", bodies[n])]
            lessons = []
            if len(starts) > 1:
                starts[0] = 1
                for k, a in enumerate(starts):
                    b = starts[k + 1] - 1 if k + 1 < len(starts) else max(bodies)
                    lessons.append({"pages": [a, b], "title": "Class %d" % (k + 1)})
            items.append({"source": os.path.basename(d), "lessons": lessons})
        out("split.json", json.dumps({"sources": items}))
        out("report.md", "# 자료 나누기\n\n차시 표시로 나눴다.\n")
    elif "# 자료 읽기 요청" in req:
        ids = sorted(os.listdir(cwd + "/input/sources"))
        for p in sorted(glob.glob(cwd + "/input/sources/*/pages/*.png")): tool(p)
        out("bundle.json", json.dumps({"title": "Laws of indices"}))
        for i in ids:
            out("sources/" + i + ".json", json.dumps({"title": "Laws of indices", "kind": "lecture slides", "assessment": False, "skipped_pages": [],
                "outcomes": [{"text": "Can multiply powers with the same base and explain why the exponents add.", "pages": [1]}]}))
        out("entries/laws-of-indices.json", json.dumps({"slug": "laws-of-indices", "title": "Laws of indices", "item": "Exponents",
            "body": "When you multiply powers with the same base, add the exponents: \\(a^m a^n = a^{m+n}\\).",
            "claims": [{"text": "\\(a^m a^n = a^{m+n}\\)", "source": ids[0], "pages": [1]}], "pages": {ids[0]: [1, 2]}}))
        out("report.md", "# Laws of indices\n\n## 무엇인가\n지수 법칙 수업 자료다.\n")
    elif "# 개념 정리 요청" in req:
        keys = re.findall(r"^\| (e\d+) \|", req, re.M)
        src = []
        for k in keys: src += re.findall(r"\"(\d{8}-[0-9a-f]{8}#p\d+)\"", read("entries/" + k + ".md"))
        out("plan.json", json.dumps({"concepts": [{"concept": None, "slug": "laws-of-indices", "title": "Laws of indices", "item": "Exponents", "entries": keys,
            "units": [{"id": None, "text": "Multiply powers with the same base by adding the exponents: \\(a^m a^n = a^{m+n}\\).", "conditions": [],
            "claims": [{"text": "\\(a^m a^n = a^{m+n}\\)", "src": src[:1]}]}]}], "held": []}))
        out("report.md", "엔트리 하나를 새 개념으로 묶었다.\n")
    elif "# 학습 페이지 요청" in req:
        ids = re.search(r"원문 단위: (.*)", req).group(1).split(", ")
        units = [{"kind": "para", "from": i} for i in ids]
        units.append({"kind": "note", "from": ids[0], "note": "misconception", "prov": "source", "text": "\\(a^m + a^n\\) is not \\(a^{m+n}\\)."})
        units.append({"kind": "block", "from": ids[0], "block": {"type": "figure", "file": "powers.html", "title": "Powers of two"},
            "caption": "Move the slider to change the exponent and watch the bar grow."})
        out("figures/powers.html", "<svg width=\"200\" height=\"40\"><rect width=\"120\" height=\"30\" fill=\"var(--accent)\"/></svg>")
        out("page.json", json.dumps({"title_ko": "지수 법칙", "units": units}))
    elif "# 관점 붙이기" in req:
        keys = re.findall(r"^- (k\d+):", req, re.M)
        # 한 장 요약과 공식: 개념 원문의 주장 id (단위 id.주장 id) 가운데서 고른다
        def refs(k):
            unit, found = None, []
            for i in re.findall(r'\bid: "([uc]\d+)"', read("concepts/" + k + ".yaml")):
                if i.startswith("u"): unit = i
                elif unit: found.append(unit + "." + i)
            return found
        out("facets.json", json.dumps({"concepts": {k: {"command_terms": ["Solve"], "key_concepts": ["Form"], "related_concepts": ["Equivalence"], "global_contexts": [], "nos": [], "tok": ["Mathematics"],
            "summary": refs(k)[:3], "formulas": refs(k)[:1]} for k in keys}}))
    elif "# 레퍼런스 찾기" in req:
        keys = re.findall(r"^- (k\d+):", req, re.M)
        # 열어 보지 않은 주소는 러너가 버린다
        out("references.json", json.dumps({k: [{"url": "https://example.com/never-fetched", "title": "X", "kind": "article", "why": "x"}] for k in keys}))
    elif "# 다시 만들기 요구" in req:
        op = re.search(r"- 방식: (\w+)", req).group(1)
        tex = re.findall(r"\\\(.*?\\\)", req)
        t = tex[0] if tex else ""
        src = re.findall(r"\((\d{8}-[0-9a-f]{8}#p\d+)\)", req)
        if op == "easy":
            out("candidate.json", json.dumps({"en": "Put simply, when you multiply you add the exponents: " + t + ".", "ko": "쉽게 말하면 곱할 때 지수를 더한다: " + t + "."}))
        elif op == "detail":
            out("candidate.json", json.dumps({"text": "In more detail, multiply powers with the same base by adding the exponents: " + t + ". Each power counts factors of the base.",
                "claims": [{"text": t, "src": src[:1]}, {"text": "each power counts factors", "added": True}]}))
        elif op == "example":
            out("candidate.json", json.dumps({"units": [{"kind": "block", "from": "u1", "block": {"type": "derivation", "title": "Simplify \\(2^3 \\times 2^2\\)",
                "steps": [{"tex": "2^3 \\times 2^2", "why": "Same base.", "expr": "2^3*2^2"}, {"tex": "2^{5}", "why": "Add the exponents.", "expr": "2^5"}, {"tex": "32", "why": "Evaluate.", "expr": "32"}]}}]}))
        elif op == "fix":
            out("verdict.json", json.dumps({"verdict": "correct", "reason": "자료 1쪽과 같다."}))
    elif read("question.md"):
        refs = []
        for p in sorted(glob.glob(cwd + "/input/sources/*/pages/*.png")):
            tool(p)
            parts = p.split("/")
            refs.append(parts[-3] + "#p" + str(int(parts[-1][:4])))
        out("answer.json", json.dumps({"en": "Because the exponents add: \\(a^m a^n = a^{m+n}\\).", "ko": "지수가 더해지기 때문이다: \\(a^m a^n = a^{m+n}\\).",
            "src": refs[:1], "supplementary": False, "outside": False}))
    elif read("targets.json"):
        units = {}
        for t in json.loads(read("targets.json")):
            tex = re.findall(r"\\\(.*?\\\)", t["text"])
            units[t["id"]] = "밑이 같은 거듭제곱을 곱할 때는 지수를 더한다: " + " ".join(tex) + "."
        out("layers.json", json.dumps({"units": units, "terms": [{"en": "exponent", "ko": "지수"}]}))
    emit({"type": "result", "subtype": "success", "is_error": False, "num_turns": 3, "total_cost_usd": 0.01, "session_id": "fake"})
    """#

  @Test func 자료_하나가_한국어가_붙은_학습_페이지까지_간다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let fake = t.root.appending(path: "bin/claude")
    try FileManager.default.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Self.fakeClaude.write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    var config = RunnerConfig(
      claudeToken: "x", timeout: .seconds(60), tools: ToolPaths(claude: fake.path), guardHelper: "/x", instructions: repoInstructions, katex: repoKatex,
      baseEnvironment: [:])
    config.model = "test"

    let pdf = t.root.appending(path: "inbox/Laws_of_indices.pdf")
    SampleFiles.pdf(pdf, [.text("Laws of indices. Product rule: a to the m times a to the n."), .text("Example: two cubed times two squared.")])
    let m = JobManager(data: t.data, folders: t.folders)
    let request = IntakeRequest(files: [pdf], labels: SourceLabels(grade: "MYP 5", subject: "Extended Math", level: "Extended"))
    _ = try await m.submit(config: config) { try SourceIntake.prepare(request, $0) }
    await m.waitUntilIdle()

    let runs = try String(contentsOf: t.data.runsLog(), encoding: .utf8).split(separator: "\n").compactMap { try? JSONValue.parse(Data($0.utf8)) }
    #expect(runs.map { $0["kind"]?.stringValue ?? "" } == ["source-intake", "source-split", "source-reading", "concept-curation", "page-build", "translation", "facets"])
    #expect(runs.allSatisfy { $0["result"]?.stringValue == "done" }, "\(runs.map { $0["error"]?.stringValue ?? "" })")

    // 자료 하나가 묶음 하나가 되고, 묶음 읽기가 이름을 짓는다
    let bundles = BundleStore.all(t.data)
    #expect(bundles.count == 1 && bundles.first?.implicit == false)
    #expect(bundles.first?.title == "Laws of indices")
    let entries = EntryStore.all(t.data, subject: "extended-math")
    #expect(entries.map(\.id) == ["extended-math/unplaced/laws-of-indices"])
    #expect(entries.first?.sources.first?.pages == [1, 2])
    #expect(entries.first?.claims.first?.src.first?.hasSuffix("#p1") == true)
    let concepts = ConceptStore.all(t.data, subject: "extended-math")
    let concept = try #require(concepts.first)
    #expect(concept.id == "extended-math/unplaced/laws-of-indices")
    #expect(concept.occurrences.map(\.entry) == [entries[0].id])
    let folder = ConceptFolder(concept.cid, in: t.data)
    let page = try #require(Page.load(folder))
    #expect(page.units.map(\.id) == ["p1", "n2", "b3"])
    // 그림 코드는 판마다 파일 하나로 개념 폴더의 figures/ 에 둔다
    #expect(page.units[2].block?["code"]?.string == "figures/b3-r1.html")
    #expect(FileOps.exists(folder.url.appending(path: "figures/b3-r1.html")))
    let layers = try #require(Layers.load(folder))
    #expect(Set(layers.ko.keys) == ["p1", "n2", "b3"])
    #expect(Translation.targets(page, layers: layers).isEmpty)
    #expect(Glossary.load(t.data).term("exponent")?.ko == "지수")
    #expect(Pipeline.pending(t.data, instructions: repoInstructions).isEmpty)
    // 관점은 어휘에 맞춰 붙고, 열어 보지 않은 레퍼런스는 버려 빈 목록으로 남는다
    #expect(ConceptFacets.load(ConceptFolder(concept.cid, in: t.data))?.keyConcepts == ["Form"])
    #expect(References.load(t.data).concepts[concept.id]?.items.isEmpty == true)

    // 화면에 넘길 페이지: 출처 칩은 자료 이름과 쪽이다
    let json = PageComposer.json(PageComposer.load(t.data, concept: concept, library: SourceLibrary.load(t.data)))
    let units = json["units"]?.arrayValue ?? []
    #expect(units.first?["ko"]?.stringValue?.contains("지수") == true)
    #expect(units.first?["src"]?.arrayValue?.first?["label"]?.stringValue == "Laws of indices · 1")
    #expect(json["titleKo"]?.stringValue == "지수 법칙")
    #expect(units[2]["figure"]?["src"]?.stringValue == "jindesk-page://figure/figures/b3-r1.html?c=extended-math/unplaced/laws-of-indices")
    #expect(units[2]["caption"]?.stringValue?.hasPrefix("Move the slider") == true)
    // 기록
    let reading = SourceReading.readSources(t.data)
    #expect(reading.count == 1)
    // 자료가 밝힌 학습 목표가 읽기 기록에 남고, 개념 정리와 페이지 만들기의 요청에 들어간다
    #expect(SourceReading.outcomes(t.data, sources: Set(reading.keys)).map(\.text) == ["Can multiply powers with the same base and explain why the exponents add."])
    // 질문을 달면 물어보기가 답글을 단다
    let unit = page.units[0]
    let question = Comment(
      id: Comment.makeID(), at: Clock.isoLocal(), by: "learner", kind: .ask, anchor: CommentAnchor(concept: concept.id, unit: unit.id, rev: unit.rev, quote: "Multiply"),
      text: "Why do the exponents add?")
    try CommentStore.append(t.data, question)
    #expect(Pipeline.pending(t.data, instructions: repoInstructions).map(\.kind) == [.ask])
    let askID = try await m.submit(config: config) { try Ask.prepare(commentID: question.id, $0) }
    let asked = await m.waitForEnd(askID)
    #expect(asked.phase == "done", "\(asked.error ?? "")")
    let thread = CommentStore.thread(CommentStore.load(t.data), concept: concept.id)
    #expect(thread.map(\.kind) == [.ask, .answer])
    #expect(thread.last?.src.first?.hasSuffix("#p1") == true)
    #expect(Ask.unanswered(t.data).isEmpty)
    let withComments = PageComposer.json(PageComposer.load(t.data, concept: concept, library: SourceLibrary.load(t.data)))
    #expect(withComments["comments"]?[unit.id]?.arrayValue?.first?["replies"]?.arrayValue?.count == 1)
    // 지우면 스레드에서 빠진다
    try CommentStore.append(t.data, Comment(id: Comment.makeID(), at: Clock.isoLocal(), by: "learner", kind: .delete, target: question.id))
    #expect(CommentStore.thread(CommentStore.load(t.data), concept: concept.id).isEmpty)

    // 다시 만들기: 더 쉽게는 곁 층, 더 자세히는 후보, 예시 더는 새 블록
    func regen(_ op: DirectiveOp, unit: PageUnit) async throws -> Directive {
      let d = try DirectiveStore.request(t.data, op: op, target: DirectiveTarget(concept: concept.id, unit: unit.id, rev: unit.rev), note: nil, fromComment: nil)
      let id = try await m.submit(config: config) { try Regen.prepare(directiveID: d.id, $0) }
      let end = await m.waitForEnd(id)
      #expect(end.phase == "done", "\(op): \(end.error ?? "")")
      return DirectiveStore.load(t.data).first { $0.id == d.id }!
    }
    let p1 = try #require(Page.load(folder)?.units.first)
    #expect(try await regen(.easy, unit: p1).status == .applied)
    #expect(Layers.load(folder)?.easy[p1.id]?.ko.contains("지수") == true)
    let detail = try await regen(.detail, unit: p1)
    #expect(detail.status == .candidate)
    _ = try Regen.accept(t.data, directiveID: detail.id)
    let accepted = try #require(Page.load(folder)?.units.first)
    #expect(accepted.rev == 2 && accepted.text?.hasPrefix("In more detail") == true && accepted.directives == [detail.id])
    #expect(try await regen(.example, unit: accepted).status == .applied)
    let withExample = try #require(Page.load(folder))
    #expect(withExample.units.contains { $0.isDerivation && $0.directives.count == 1 })
    // 페이지를 다시 만들어도 원문이 그대로면 받아들인 판과 더한 예시가 남는다
    let draft = PageBuild.Draft(titleKo: "지수 법칙", units: [.init(kind: .para, from: "u1", prov: "source")])
    let livingDirectives = DirectiveStore.load(t.data).filter(\.status.isLiving)
    let rebuilt = PageBuild.assemble(
      draft, concept: concept, old: withExample, provenance: ["job": "x"], living: Set(livingDirectives.map(\.id)),
      inserting: Set(livingDirectives.filter { $0.op.inserts }.map(\.id)))
    #expect(rebuilt.page.units.first?.text?.hasPrefix("In more detail") == true)
    #expect(rebuilt.page.units.contains { $0.isDerivation })
    #expect(rebuilt.recheck.isEmpty)

    // 러너가 쓴 모든 데이터 파일이 리포의 스키마에 맞는다
    let issues = DataValidation.validate(t.data, schemas: SchemaSet(repoRoot.appending(path: "schemas/\(CurrentSchema.version)")))
    #expect(issues.isEmpty, "\(issues)")
  }

  @Test func 토큰_없이_넣은_자료는_남은_일로_보인다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let pdf = t.root.appending(path: "inbox/a.pdf")
    SampleFiles.pdf(pdf, [.text("Only a page with enough words to be text layer okay")])
    let m = JobManager(data: t.data, folders: t.folders)
    var config = testConfig
    config.claudeToken = ""
    let request = IntakeRequest(files: [pdf], labels: SourceLabels(grade: nil, subject: "Physics", level: nil))
    _ = try await m.submit(config: config) { try SourceIntake.prepare(request, $0) }
    await m.waitUntilIdle()
    // 한 쪽짜리 자료는 나눌 수 없어 나누기를 보지 않고 바로 읽는다
    let pending = Pipeline.pending(t.data, instructions: repoInstructions)
    #expect(pending.map(\.kind) == [.sourceReading])
  }

  @Test func 수업_여러_개가_든_파일은_수업마다_자료와_묶음으로_나눈다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let fake = t.root.appending(path: "bin/claude")
    try FileManager.default.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Self.fakeClaude.write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    var config = RunnerConfig(
      claudeToken: "x", timeout: .seconds(60), tools: ToolPaths(claude: fake.path), guardHelper: "/x", instructions: repoInstructions, katex: repoKatex,
      baseEnvironment: [:])
    config.model = "test"

    // 단원 표지 뒤에 차시 셋. 1쪽(단원 표지)은 첫 수업에 붙는다.
    let pdf = t.root.appending(path: "inbox/Forces_unit.pdf")
    SampleFiles.pdf(
      pdf,
      [
        .text("Forces and Motion unit for grade ten physics students"), .text("Week 1 Class 1 of 3 What is momentum and why it matters"),
        .text("Momentum is mass times velocity and it is a vector quantity"), .text("Week 1 Class 2 of 3 Impulse and the change in momentum"),
        .text("Impulse equals force multiplied by the time of contact"), .text("Week 2 Class 3 of 3 Conservation of momentum in collisions"),
        .text("Total momentum before equals total momentum after a collision"),
      ])
    let m = JobManager(data: t.data, folders: t.folders)
    let request = IntakeRequest(files: [pdf], labels: SourceLabels(grade: "MYP 5", subject: "Physics", level: nil), memo: "역학 단원")
    let intake = try await m.submit(config: config) { try SourceIntake.prepare(request, $0) }
    #expect(await m.waitForEnd(intake).phase == "done")
    let parent = try #require(SourceLibrary.load(t.data).sources.first)
    // 나누기가 시작하면 뒤따르는 자료 읽기는 대기열에 남겨 둔다
    m.hold(.backup)
    let split = try #require(m.active.first { $0.kind == .sourceSplit })
    let end = await m.waitForEnd(split.id)
    #expect(end.phase == "done", "\(end.error ?? "")")
    #expect(end.counts?.map(\.count) == [1, 1, 3])

    // 원래 자료는 없어지고, 수업마다 자료가 생긴다. 쪽 번호는 수업 안에서 1부터다.
    let library = SourceLibrary.load(t.data)
    #expect(library.source(parent.id) == nil && !FileOps.exists(t.folders.pageImages(parent.id)))
    let pieces = library.sources.sorted { ($0.meta.splitFrom?.pages.first ?? 0) < ($1.meta.splitFrom?.pages.first ?? 0) }
    #expect(pieces.map(\.meta.pages) == [3, 2, 2])
    #expect(pieces.map { $0.meta.splitFrom?.pages ?? [] } == [[1, 3], [4, 5], [6, 7]])
    #expect(pieces.map(\.meta.original.name) == ["Forces_unit · Class 1.pdf", "Forces_unit · Class 2.pdf", "Forces_unit · Class 3.pdf"])
    #expect(pieces.allSatisfy { $0.meta.splitFrom?.sha256 == parent.meta.original.sha256 && $0.meta.received == parent.meta.received })
    #expect(pieces.allSatisfy { $0.labels.labels.summary == "MYP 5 · Physics" })
    #expect(SourcePages.text(pieces[1].folder, page: 1).contains("Class 2 of 3"))
    #expect(PDFDocument(url: try #require(pieces[2].folder.original))?.pageCount == 2)
    #expect(FileOps.exists(t.folders.pageImages(pieces[0].id).appending(path: "0003.png")))
    #expect(try FileOps.read(pieces[0].folder.index).contains("| 3 |"))
    // 같은 파일을 다시 넣으면 원래 파일의 해시로 알아본다
    if case .existing = SourceIntake.plan([pdf], library: library).first?.status {} else { Issue.record("다시 넣은 파일을 알아보지 못했습니다") }

    // 수업마다 묶음 하나. 메모는 묶음마다 붙고, 첫 수업이 맨 위다.
    let bundles = BundleStore.all(t.data, library: library)
    #expect(bundles.map(\.id) == pieces.map(\.id))
    #expect(bundles.allSatisfy { $0.memo == "역학 단원" && !$0.implicit && $0.sources.count == 1 })
    // 뒤따르는 자료 읽기는 수업마다 하나씩, 수업 차례로
    #expect(m.queue.filter { $0.kind == .sourceReading }.map(\.target) == pieces.map(\.id))
    // 나누기를 본 자료와 쪼갠 자료는 다시 나누기를 보지 않는다
    #expect(SourceSplit.checkedSources(t.data) == [parent.id])
    #expect(Pipeline.pending(t.data, instructions: repoInstructions).map(\.kind) == [.sourceReading, .sourceReading, .sourceReading])
    let issues = DataValidation.validate(t.data, schemas: SchemaSet(repoRoot.appending(path: "schemas/\(CurrentSchema.version)")))
    #expect(issues.isEmpty, "\(issues)")
    m.shutdown()
  }

  @Test func 나누기_검사는_빈틈과_겹침과_이어_채운_쪽_가르기를_찾는다() throws {
    let t = TempPlace()
    func source(_ pages: Int, buildUps: [[Int]] = []) -> SourceSummary {
      let meta = SourceMeta(
        id: "20261019-aaaa0000", original: .init(name: "x.pdf", bytes: 1, sha256: "s"), received: "r", converted: nil, pages: pages,
        textLayer: .init(by: "pdfkit", pagesWithText: pages, ocrPages: []), buildUps: buildUps)
      return SourceSummary(
        folder: SourceFolder(id: meta.id, in: t.data), meta: meta, labels: SourceLabelsFile(source: meta.id, labels: SourceLabels(), memo: nil, syllabusBasis: false))
    }
    func check(_ lessons: [[Any]], pages: Int = 10, buildUps: [[Int]] = []) throws -> SourceSplit.Plan {
      let items = lessons.map { l in #"{"pages": [\#(l[0]), \#(l[1])], "title": "\#(l[2])"}"# }.joined(separator: ",")
      try FileOps.write(#"{"sources": [{"source": "20261019-aaaa0000", "lessons": [\#(items)]}]}"#, to: t.root.appending(path: "out/split.json"))
      return SourceSplit.check(out: t.root.appending(path: "out"), targets: [source(pages, buildUps: buildUps)])
    }
    #expect(try check([[1, 4, "Class 1"], [5, 10, "Class 2"]]).lessons["20261019-aaaa0000"]?.count == 2)
    // 수업이 하나뿐이거나 없으면 나누지 않는다
    #expect(try check([[1, 10, "Class 1"]]).lessons.isEmpty)
    #expect(try check([]).problems.isEmpty)
    #expect(try check([[2, 4, "A"], [5, 10, "B"]]).problems.count == 1)
    #expect(try check([[1, 4, "A"], [4, 10, "B"]]).problems.count == 1)
    #expect(try check([[1, 4, "A"], [5, 9, "B"]]).problems.count == 1)
    #expect(try check([[1, 4, "수업 1"], [5, 10, "B"]]).problems.count == 1)
    #expect(try check([[1, 4, "A"], [5, 10, "B"]], buildUps: [[3, 4, 5]]).problems.count == 1)
    #expect(try check([[1, 4, "A"], [5, 10, "B"]]).lessons.count == 1)
  }

  @Test func 같은_일을_할_작업이_대기열에_있으면_하나로_합친다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let m = JobManager(data: t.data, folders: t.folders)
    m.hold(.update)
    let a = try await m.submit(config: testConfig) { try ConceptCuration.prepare(bundle: "20261019-aaaabbbb", $0) }
    let b = try await m.submit(config: testConfig) { try ConceptCuration.prepare(bundle: "20261019-aaaabbbb", $0) }
    let c = try await m.submit(config: testConfig) { try ConceptCuration.prepare(bundle: "20261019-ccccdddd", $0) }
    #expect(a == b)
    #expect(a != c)
    #expect(m.queue.count == 2)
    m.release(.update)
    await m.waitUntilIdle()
  }
}
