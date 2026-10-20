// 부분 다시 만들기 (regen, REGENERATION.md). 학생의 요구 하나로 단위 하나를 다시 만든다. 다른 단위는 흔들지 않는다.
// 방식: 더 쉽게(곁 층), 더 자세히(새 판 후보 또는 곁 층), 예시 더(새 블록), 그림으로(그림 후보), 그림 다시(그림 새 판 후보),
//       단계 더(풀이 새 판 후보), 고치기(두 에이전트가 따로 자료와 대조해 원문을 고친다).
// 글을 만드는 방식은 격리 검증(도구 없는 검증자가 원래 판·새 판·자료 쪽만 보고 빠진 주장, 모순, 근거 없는 새 주장, 바뀐 숫자를 찾는다)과
// 요구 수준의 학생 독자 시험을 거친다. 그림은 돌아가는지만 본다. 받아들이기 전에는 아무것도 바뀌지 않는다.
import Foundation

// 페이지와 곁 층을 읽고-고쳐-쓰는 구간의 잠금 (한 프로세스에서 페이지 만들기, 번역, 다시 만들기, 받아들이기가 겹칠 때)
public enum PageLock {
  static let lock = NSLock()

  public static func withLock<T>(_ body: () throws -> T) rethrows -> T {
    try lock.withLock { try body() }
  }
}

public enum Regen {
  static func prompt(_ op: DirectiveOp) -> String {
    "input/request.md 의 요구(\(op.rawValue))로 지침대로 대상 단위 하나를 다시 만들어라. out/candidate.json 을 쓴다"
      + (op == .visual || op == .redraw ? " (그림 코드는 out/figures/ 에)." : ".")
  }

  public static func prepare(directiveID: String, _ ctx: PrepareContext) throws -> PreparedJob {
    guard let d = DirectiveStore.load(ctx.data).first(where: { $0.id == directiveID }) else { throw RequestError("요구를 찾지 못했습니다: \(directiveID)") }
    guard let cid = ConceptID(d.target.concept) else { throw RequestError("개념을 찾지 못했습니다: \(d.target.concept)") }
    let id = try JobID.make(date: ctx.now, slugSource: "regen \(d.op.rawValue) \(cid.slug)", exists: ctx.taken)
    return PreparedJob(
      id: id, kind: .regen, title: "\(d.op.label) · \(cid.slug) \(d.target.unit)", serialKey: d.target.concept, target: d.target.concept,
      coalesceKey: "regen:\(directiveID)", recipe: .regen(directive: directiveID)
    ) { c in
      try await run(directiveID: directiveID, c)
    }
  }

  // 다시 돌아야 하는 요구: 요청했는데 아직 결과가 없거나, 원문이 바뀌어 다시 확인해야 하거나, 곁 층이 낡은 것
  public static func pending(_ data: DataFolder) -> [Directive] {
    let all = DirectiveStore.load(data)
    var out = all.filter { $0.status == .requested || $0.status == .recheck }
    for d in all where d.status == .applied && (d.op == .easy || d.op == .detail) {
      guard let cid = ConceptID(d.target.concept) else { continue }
      let folder = ConceptFolder(cid, in: data)
      guard let page = Page.load(folder), let unit = page.units.first(where: { $0.id == d.target.unit }), let layers = Layers.load(folder) else { continue }
      let layer = d.op == .easy ? layers.easy[unit.id] : layers.detail[unit.id]
      if let layer, layer.directive == d.id, !layer.isCurrent(for: unit) { out.append(d) }
    }
    return out
  }

  struct Base: Sendable {
    let concept: Concept
    let page: Page
    let unit: PageUnit
    let source: ConceptUnit?
    let available: Set<String>
    let sourceText: String
  }

  static func run(directiveID: String, _ ctx: JobContext) async throws {
    await ctx.setPhase("preparing")
    guard let d = DirectiveStore.load(ctx.data).first(where: { $0.id == directiveID }) else { throw ToolError("요구를 찾지 못했습니다") }
    do {
      try await runDirective(d, ctx)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try? DirectiveStore.update(ctx.data, id: d.id, status: .failed, job: ctx.id, extra: ["reason": .string(error.localizedDescription)])
      throw error
    }
  }

