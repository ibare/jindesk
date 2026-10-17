import Foundation
import Testing
@testable import JindeskKit

let repoKatex = repoRoot.appending(path: "renderer/katex/katex.min.js")

@Suite struct TextCheckTests {
  @Test func 한글과_한자_일본어를_가린다() {
    #expect(TextChecks.hasHangul("log 는"))
    #expect(!TextChecks.hasHangul("logarithm"))
    #expect(TextChecks.hasHanOrKana("指数"))
    #expect(TextChecks.hasHanOrKana("ログ"))
    #expect(!TextChecks.hasHanOrKana("로그와 log"))
    #expect(TextChecks.englishProblems("The base 밑", field: "f", privacy: []).count == 1)
    #expect(TextChecks.koreanProblems("밑은 a 다", field: "f", privacy: []).isEmpty)
    #expect(TextChecks.koreanProblems("the base", field: "f", privacy: []).count == 1)
  }

  @Test func 금지어와_원래_자료가_있어야_통하는_말을_찾는다() {
    #expect(TextChecks.privacyHits("Taught by Ms Kim at Sample Academy", terms: ["sample academy"]) == ["sample academy"])
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

  @Test func 맞는_엔트리는_받고_틀린_엔트리는_까닭과_함께_뺀다() throws {
    let out = TempPlace().root.appending(path: "out")
    try write(out, "source.json", ["title": "Laws of indices", "kind": "lecture slides", "assessment": false, "skipped_pages": [["page": 1, "reason": "표지"]]])
    try write(out, "report.md", "# Laws of indices\n\n지수 법칙 자료다.\n")
    try write(
      out, "entries/good.json",
      ["slug": "laws-of-indices", "title": "Laws of indices", "body": "Add exponents: \\(a^m a^n = a^{m+n}\\).", "claims": [["text": "\\(a^m a^n = a^{m+n}\\)", "pages": [2]]]])
    try write(out, "entries/korean.json", ["title": "지수 법칙", "body": "x", "claims": [["text": "y", "pages": [2]]]])
    try write(out, "entries/badpage.json", ["title": "Zero exponent", "body": "\\(a^0 = 1\\)", "claims": [["text": "\\(a^0 = 1\\)", "pages": [9]]]])
    try write(out, "entries/slide.json", ["title": "Negative exponent", "body": "As shown on the slide, \\(a^{-1}\\).", "claims": [["text": "c", "pages": [2]]]])
    let checked = SourceReading.check(out: out, meta: meta(pages: 3), privacy: [], math: MathChecker(katex: repoKatex))
    #expect(checked.problems.isEmpty)
    #expect(checked.entries.map(\.slug) == ["laws-of-indices"])
    #expect(Set(checked.rejected.map(\.file)) == ["korean.json", "badpage.json", "slide.json"])
    #expect(checked.note?.skipped == [1])
  }

  @Test func 요약과_엔트리가_없으면_작업_전체가_틀린다() throws {
    let out = TempPlace().root.appending(path: "out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let checked = SourceReading.check(out: out, meta: meta(pages: 2), privacy: [], math: nil)
    #expect(checked.problems.count == 3)
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
      id: id, subject: "math", item: nil, itemProposed: "Exponents", title: "T", source: "20261017-aaaabbbb", pages: [1],
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
    let c = ConceptCuration.check(out: out, input: input(), privacy: [], math: nil)
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
    let c = ConceptCuration.check(out: out, input: input, privacy: [], math: MathChecker(katex: repoKatex))
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
    let c = PageBuild.check(out: o, concept: concept, privacy: [], math: nil)
    #expect(c.problems.contains { $0.contains("u2") })
    #expect(c.problems.contains { $0.contains("math 블록만") })
  }

  @Test func 다시_만들면_같은_자리의_단위는_id_를_지키고_바뀐_것만_판을_올린다() throws {
    let o = try out([
      "title_ko": "지수 법칙",
      "units": [
        ["kind": "para", "from": "u1"], ["kind": "block", "from": "u1", "block": ["type": "math", "tex": "a^m a^n = a^{m+n}"]],
        ["kind": "note", "from": "u1", "note": "misconception", "prov": "source", "text": "\\(a^m + a^n\\) is not \\(a^{m+n}\\)."], ["kind": "para", "from": "u2"],
      ],
    ])
    let c = PageBuild.check(out: o, concept: concept, privacy: [], math: MathChecker(katex: repoKatex))
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
}

@Suite struct TranslationCheckTests {
  @Test func 수식_숫자_남은_영어_어휘를_본다() {
    let g = Glossary(terms: [GlossaryTerm(en: "exponent", ko: "지수")])
    let en = "Add the exponents when you multiply: \\(a^m a^n = a^{m+n}\\) for 2 cases."
    #expect(Translation.unitProblems(en: en, ko: "곱할 때는 지수를 더한다: \\(a^m a^n = a^{m+n}\\). 경우는 2가지다.", glossary: g, privacy: []).isEmpty)
    #expect(Translation.unitProblems(en: en, ko: "곱할 때는 지수를 더한다: \\(a^m a^n\\). 경우는 2가지다.", glossary: g, privacy: []).contains { $0.contains("수식") })
    #expect(Translation.unitProblems(en: en, ko: "곱할 때는 지수를 더한다: \\(a^m a^n = a^{m+n}\\). 경우는 3가지다.", glossary: g, privacy: []).contains { $0.contains("숫자") })
    #expect(Translation.unitProblems(en: en, ko: "곱할 때는 거듭제곱 수를 더한다: \\(a^m a^n = a^{m+n}\\). 2가지.", glossary: g, privacy: []).contains { $0.contains("exponent") })
    #expect(Translation.leftoverEnglish("지수는 (exponent of the base here now) 이다") == nil)
    #expect(Translation.leftoverEnglish("그래서 add the exponents when you multiply them 이다") != nil)
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
    emit({"type": "system", "subtype": "init", "session_id": "fake"})
    req = read("request.md")
    if "# 자료 읽기 요청" in req:
        for p in sorted(glob.glob(cwd + "/input/pages/*.png")): tool(p)
        out("source.json", json.dumps({"title": "Laws of indices", "kind": "lecture slides", "assessment": False, "skipped_pages": []}))
        out("entries/laws-of-indices.json", json.dumps({"slug": "laws-of-indices", "title": "Laws of indices", "item": "Exponents",
            "body": "When you multiply powers with the same base, add the exponents: \\(a^m a^n = a^{m+n}\\).",
            "claims": [{"text": "\\(a^m a^n = a^{m+n}\\)", "pages": [1]}], "pages": [1, 2]}))
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
        out("page.json", json.dumps({"title_ko": "지수 법칙", "units": units}))
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
    #expect(runs.map { $0["kind"]?.stringValue ?? "" } == ["source-intake", "source-reading", "concept-curation", "page-build", "translation"])
    #expect(runs.allSatisfy { $0["result"]?.stringValue == "done" }, "\(runs.map { $0["error"]?.stringValue ?? "" })")

    let entries = EntryStore.all(t.data, subject: "extended-math")
    #expect(entries.map(\.id) == ["extended-math/unplaced/laws-of-indices"])
    #expect(entries.first?.claims.first?.src.first?.hasSuffix("#p1") == true)
    let concepts = ConceptStore.all(t.data, subject: "extended-math")
    let concept = try #require(concepts.first)
    #expect(concept.id == "extended-math/unplaced/laws-of-indices")
    #expect(concept.occurrences.map(\.entry) == [entries[0].id])
    let folder = ConceptFolder(concept.cid, in: t.data)
    let page = try #require(Page.load(folder))
    #expect(page.units.map(\.id) == ["p1", "n2"])
    let layers = try #require(Layers.load(folder))
    #expect(Set(layers.ko.keys) == ["p1", "n2"])
    #expect(Translation.targets(page, layers: layers).isEmpty)
    #expect(Glossary.load(t.data).term("exponent")?.ko == "지수")
    #expect(Pipeline.pending(t.data, instructions: repoInstructions).isEmpty)

    // 화면에 넘길 페이지: 출처 칩은 자료 이름과 쪽이다
    let json = PageComposer.json(PageComposer.load(t.data, concept: concept, library: SourceLibrary.load(t.data)))
    let units = json["units"]?.arrayValue ?? []
    #expect(units.first?["ko"]?.stringValue?.contains("지수") == true)
    #expect(units.first?["src"]?.arrayValue?.first?["label"]?.stringValue == "Laws of indices · 1")
    #expect(json["titleKo"]?.stringValue == "지수 법칙")
    // 기록
    let reading = SourceReading.readSources(t.data)
    #expect(reading.count == 1)
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
    let pending = Pipeline.pending(t.data, instructions: repoInstructions)
    #expect(pending.map(\.kind) == [.sourceReading])
  }

  @Test func 같은_일을_할_작업이_대기열에_있으면_하나로_합친다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let m = JobManager(data: t.data, folders: t.folders)
    m.hold(.update)
    let a = try await m.submit(config: testConfig) { try ConceptCuration.prepare(subject: "math", $0) }
    let b = try await m.submit(config: testConfig) { try ConceptCuration.prepare(subject: "math", $0) }
    let c = try await m.submit(config: testConfig) { try ConceptCuration.prepare(subject: "physics", $0) }
    #expect(a == b)
    #expect(a != c)
    #expect(m.queue.count == 2)
    m.release(.update)
    await m.waitUntilIdle()
  }
}