  static func runDirective(_ d: Directive, _ ctx: JobContext) async throws {
    guard let cid = ConceptID(d.target.concept), let concept = ConceptStore.load(ctx.data, id: cid) else { throw ToolError("개념을 찾지 못했습니다") }
    let folder = ConceptFolder(cid, in: ctx.data)
    guard let page = Page.load(folder), let unit = page.units.first(where: { $0.id == d.target.unit }) else { throw ToolError("단위를 찾지 못했습니다: \(d.target.unit)") }
    let source = concept.units.first { $0.id == unit.fromUnit }
    let dirs = AgentDirs(ctx.folders, ctx.id)
    try dirs.make()
    let (instructions, instructionsFile) = try await AgentStep.fixInstructions(.regen, ctx, into: dirs.run)
    let base = try writeInput(d, concept: concept, page: page, unit: unit, source: source, dirs: dirs, ctx: ctx, allPages: d.op == .fix)
    await ctx.log(.info, "\(d.op.label): \(concept.id) \(unit.id) (판 \(unit.rev))")
    try ctx.checkCancellation()

    if d.op == .fix {
      try await runFix(d, base: base, dirs: dirs, instructionsFile: instructionsFile, instructions: instructions, ctx: ctx)
      return
    }

    await ctx.setPhase("running")
    let options = AgentStep.options(ctx, dirs, instructions: instructionsFile, prompt: prompt(d.op), events: "regen")
    let result = try await AgentStep.run(options, ctx, label: d.op.label)
    await ctx.setPhase("checking")
    var checked = await check(d, base: base, out: dirs.out, ctx: ctx, scratch: dirs.run.appending(path: "verify-1"))
    if !checked.problems.isEmpty {
      await ctx.log(.warn, "검사에서 \(checked.problems.count)건이 나와 고쳐 쓰게 합니다: \(checked.problems.prefix(3).joined(separator: " · "))")
      await ctx.setPhase("fixing")
      try await AgentStep.fix(options, session: result.sessionID, problems: checked.problems, ctx: ctx, label: d.op.label, events: "regen-fix")
      await ctx.setPhase("checking")
      checked = await check(d, base: base, out: dirs.out, ctx: ctx, scratch: dirs.run.appending(path: "verify-2"))
    }
    let record = ctx.data.record(JobKind.regen.rawValue, ctx.id)
    try FileOps.writeNew(JSONText.record(requestJSON(d)), to: record.appending(path: "request.json"))
    try FileOps.writeNew(JSONText.record(baseJSON(base)), to: record.appending(path: "base.json"))
    try FileOps.writeNew(JSONText.record(.object(["v": .number(1), "problems": .array(checked.problems.map(JSONValue.string)), "checks": .array(checked.passed.map(JSONValue.string))])), to: record.appending(path: "checks.json"))
    guard checked.problems.isEmpty, let candidate = checked.candidate else {
      throw ToolError("\(d.op.label) 검사 실패: " + checked.problems.prefix(4).joined(separator: " · "))
    }

    await ctx.setPhase("finalizing")
    let prov = AgentStep.provenance(ctx, .regen, instructions)
    try FileOps.writeNew(JSONText.record(candidate.json), to: record.appending(path: "candidate.json"))
    for (file, code) in candidate.figures { try FileOps.writeNew(code, to: record.appending(path: "figures/\(file)")) }
    switch candidate.place {
    case .layer:
      try PageLock.withLock {
        guard let now = Page.load(folder), let u = now.units.first(where: { $0.id == base.unit.id }), u.hash == base.unit.hash, u.rev == base.unit.rev else {
          throw ToolError("그사이 단위가 바뀌어 쓰지 않았습니다. 다시 요청하세요")
        }
        var layers = Layers.load(folder) ?? Layers(concept: concept.id)
        let side = SideLayer(from: u.ref, unitHash: u.hash, en: candidate.en ?? "", ko: candidate.ko ?? "", directive: d.id, checks: checked.passed, prov: prov)
        if d.op == .easy { layers.easy[u.id] = side } else { layers.detail[u.id] = side }
        try layers.write(folder, order: now.units.map(\.id))
      }
      try DirectiveStore.update(ctx.data, id: d.id, status: .applied, job: ctx.id, result: base.unit.id)
      await ctx.log(.info, "곁 층 \"\(d.op.label)\"에 넣었습니다")
    case .insert:
      let ids = try insert(candidate.units, after: base.unit, directive: d.id, folder: folder, base: base, provenance: prov, figures: candidate.figures)
      try DirectiveStore.update(ctx.data, id: d.id, status: .applied, job: ctx.id, result: ids.first)
      await ctx.log(.info, "단위 \(ids.joined(separator: ", ")) 를 더했습니다")
      _ = await ctx.queueFollowUp("번역", { try Translation.prepare(subject: concept.subject, $0) })
    case .candidate:
      try DirectiveStore.update(ctx.data, id: d.id, status: .candidate, job: ctx.id)
      await ctx.log(.info, "새 판 후보를 만들었습니다. 학생이 견주어 고릅니다")
    }
    await ctx.report(counts: [JobCount(key: "checks", label: "통과한 검사", count: checked.passed.count)])
  }

  // MARK: - 입력

  static func writeInput(
    _ d: Directive, concept: Concept, page: Page, unit: PageUnit, source: ConceptUnit?, dirs: AgentDirs, ctx: JobContext, allPages: Bool
  ) throws -> Base {
    let folder = ConceptFolder(concept.cid, in: ctx.data)
    try FileOps.copy(folder.concept, to: dirs.input.appending(path: "concept.yaml"))
    try FileOps.copy(folder.page, to: dirs.input.appending(path: "page.yaml"))
    try AgentStep.writeGlossary(ctx.data, into: dirs.input)
    // 블록(풀이, 확인 문제, 그림)의 모양과 그림 규칙은 학습 페이지 지침에 있다. 참고로 함께 둔다.
    if let reference = FileOps.readIfExists(ctx.config.instructions.file(.pageBuild)) {
      try FileOps.write(reference, to: dirs.input.appending(path: "reference/page-build.md"))
    }
    var refs = Set(unit.claims.flatMap(\.src)).union(source?.refs ?? [])
    if allPages || refs.isEmpty { refs.formUnion(concept.refs) }
    var pagesBySource: [String: Set<Int>] = [:]
    for r in refs { if let (s, p) = SourceRef.parse(r) { pagesBySource[s, default: []].insert(p) } }
    if allPages { for o in concept.occurrences { pagesBySource[o.source, default: []].formUnion(o.pages) } }
    let library = SourceLibrary.load(ctx.data)
    var available: Set<String> = []
    var sourceText = ""
    for (s, pages) in pagesBySource.sorted(by: { $0.key < $1.key }) {
      guard let summary = library.source(s) else { continue }
      for n in pages.sorted() where n >= 1 && n <= summary.meta.pages {
        let dir = dirs.input.appending(path: "sources/\(s)/pages")
        try FileOps.copy(summary.folder.pageText(n), to: dir.appending(path: "\(SourceFolder.pageName(n)).txt"))
        try FileOps.copy(try SourcePages.image(summary.folder, page: n, folders: ctx.folders), to: dir.appending(path: "\(SourceFolder.pageName(n)).png"))
        available.insert(SourceRef.make(s, page: n))
        sourceText += "[\(SourceRef.make(s, page: n))]\n" + (FileOps.readIfExists(summary.folder.pageText(n)) ?? "") + "\n"
      }
    }
    var r = ["# 다시 만들기 요구", "", "- 방식: \(d.op.rawValue) (\(d.op.label))", "- 개념: \(concept.id) (\(concept.title))", "- 대상 단위: \(unit.id) (\(unit.kind.rawValue), 판 \(unit.rev))"]
    if unit.isFigure { r.append("- 대상은 그림 블록이다. 지금 코드: input/figure.html") }
    if unit.isDerivation { r.append("- 대상은 풀이 블록이다. 단계는 input/page.yaml 에서 parent 가 \(unit.id) 인 step 단위다") }
    if let note = d.note { r += ["- 학생 메모: \(note)"] }
    if let c = d.fromComment, let comment = CommentStore.load(ctx.data).first(where: { $0.id == c }) {
      r += ["- 이 요구가 나온 코멘트(\(comment.kind.label)): \(comment.text ?? "")"]
    }
    let level = ReaderTest.level(library.sources.first { $0.labels.labels.subjectID == concept.subject }?.labels.labels)
    r.append("- 학생: \(level)")
    if let target = LanguageAcquisition.target(of: library.subjects.first { $0.id == concept.subject }?.name ?? concept.subject) {
      r.append(LanguageAcquisition.requestLine(target))
    }
    r += ["", "## 대상 단위의 지금 글", ""]
    r.append(unit.english ?? (unit.block.map { YAML.stringify($0) } ?? ""))
    if let source {
      r += ["", "## 이 단위가 온 원문 단위 (\(source.id))", "", source.text, ""]
      if !source.conditions.isEmpty { r.append("- 조건: \(source.conditions.joined(separator: "; "))") }
      for c in source.claims { r.append("- 주장 \(c.id): \(c.text) (\(c.src.joined(separator: ", ")))") }
    }
    let living = DirectiveStore.forConcept(DirectiveStore.load(ctx.data), concept: concept.id).filter { $0.target.unit == unit.id && $0.status.isLiving }
    if !living.isEmpty {
      r += ["", "## 이 단위에 적용된 요구", ""]
      for l in living { r.append("- \(l.id) \(l.op.label)\(l.note.map { ": \($0)" } ?? "")") }
    }
    r += ["", "## 자료 쪽", "", available.sorted().map { "`\($0)`" }.joined(separator: ", ")]
    try FileOps.write(r.joined(separator: "\n") + "\n", to: dirs.input.appending(path: "request.md"))
    if unit.isFigure, let code = unit.block?["code"]?.string, let text = FileOps.readIfExists(folder.url.appending(path: code)) {
      try FileOps.write(text, to: dirs.input.appending(path: "figure.html"))
    }
    return Base(concept: concept, page: page, unit: unit, source: source, available: available.union(concept.refs), sourceText: sourceText)
  }

  static func requestJSON(_ d: Directive) -> JSONValue {
    .object([
      "v": .number(1), "id": .string(d.id), "op": .string(d.op.rawValue), "target": d.target.json, "note": d.note.map(JSONValue.string) ?? .null,
      "from_comment": d.fromComment.map(JSONValue.string) ?? .null,
    ])
  }

  static func baseJSON(_ b: Base) -> JSONValue {
    .object([
      "v": .number(1), "concept": .string(b.concept.id), "unit": .string(b.unit.id), "rev": .number(Double(b.unit.rev)), "unit_hash": .string(b.unit.hash),
      "source_unit": b.source.map { .string("\($0.id)@\($0.hash)") } ?? .null,
    ])
  }

  // MARK: - 검사

  enum Place: Sendable { case layer, insert, candidate }

  struct Candidate: Sendable {
    let place: Place
    var en: String? = nil
    var ko: String? = nil
    // 새 판이나 새 단위 (PageUnit 모양, id 와 rev 는 반영할 때 정한다)
    var units: [PageUnit] = []
    var figures: [(file: String, code: String)] = []

    var json: JSONValue {
      var o: [String: JSONValue] = ["v": .number(1)]
      if let en { o["en"] = .string(en) }
      if let ko { o["ko"] = .string(ko) }
      o["units"] = .array(units.map { YAMLValue.map($0.yaml).json })
      o["figures"] = .array(figures.map { JSONValue.string($0.file) })
      return .object(o)
    }

    static func read(_ url: URL) -> (units: [PageUnit], figures: [String])? {
      guard let data = try? Data(contentsOf: url), let v = try? JSONValue.parse(data) else { return nil }
      let units = (v["units"]?.arrayValue ?? []).compactMap { PageUnit(yaml: YAMLValue(json: $0)) }
      return (units, (v["figures"]?.arrayValue ?? []).compactMap(\.stringValue))
    }
  }

  struct Checked: Sendable {
    var candidate: Candidate?
    var problems: [String] = []
    var passed: [String] = []
  }

  static func check(_ d: Directive, base: Base, out: URL, ctx: JobContext, scratch: URL) async -> Checked {
    var c = Checked()
    let v: JSONValue
    switch AgentJSON.read(out.appending(path: "candidate.json"), label: "out/candidate.json") {
    case .failure(let p):
      c.problems.append(p.message)
      return c
    case .success(let value): v = value
    }
    let math = ctx.config.katex.flatMap(MathChecker.init(katex:))
    let glossary = Glossary.load(ctx.data).of(subject: base.concept.subject)
    let original = base.unit.english ?? base.source?.text ?? ""
    let side = d.op == .easy || (d.op == .detail && (d.note?.contains("곁") ?? false))

    switch d.op {
    case .easy, .detail where side:
      guard let en = AgentJSON.string(v["en"]), let ko = AgentJSON.string(v["ko"]) else {
        c.problems.append("en 과 ko 가 있어야 한다")
        return c
      }
      c.problems += TextChecks.englishProblems(en, field: "en")
      if let math { c.problems += math.problems(inText: en, field: "en") }
      c.problems += TexText.asciiMath(en, field: "en")
      c.problems += Translation.unitProblems(en: en, ko: ko, glossary: glossary).map { "ko: \($0)" }
      let missing = Set(TexText.numbers(original)).subtracting(TexText.numbers(en))
      if !missing.isEmpty { c.problems.append("원래 글의 숫자가 빠졌습니다: \(missing.sorted().joined(separator: ", "))") }
      if c.problems.isEmpty {
        c.problems += await verify(base: base, newText: en, added: [], allowNew: false, ctx: ctx, scratch: scratch)
        c.problems += await reader(en, op: d.op, base: base, ctx: ctx, scratch: scratch.appending(path: "reader"))
      }
      if c.problems.isEmpty {
        c.passed = ["조건과 주장 유지", "새 주장 없음", "숫자 대조", "격리 검증", "독자 시험"]
        c.candidate = Candidate(place: .layer, en: en, ko: ko)
      }
    case .detail:
      guard let text = AgentJSON.string(v["text"]) else {
        c.problems.append("text 가 없습니다")
        return c
      }
      c.problems += TextChecks.englishProblems(text, field: "text")
      for phrase in TextChecks.materialPhrases(text) { c.problems.append("text: 원래 자료가 있어야만 통하는 말입니다 (\"\(phrase)\")") }
      if let math { c.problems += math.problems(inText: text, field: "text") }
      c.problems += TexText.asciiMath(text, field: "text")
      var claims: [UnitClaim] = []
      var added: [String] = []
      for (i, cl) in (v["claims"]?.arrayValue ?? []).enumerated() {
        guard let t = AgentJSON.string(cl["text"]) else { continue }
        let src = AgentJSON.strings(cl["src"])
        if cl["added"]?.boolValue == true {
          added.append(t)
          continue
        }
        if src.isEmpty { c.problems.append("claims[\(i)]: 출처(src)가 없으면 added 를 true 로 둔다") }
        for s in src where !base.available.contains(s) { c.problems.append("claims[\(i)]: 이 개념의 자료에 없는 출처입니다 (\(s))") }
        claims.append(UnitClaim(id: "c\(claims.count + 1)", text: t, src: src))
      }
      if c.problems.isEmpty {
        c.problems += await verify(base: base, newText: text, added: added, allowNew: true, ctx: ctx, scratch: scratch)
        c.problems += await reader(text, op: d.op, base: base, ctx: ctx, scratch: scratch.appending(path: "reader"))
      }
      if c.problems.isEmpty {
        var u = base.unit
        u.text = text
        u.claims = claims
        u.conditions = AgentJSON.strings(v["conditions"]).isEmpty ? base.unit.conditions : AgentJSON.strings(v["conditions"])
        u.prov = claims.isEmpty ? "added" : "source"
        c.passed = ["원래 주장 모두 포함", "새 주장은 출처나 보충 표시", "격리 검증", "독자 시험"]
        c.candidate = Candidate(place: .candidate, units: [u])
      }
    case .example, .visual, .steps:
      let list =
        v["units"]?.arrayValue ?? v["unit"].map { [$0] }
        ?? v["block"].map { [JSONValue.object(["kind": .string("block"), "from": .string(base.unit.fromUnit), "block": $0])] } ?? []
      let parsed = PageBuild.parseUnits(list, concept: base.concept, out: out, math: math, label: "units")
      c.problems += parsed.problems
      if parsed.units.contains(where: { $0.kind == .para || $0.kind == .note }) { c.problems.append("문단과 강조 상자는 만들지 않는다") }
      switch d.op {
      case .visual where !parsed.units.contains(where: { $0.figure != nil }): c.problems.append("그림 블록(figure)이 하나 있어야 한다")
      case .steps where !(parsed.units.first?.spec?["type"]?.string == "derivation" && base.unit.isDerivation):
        c.problems.append("대상이 풀이 블록이고, 새 풀이 블록(derivation) 하나를 써야 한다")
      case .example where parsed.units.isEmpty: c.problems.append("풀이 블록이나 확인 문제가 하나 이상 있어야 한다")
      default: break
      }
      let figureChecks = await PageBuild.checkFigures(PageBuild.Draft(titleKo: "", units: parsed.units), ctx: ctx, tag: d.id)
      c.problems += figureChecks.problems
      if c.problems.isEmpty {
        let built = PageBuild.assemble(
          PageBuild.Draft(titleKo: base.page.titleKo ?? "", units: parsed.units), concept: base.concept, old: nil, provenance: YAMLMap([]))
        c.passed = d.op == .visual ? ["돌아가는지 확인"] : ["단계마다 수식 파싱", "계산 확인"]
        var units = built.page.units
        // "예시 더"의 예제는 자료에 없는 새 예제다. 보충으로 둔다.
        if d.op == .example { for i in units.indices { units[i].prov = "added" } }
        var cand = Candidate(place: d.op == .example ? .insert : .candidate, units: units)
        cand.figures = built.figures.map { ((($0.path as NSString).lastPathComponent), $0.code) }
        c.candidate = cand
      }
    case .redraw:
      guard base.unit.isFigure else {
        c.problems.append("대상이 그림 블록이 아니다")
        return c
      }
      let unit: JSONValue = .object([
        "kind": .string("block"), "from": .string(base.unit.fromUnit),
        "block": .object(["type": .string("figure"), "file": v["file"] ?? .null, "title": v["title"] ?? .string(base.unit.block?["title"]?.string ?? "")]),
        "caption": v["caption"] ?? .string(base.unit.caption ?? ""),
      ])
      let parsed = PageBuild.parseUnits([unit], concept: base.concept, out: out, math: math, label: "figure")
      c.problems += parsed.problems
      let figureChecks = await PageBuild.checkFigures(PageBuild.Draft(titleKo: "", units: parsed.units), ctx: ctx, tag: d.id)
      c.problems += figureChecks.problems
      if c.problems.isEmpty {
        let built = PageBuild.assemble(PageBuild.Draft(titleKo: "", units: parsed.units), concept: base.concept, old: nil, provenance: YAMLMap([]))
        c.passed = ["돌아가는지 확인"]
        var cand = Candidate(place: .candidate, units: built.page.units)
        cand.figures = built.figures.map { ((($0.path as NSString).lastPathComponent), $0.code) }
        c.candidate = cand
      }
    case .fix:
      break
    }
    return c
  }

  // 격리 검증: 도구 없는 검증자가 원래 판, 새 판, 인용한 자료 쪽의 글만 보고 판정한다
  static let verifySchema = """
    {"type":"object","properties":{"missing":{"type":"array","items":{"type":"string"}},"contradictions":{"type":"array","items":{"type":"string"}},"unsupported":{"type":"array","items":{"type":"string"}},"changed_numbers":{"type":"array","items":{"type":"string"}}},"required":["missing","contradictions","unsupported","changed_numbers"]}
    """

  static func verify(base: Base, newText: String, added: [String], allowNew: Bool, ctx: JobContext, scratch: URL) async -> [String] {
    var original = base.unit.english ?? base.source?.text ?? ""
    if let s = base.source {
      if !s.conditions.isEmpty { original += "\n\nConditions: " + s.conditions.joined(separator: "; ") }
      original += "\n\nClaims:\n" + s.claims.map { "- \($0.text)" }.joined(separator: "\n")
    }
    let prompt = """
      너는 검증자다. 학습 페이지 한 단위의 원래 판과 새 판, 그리고 그 단위가 인용한 학교 자료 쪽의 글을 받는다. 다른 것은 볼 수 없다.
      다음을 찾아 목록마다 한 줄씩 적는다 (한국어). 없으면 빈 목록이다.
      - missing: 새 판에서 빠진 원래 주장이나 조건
      - contradictions: 원래 판이나 자료 쪽과 어긋나는 말
      - unsupported: \(allowNew ? "자료 쪽에 근거가 없는 새 주장 (아래 '보충' 목록에 있는 것은 빼고)" : "원래 판에 없던 새 주장 (설명을 쉽게 풀어 쓴 것, 예를 든 것은 새 주장이 아니다)")
      - changed_numbers: 바뀐 숫자, 단위, 수식, 기호
      글 수준이나 문체는 판정하지 않는다.

      <original>
      \(original)
      </original>

      <new>
      \(newText)
      </new>

      <supplementary>
      \(added.joined(separator: "\n"))
      </supplementary>

      <source_pages>
      \(FileOps.prefix(base.sourceText, 12000))
      </source_pages>
      """
    let r = await Judge.run(prompt: prompt, schema: verifySchema, config: ctx.config, scratch: scratch, effort: .medium)
    guard let v = r.value else {
      await ctx.log(.warn, "격리 검증을 하지 못했습니다: \(r.error ?? "")")
      return ["격리 검증을 하지 못했습니다: \(r.error ?? "")"]
    }
    var out: [String] = []
    for (key, label) in [("missing", "빠진 주장"), ("contradictions", "모순"), ("unsupported", "근거 없는 새 주장"), ("changed_numbers", "바뀐 숫자")] {
      for line in (v[key]?.arrayValue ?? []).compactMap(\.stringValue) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        out.append("격리 검증 · \(label): \(line)")
      }
    }
    return out
  }

  static func reader(_ text: String, op: DirectiveOp, base: Base, ctx: JobContext, scratch: URL) async -> [String] {
    let level = op == .easy ? "an IB MYP 5 student (Year 10)" : ReaderTest.level(SourceLibrary.load(ctx.data).sources.first { $0.labels.labels.subjectID == base.concept.subject }?.labels.labels)
    let (verdicts, error) = await ReaderTest.check(
      [ReaderTest.Item(key: base.unit.id, text: text)], level: level, subject: base.concept.subject, config: ctx.config, scratch: scratch)
    if let error {
      await ctx.log(.warn, "독자 시험을 하지 못했습니다: \(error)")
      return []
    }
    return ReaderTest.problems(verdicts).values.flatMap { $0 }
  }

  // MARK: - 반영

  // 대상 단위 뒤에 새 단위를 넣는다 (풀이 블록이면 그 단계들 뒤). 새 id 는 페이지의 next_id 로 붙인다.
  static func insert(
    _ new: [PageUnit], after target: PageUnit, directive: String, folder: ConceptFolder, base: Base, provenance: YAMLMap, figures: [(file: String, code: String)]
  ) throws -> [String] {
    try PageLock.withLock {
      guard var page = Page.load(folder), let at = page.units.firstIndex(where: { $0.id == target.id }), page.units[at].hash == target.hash else {
        throw ToolError("그사이 단위가 바뀌어 쓰지 않았습니다. 다시 요청하세요")
      }
      var index = at + 1
      while index < page.units.count, page.units[index].parent == target.id { index += 1 }
      var ids: [String] = []
      var parent: String?
      let codes = Dictionary(figures.map { ($0.file, $0.code) }, uniquingKeysWith: { a, _ in a })
      for var u in new {
        let id = u.kind.prefix + String(page.nextID)
        page.nextID += 1
        u = PageUnit(
          id: id, rev: 1, kind: u.kind, from: u.from, prov: u.prov, text: u.text, note: u.note, block: u.block, caption: u.caption, claims: u.claims,
          conditions: u.conditions)
        u.directives = [directive]
        if u.isDerivation { parent = id }
        if u.kind == .step { u.block?["parent"] = parent.map(YAMLValue.string) }
        if u.isFigure, let old = u.block?["code"]?.string, let code = codes[(old as NSString).lastPathComponent] {
          let path = "figures/\(id)-r1.html"
          try FileOps.writeNew(code, to: folder.url.appending(path: path))
          u.block?["code"] = .string(path)
        }
        page.units.insert(u, at: index)
        index += 1
        ids.append(id)
      }
      try page.write(folder)
      return ids
    }
  }

  // 후보를 받아들인다 (새 판). 받아들인 단위의 번역은 낡은 것이 되어 다시 옮긴다.
  public static func accept(_ data: DataFolder, directiveID: String) throws -> String? {
    guard let d = DirectiveStore.load(data).first(where: { $0.id == directiveID }), d.status == .candidate, let job = d.job,
      let cid = ConceptID(d.target.concept)
    else { throw RequestError("받아들일 후보가 없습니다") }
    let record = data.record(JobKind.regen.rawValue, job)
    guard let candidate = Candidate.read(record.appending(path: "candidate.json")),
      let baseData = try? Data(contentsOf: record.appending(path: "base.json")), let baseJSON = try? JSONValue.parse(baseData)
    else { throw ToolError("후보 기록을 읽지 못했습니다") }
    let folder = ConceptFolder(cid, in: data)
    var result: String?
    try PageLock.withLock {
      guard var page = Page.load(folder), let at = page.units.firstIndex(where: { $0.id == d.target.unit }) else { throw ToolError("단위를 찾지 못했습니다") }
      let current = page.units[at]
      guard current.hash == baseJSON["unit_hash"]?.stringValue else {
        try DirectiveStore.update(data, id: d.id, status: .recheck)
        throw RequestError("후보를 만든 뒤 단위가 바뀌었습니다. 같은 요구로 다시 만듭니다")
      }
      let historyAt = Clock.isoLocal()
      let prov: YAMLMap = ["job": .string(job)]
      switch d.op {
      case .detail:
        guard var u = candidate.units.first else { throw ToolError("후보가 비었습니다") }
        try FileOps.appendLine(JSONText.line(PageBuild.historyLine(current, reason: "replaced", at: historyAt, provenance: prov)), to: folder.history)
        u = PageUnit(
          id: current.id, rev: current.rev + 1, kind: current.kind, from: current.from, prov: u.prov, text: u.text, note: current.note, block: current.block,
          caption: current.caption, claims: u.claims, conditions: u.conditions)
        u.directives = current.directives + [d.id]
        page.units[at] = u
        result = u.id
      case .visual:
        let ids = try insertLocked(&page, candidate.units, after: current, directive: d.id, folder: folder, record: record)
        result = ids.first
      case .redraw:
        guard var u = candidate.units.first, let file = candidate.figures.first, let code = FileOps.readIfExists(record.appending(path: "figures/\(file)")) else {
          throw ToolError("그림 후보가 없습니다")
        }
        try FileOps.appendLine(JSONText.line(PageBuild.historyLine(current, reason: "replaced", at: historyAt, provenance: prov)), to: folder.history)
        let rev = current.rev + 1
        let path = "figures/\(current.id)-r\(rev).html"
        if !FileOps.exists(folder.url.appending(path: path)) { try FileOps.writeNew(code, to: folder.url.appending(path: path)) }
        u = PageUnit(
          id: current.id, rev: rev, kind: .block, from: current.from, prov: current.prov, block: u.block, caption: u.caption)
        u.block?["code"] = .string(path)
        u.directives = current.directives + [d.id]
        page.units[at] = u
        result = u.id
      case .steps:
        guard var block = candidate.units.first, block.isDerivation else { throw ToolError("풀이 후보가 없습니다") }
        try FileOps.appendLine(JSONText.line(PageBuild.historyLine(current, reason: "replaced", at: historyAt, provenance: prov)), to: folder.history)
        for old in page.units where old.parent == current.id {
          try FileOps.appendLine(JSONText.line(PageBuild.historyLine(old, reason: "removed", at: historyAt, provenance: prov)), to: folder.history)
        }
        page.units.removeAll { $0.parent == current.id }
        block = PageUnit(id: current.id, rev: current.rev + 1, kind: .block, from: current.from, prov: current.prov, block: block.block)
        block.directives = current.directives + [d.id]
        page.units[at] = block
        var index = at + 1
        for var s in candidate.units.dropFirst() where s.kind == .step {
          let id = "s" + String(page.nextID)
          page.nextID += 1
          s = PageUnit(id: id, rev: 1, kind: .step, from: s.from, prov: s.prov, text: s.text, block: s.block)
          s.block?["parent"] = .string(current.id)
          s.directives = [d.id]
          page.units.insert(s, at: index)
          index += 1
        }
        result = current.id
      default:
        throw RequestError("견주어 고르는 방식이 아닙니다")
      }
      try page.write(folder)
    }
    try DirectiveStore.update(data, id: d.id, status: .accepted, result: result)
    return result
  }

  static func insertLocked(_ page: inout Page, _ new: [PageUnit], after target: PageUnit, directive: String, folder: ConceptFolder, record: URL) throws -> [String] {
    guard let at = page.units.firstIndex(where: { $0.id == target.id }) else { return [] }
    var index = at + 1
    while index < page.units.count, page.units[index].parent == target.id { index += 1 }
    var ids: [String] = []
    for var u in new {
      let id = u.kind.prefix + String(page.nextID)
      page.nextID += 1
      u = PageUnit(id: id, rev: 1, kind: u.kind, from: u.from, prov: u.prov, text: u.text, note: u.note, block: u.block, caption: u.caption, claims: u.claims)
      u.directives = [directive]
      if u.isFigure, let old = u.block?["code"]?.string, let code = FileOps.readIfExists(record.appending(path: "figures/\((old as NSString).lastPathComponent)")) {
        let path = "figures/\(id)-r1.html"
        try FileOps.writeNew(code, to: folder.url.appending(path: path))
        u.block?["code"] = .string(path)
      }
      page.units.insert(u, at: index)
      index += 1
      ids.append(id)
    }
    return ids
  }

  public static func keep(_ data: DataFolder, directiveID: String) throws {
    try DirectiveStore.update(data, id: directiveID, status: .kept)
  }

  // MARK: - 고치기

  static let fixPrompt =
    "input/request.md 의 고치기 요구를 지침의 \"고치기\"대로 판단하라. input/sources/ 의 쪽 이미지를 직접 보고, 원문 단위가 맞는지 틀렸는지 근거와 함께 out/verdict.json 에 쓴다."

  struct FixVerdict: Sendable {
    let wrong: Bool
    let reason: String
    let text: String?
    let claims: [UnitClaim]
  }

  static func runFix(_ d: Directive, base: Base, dirs: AgentDirs, instructionsFile: URL, instructions: Instructions, ctx: JobContext) async throws {
    guard let source = base.source else { throw ToolError("원문 단위를 찾지 못했습니다") }
    await ctx.setPhase("running")
    var verdicts: [FixVerdict] = []
    for pass in ["fix1", "fix2"] {
      let passDirs = AgentDirs(ctx.folders, ctx.id, sub: pass)
      try passDirs.make()
      // 두 판단은 서로를 보지 않는다. 같은 입력을 따로 받는다.
      FileOps.remove(passDirs.input)
      try FileOps.copy(dirs.input, to: passDirs.input)
      let options = AgentStep.options(ctx, passDirs, instructions: instructionsFile, prompt: fixPrompt, events: pass)
      _ = try await AgentStep.run(options, ctx, label: "고치기 \(pass == "fix1" ? "1차" : "2차")")
      guard let data = try? Data(contentsOf: passDirs.out.appending(path: "verdict.json")), let v = try? JSONValue.parse(data),
        let verdict = v["verdict"]?.stringValue
      else { throw ToolError("고치기 판단(out/verdict.json)이 없습니다") }
      let claims = (v["claims"]?.arrayValue ?? []).enumerated().compactMap { i, c -> UnitClaim? in
        guard let t = AgentJSON.string(c["text"]) else { return nil }
        return UnitClaim(id: "c\(i + 1)", text: t, src: AgentJSON.strings(c["src"]).filter(base.available.contains))
      }
      verdicts.append(FixVerdict(wrong: verdict == "wrong", reason: AgentJSON.string(v["reason"]) ?? "", text: AgentJSON.string(v["text"]), claims: claims))
    }
    await ctx.setPhase("finalizing")
    let a = verdicts[0]
    let b = verdicts[1]
    var reply: String
    var status: DirectiveStatus
    if a.wrong && b.wrong, let text = b.text, consistent(a.text ?? "", text) {
      var problems = TextChecks.englishProblems(text, field: "text")
      if let math = ctx.config.katex.flatMap(MathChecker.init(katex:)) { problems += math.problems(inText: text, field: "text") }
      problems += TexText.asciiMath(text, field: "text")
      guard problems.isEmpty else { throw ToolError("고친 글 검사 실패: " + problems.joined(separator: " · ")) }
      var concept = base.concept
      guard let i = concept.units.firstIndex(where: { $0.id == source.id }), concept.units[i].hash == source.hash else {
        throw ToolError("그사이 원문 단위가 바뀌었습니다. 다시 요청하세요")
      }
      concept.units[i] = ConceptUnit(id: source.id, text: text, conditions: source.conditions, claims: b.claims.isEmpty ? source.claims : b.claims)
      try concept.write(ctx.data)
      reply = "두 에이전트가 따로 자료와 대조해 원문이 틀렸다고 판단해 고쳤습니다.\n\n" + b.reason
      status = .applied
      let subject = concept.subject
      _ = await ctx.queueFollowUp("학습 페이지 만들기", { try PageBuild.prepare(subject: subject, $0) })
    } else if !a.wrong && !b.wrong {
      reply = "두 에이전트가 따로 자료와 대조해 원래 글이 맞다고 판단했습니다. 바꾸지 않았습니다.\n\n" + a.reason + "\n\n" + b.reason
      status = .kept
    } else {
      reply = "두 판단이 달라 바꾸지 않았습니다.\n\n1차: " + a.reason + "\n\n2차: " + b.reason
      status = .failed
    }
    reply = PageComposer.readableRefs(reply, library: SourceLibrary.load(ctx.data))
    if let c = d.fromComment {
      try CommentStore.append(
        ctx.data, Comment(id: Comment.makeID(), at: Clock.isoLocal(), by: "job:regen", kind: .answer, text: reply, replyTo: c, job: ctx.id))
    }
    let record = ctx.data.record(JobKind.regen.rawValue, ctx.id)
    try FileOps.writeNew(JSONText.record(requestJSON(d)), to: record.appending(path: "request.json"))
    try FileOps.writeNew(
      JSONText.record(.object([
        "v": .number(1), "first": .object(["wrong": .bool(a.wrong), "reason": .string(a.reason)]),
        "second": .object(["wrong": .bool(b.wrong), "reason": .string(b.reason)]), "status": .string(status.rawValue),
      ])), to: record.appending(path: "decision.json"))
    try DirectiveStore.update(ctx.data, id: d.id, status: status, job: ctx.id, result: status == .applied ? source.id : nil)
    _ = instructions
    await ctx.log(.info, reply.split(separator: "\n").first.map(String.init) ?? "")
  }

  // 두 고친 글의 방향이 같은가: 수식과 숫자가 같다
  static func consistent(_ a: String, _ b: String) -> Bool {
    Set(TexText.segments(a).map { TexText.key($0.tex) }) == Set(TexText.segments(b).map { TexText.key($0.tex) })
      && Set(TexText.numbers(a)) == Set(TexText.numbers(b))
  }
}
