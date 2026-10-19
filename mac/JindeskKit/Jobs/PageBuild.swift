// 학습 페이지 만들기 (page-build, JOBS.md). 개념 원문(concept.yaml)에서 학습 페이지(page.yaml)를 만든다. 개념마다 에이전트 하나, 셋씩 함께 돈다.
// 문단은 원문 단위의 글을 그대로 쓴다. 에이전트는 문단의 차례와 수식 블록, 강조 상자, 한국어 제목을 정하고, 러너가 원문 글을 넣는다.
// 시작할 때 페이지가 없거나 낡은 개념을 고른다. 낡은 것은 원문 단위의 해시가 바뀌었거나 지침 판이 바뀐 것이다.
// 블록은 수식(math)과 그림(figure)이 있다. 그림은 에이전트가 HTML 조각으로 짜고, 러너는 화면 밖 웹 보기에서 돌아가는지만 본다.
// 풀이(derivation) 블록은 다음에 붙인다.
import Foundation

public enum PageBuild {
  static let concurrency = 3
  static let prompt =
    "input/concept.yaml 의 개념으로 지침대로 학습 페이지를 짜라. 이전 페이지가 있으면 input/page.yaml 에 있다. out/page.json 을 쓴다."

  public static func prepare(subject: String, _ ctx: PrepareContext) throws -> PreparedJob {
    let id = try JobID.make(date: ctx.now, slugSource: "page \(subject)", exists: ctx.taken)
    return PreparedJob(id: id, kind: .pageBuild, title: subject, target: subject, coalesceKey: "page-build:\(subject)", recipe: .pageBuild(subject: subject)) { c in
      try await run(subject: subject, c)
    }
  }

  // 페이지가 없거나 낡았는가
  public static func needsPage(_ concept: Concept, page: Page?, version: String?) -> Bool {
    guard let page else { return true }
    if let version, page.instructionsVersion != version { return true }
    let current = Set(concept.units.map { "\($0.id)@\($0.hash)" })
    let paras = page.units.filter { $0.kind == .para }.map(\.from)
    return Set(paras) != current || paras.count != current.count || page.units.contains { !current.contains($0.from) }
  }

  public static func pending(_ data: DataFolder, subject: String, version: String?) -> [Concept] {
    ConceptStore.all(data, subject: subject).filter { needsPage($0, page: Page.load(ConceptFolder($0.cid, in: data)), version: version) }
  }

  static func run(subject: String, _ ctx: JobContext) async throws {
    await ctx.setPhase("preparing")
    let instructions = try Instructions.read(ctx.config.instructions, kind: .pageBuild)
    let todo = pending(ctx.data, subject: subject, version: instructions.version)
    if todo.isEmpty {
      await ctx.log(.info, "만들 페이지가 없습니다")
      await ctx.report(counts: [JobCount(key: "pages", label: "페이지", count: 0)])
      return
    }
    let dir = ctx.folders.workDir(ctx.id)
    let (fixed, instructionsFile) = try await AgentStep.fixInstructions(.pageBuild, ctx, into: dir)
    await ctx.log(.info, "페이지 \(todo.count)개: \(todo.map(\.cid.slug).joined(separator: ", "))")
    let math = ctx.config.katex.flatMap(MathChecker.init(katex:))
    let labels = SourceLibrary.load(ctx.data).subjects.first { $0.id == subject }

    await ctx.setPhase("running")
    var written: [String] = []
    var warnings: [String] = []
    try await withThrowingTaskGroup(of: Outcome.self) { group in
      var next = 0
      func add() {
        guard next < todo.count else { return }
        let concept = todo[next]
        let n = next + 1
        next += 1
        group.addTask {
          do {
            return try await buildOne(
              concept, n: n, ctx: ctx, instructions: fixed, instructionsFile: instructionsFile, math: math, labels: labels)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            return .failed(concept.id, error.localizedDescription)
          }
        }
      }
      for _ in 0..<concurrency { add() }
      while let outcome = try await group.next() {
        switch outcome {
        case .written(let id): written.append(id)
        case .failed(let id, let message):
          warnings.append("\(id): \(message)")
          await ctx.log(.error, "\(id): \(message)")
        case .changed(let id):
          warnings.append("\(id): 만드는 사이 개념이 바뀌어 쓰지 않았습니다")
        }
        add()
      }
    }

    await ctx.setPhase("finalizing")
    await ctx.report(
      counts: [JobCount(key: "pages", label: "페이지", count: written.count), JobCount(key: "failed", label: "못 만듦", count: todo.count - written.count)],
      warnings: warnings.isEmpty ? nil : warnings)
    if written.isEmpty && !warnings.isEmpty { throw ToolError("페이지를 하나도 만들지 못했습니다") }
    if !written.isEmpty, await ctx.queueFollowUp("번역", { try Translation.prepare(subject: subject, $0) }) != nil {
      await ctx.log(.info, "번역을 대기열에 넣었습니다")
    }
    // 관점이 없는 개념(새 개념)이 있으면 관점 붙이기도 넣는다
    if !Facets.pendingFacets(ctx.data, subject: subject).isEmpty, await ctx.queueFollowUp("관점 붙이기", { try Facets.prepare(subject: subject, $0) }) != nil {
      await ctx.log(.info, "관점 붙이기를 대기열에 넣었습니다")
    }
    if warnings.contains(where: { $0.hasSuffix("개념이 바뀌어 쓰지 않았습니다") }) {
      _ = await ctx.queueFollowUp("학습 페이지 만들기", { try prepare(subject: subject, $0) })
    }
  }

  enum Outcome: Sendable {
    case written(String)
    case failed(String, String)
    case changed(String)
  }

  static func buildOne(
    _ concept: Concept, n: Int, ctx: JobContext, instructions: Instructions, instructionsFile: URL, math: MathChecker?, labels: SubjectSummary?
  ) async throws -> Outcome {
    let folder = ConceptFolder(concept.cid, in: ctx.data)
    let conceptHash = ConceptStore.fileHash(ctx.data, id: concept.cid)
    let old = Page.load(folder)
    let dirs = AgentDirs(ctx.folders, ctx.id, sub: "c\(n)")
    try dirs.make()
    try FileOps.copy(folder.concept, to: dirs.input.appending(path: "concept.yaml"))
    // 학생 요구로 더한 단위(예시 더, 그림으로)는 러너가 다시 넣는다. 에이전트가 베껴 두 번 만들지 않게 이전 페이지에서 뺀다.
    let inserting = Set(DirectiveStore.forConcept(DirectiveStore.load(ctx.data), concept: concept.id).filter { $0.status.isLiving && $0.op.inserts }.map(\.id))
    var added: [String] = []
    if var shown = old {
      added = shown.units.filter { !Set($0.directives).isDisjoint(with: inserting) }.map(\.id)
      shown.units.removeAll { !Set($0.directives).isDisjoint(with: inserting) }
      try FileOps.write(YAML.stringify(shown.yaml), to: dirs.input.appending(path: "page.yaml"))
    }
    try AgentStep.writeGlossary(ctx.data, into: dirs.input)
    var request = ["# 학습 페이지 요청", "", "- 개념: \(concept.id)", "- 제목: \(concept.title)"]
    if let labels {
      request.append("- 과목: \(labels.name)")
      if !(labels.grades + labels.levels).isEmpty { request.append("- 학년·수준: \((labels.grades + labels.levels).joined(separator: ", "))") }
    }
    request.append("- 원문 단위: \(concept.units.map(\.id).joined(separator: ", "))")
    request.append("- 이전 페이지: \(old == nil ? "없다. 처음 만든다" : "input/page.yaml")")
    if !added.isEmpty {
      request.append("- 학생 요구로 더한 단위 \(added.joined(separator: ", ")): 러너가 그대로 다시 넣는다. input/page.yaml 에서 뺐다. 그 예제나 그림을 다시 만들지 않는다")
    }
    // 이 개념이 나온 자료가 밝힌 학습 목표: 해당하는 목표마다 그것을 연습하는 확인 문제를 둔다 (지침 3.2)
    let outcomes = SourceReading.outcomes(ctx.data, sources: Set(concept.occurrences.map(\.source)))
    let goals = outcomes.enumerated().map { OutcomeTest.Goal(key: "o\($0.offset + 1)", text: $0.element.text) }
    request += ["", "## 학습 목표 (자료가 밝힌 것)", ""]
    request += goals.isEmpty ? ["자료가 밝힌 학습 목표가 없다."] : goals.map { "- \($0.text)" }
    try FileOps.write(request.joined(separator: "\n") + "\n", to: dirs.input.appending(path: "request.md"))

    let tag = concept.cid.slug
    let options = AgentOptions(
      config: ctx.config, workspace: dirs.workspace, configDir: dirs.configDir, systemPromptFile: instructionsFile, eventsFile: dirs.events("page"),
      prompt: prompt, onEvent: { kind, message in if kind != .text { await ctx.log(kind, "[\(tag)] \(message)") } })
    let result = try await AgentStep.run(options, ctx, label: "\(tag) 페이지")
    var checked = check(out: dirs.out, concept: concept, math: math)
    var figures = await checkFigures(checked.draft, ctx: ctx, tag: tag)
    // 학습 목표 시험: 해당하는 목표마다 그것을 연습하는 확인 문제가 있는가. 첫 검사의 문제와 함께 한 번 고쳐 쓰게 한다.
    let level = ReaderTest.level(SourceLibrary.load(ctx.data).sources.first { $0.labels.labels.subjectID == concept.subject }?.labels.labels)
    func outcomeGaps(_ draft: Draft?, _ round: Int) async -> [OutcomeTest.Verdict] {
      guard let draft, !goals.isEmpty else { return [] }
      let others = ConceptStore.all(ctx.data, subject: concept.subject).filter { $0.id != concept.id }.map(\.title)
      let (verdicts, error) = await OutcomeTest.check(
        text: studyText(draft, concept: concept), goals: goals, level: level, subject: labels?.name ?? concept.subject, others: others,
        config: ctx.config, scratch: dirs.run.appending(path: "outcome-\(round)"))
      if let error { await ctx.log(.warn, "[\(tag)] 학습 목표 시험을 하지 못했습니다: \(error)") }
      return verdicts
    }
    var outcome = await outcomeGaps(checked.draft, 1)
    let first = checked.problems + figures.problems + OutcomeTest.unpracticed(outcome, goals: goals)
    if !first.isEmpty {
      await ctx.log(.warn, "[\(tag)] 검사에서 \(first.count)건이 나와 고쳐 쓰게 합니다: \(first.prefix(3).joined(separator: " · "))")
      try await AgentStep.fix(options, session: result.sessionID, problems: first, ctx: ctx, label: "\(tag) 페이지", events: "page-fix")
      checked = check(out: dirs.out, concept: concept, math: math)
      figures = await checkFigures(checked.draft, ctx: ctx, tag: tag)
      if !OutcomeTest.unpracticed(outcome, goals: goals).isEmpty { outcome = await outcomeGaps(checked.draft, 2) }
    }
    // 고쳐 써도 남은 것은 기록에만 남긴다. 페이지만으로 해낼 수 없는 목표도 기록에 남긴다 (문단은 개념 원문이라 여기서 고치지 못한다).
    for line in OutcomeTest.unpracticed(outcome, goals: goals) + OutcomeTest.unmet(outcome, goals: goals) {
      await ctx.log(.warn, "[\(tag)] 학습 목표 시험: \(line)")
    }
    guard checked.problems.isEmpty, var draft = checked.draft else {
      return .failed(concept.id, "검사 실패: " + checked.problems.prefix(5).joined(separator: " · "))
    }
    // 고쳐 써도 돌아가지 않는 그림은 그 블록만 넣지 않는다
    if !figures.failed.isEmpty {
      for (file, problems) in figures.failed.sorted(by: { $0.key < $1.key }) {
        await ctx.log(.warn, "[\(tag)] 그림 \(file) 를 넣지 않았습니다: \(problems.prefix(2).joined(separator: " · "))")
      }
      draft = Draft(titleKo: draft.titleKo, units: draft.units.filter { $0.figure.map { figures.failed[$0.file] == nil } ?? true })
    }
    let livingDirectives = DirectiveStore.forConcept(DirectiveStore.load(ctx.data), concept: concept.id).filter(\.status.isLiving)
    let built = assemble(
      draft, concept: concept, old: old, provenance: AgentStep.provenance(ctx, .pageBuild, instructions), living: Set(livingDirectives.map(\.id)),
      inserting: Set(livingDirectives.filter { $0.op.inserts }.map(\.id)))
    // 쓰기 직전에 개념 원문이 그대로인지 다시 본다
    guard ConceptStore.fileHash(ctx.data, id: concept.cid) == conceptHash else { return .changed(concept.id) }
    // 그림 코드는 판마다 파일 하나다 (figures/<단위 id>-r<판>.html). 고치지 않는다.
    for (path, code) in built.figures where !FileOps.exists(folder.url.appending(path: path)) {
      try FileOps.writeNew(code, to: folder.url.appending(path: path))
    }
    for line in built.history { try FileOps.appendLine(JSONText.line(line), to: folder.history) }
    try PageLock.withLock { try built.page.write(folder) }
    // 원문이 바뀌어 요구를 다시 확인해야 한다: 같은 요구로 다시 만든다
    for d in built.recheck {
      try DirectiveStore.update(ctx.data, id: d, status: .recheck)
      _ = await ctx.queueFollowUp("다시 만들기", { try Regen.prepare(directiveID: d, $0) })
    }
    let figureCount = built.page.units.filter(\.isFigure).count
    await ctx.log(.info, "[\(tag)] 페이지: 단위 \(built.page.units.count)개\(figureCount > 0 ? ", 그림 \(figureCount)개" : "")")
    return .written(concept.id)
  }

  // 저장된 페이지의 글 (학습 목표 시험을 다시 돌려 볼 때)
  public static func studyText(page: Page, concept: Concept) -> String {
    var out = ["# \(concept.title)"]
    for u in page.units {
      switch u.kind {
      case .para: out.append(u.text ?? "")
      case .note: out.append("[\(u.note?.rawValue ?? "note")] \(u.text ?? "")")
      case .step: out.append("  \(u.block?["tex"]?.string ?? "")  — \(u.text ?? "")")
      case .check:
        var lines = ["[Check] \(u.text ?? "")"]
        if let a = u.block?["answer"]?.string { lines.append("Answer: \(a)") }
        if let s = u.block?["solution"]?.string { lines.append("Solution: \(s)") }
        out.append(lines.joined(separator: "\n"))
      case .block:
        if u.isFigure {
          out.append("[Figure] \(u.block?["title"]?.string ?? "")\(u.caption.map { " — \($0)" } ?? "")")
        } else if u.isDerivation {
          out.append("[Worked solution] \(u.block?["title"]?.string ?? "")")
        } else if let tex = u.block?["tex"]?.string {
          out.append("\\[\(tex)\\]")
        }
      }
    }
    return out.joined(separator: "\n\n")
  }

  // 학습 목표 시험에 넘길 페이지 글: 문단(개념 원문), 상자, 풀이와 단계의 까닭, 수식, 그림 설명, 확인 문제와 답·풀이
  static func studyText(_ draft: Draft, concept: Concept) -> String {
    let unitText = Dictionary(concept.units.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
    var out = ["# \(concept.title)"]
    for u in draft.units {
      switch u.kind {
      case .para: out.append(unitText[u.from] ?? "")
      case .note: out.append("[\(u.note?.rawValue ?? "note")] \(u.text ?? "")")
      case .step: out.append("  \(u.spec?["tex"]?.string ?? "")  — \(u.text ?? "")")
      case .check:
        var lines = ["[Check] \(u.text ?? "")"]
        if let a = u.spec?["answer"]?.string { lines.append("Answer: \(a)") }
        if let s = u.spec?["solution"]?.string { lines.append("Solution: \(s)") }
        out.append(lines.joined(separator: "\n"))
      case .block:
        if let f = u.figure {
          out.append("[Figure] \(f.title)\(u.caption.map { " — \($0)" } ?? "")")
        } else if u.spec?["type"]?.string == "derivation" {
          out.append("[Worked solution] \(u.spec?["title"]?.string ?? "")")
        } else if let tex = u.tex ?? u.spec?["tex"]?.string {
          out.append("\\[\(tex)\\]")
        }
      }
    }
    return out.joined(separator: "\n\n")
  }

  struct FigureChecks: Sendable {
    // 파일 이름 → 문제
    var failed: [String: [String]] = [:]

    var problems: [String] { failed.keys.sorted().flatMap { f in failed[f]!.map { "out/figures/\(f): \($0)" } } }
  }

  // 그림 블록마다 블록 틀에 넣어 화면 밖 웹 보기에서 돌려 본다. 그림이 부른 바깥 파일은 이때 library/vendor/ 에 받아 둔다.
  static func checkFigures(_ draft: Draft?, ctx: JobContext, tag: String) async -> FigureChecks {
    var out = FigureChecks()
    let list = (draft?.units ?? []).compactMap(\.figure)
    guard !list.isEmpty else { return out }
    guard let checker = ctx.config.figureChecker else {
      await ctx.log(.warn, "[\(tag)] 그림 검사기가 없어 그림이 돌아가는지 보지 않았습니다")
      return out
    }
    let vendor = VendorStore(ctx.data)
    for f in list {
      let result = await checker.check(html: FigureFrame.compose(f.code), vendor: vendor)
      if !result.fetched.isEmpty { await ctx.log(.info, "[\(tag)] 그림 \(f.file): 바깥 파일 \(result.fetched.count)개를 받아 두었습니다") }
      if !result.problems.isEmpty { out.failed[f.file] = result.problems }
    }
    return out
  }

  // MARK: - 검사

  struct DraftFigure: Sendable {
    let file: String
    let title: String
    let code: String
  }

  struct DraftUnit: Sendable {
    let kind: PageUnitKind
    let from: String
    let prov: String
    var text: String? = nil
    var note: NoteKind? = nil
    var tex: String? = nil
    var figure: DraftFigure? = nil
    var caption: String? = nil
    // 풀이 블록 명세 (type, v, title, vars, check), 풀이 단계 (tex, expr, approx), 확인 문제 (answer, solution, verify)
    var spec: YAMLMap? = nil
  }

  static let figureSizeLimit = 400 * 1024

  struct Draft: Sendable {
    let titleKo: String
    let units: [DraftUnit]
  }

  struct Checked: Sendable {
    var draft: Draft?
    var problems: [String] = []
  }

  static func check(out: URL, concept: Concept, math: MathChecker?) -> Checked {
    var c = Checked()
    let v: JSONValue
    switch AgentJSON.read(out.appending(path: "page.json"), label: "out/page.json") {
    case .failure(let p):
      c.problems.append(p.message)
      return c
    case .success(let value): v = value
    }
    let titleKo = AgentJSON.string(v["title_ko"])
    if let titleKo { c.problems += TextChecks.koreanProblems(titleKo, field: "title_ko") } else { c.problems.append("title_ko 가 없습니다") }
    let parsed = parseUnits(v["units"]?.arrayValue ?? [], concept: concept, out: out, math: math, label: "units")
    c.problems += parsed.problems
    for id in concept.units.map(\.id) {
      switch parsed.paras[id] ?? 0 {
      case 0: c.problems.append("원문 단위 \(id) 의 문단(para)이 없습니다. 원문 단위마다 문단 하나를 둔다")
      case 1: break
      default: c.problems.append("원문 단위 \(id) 의 문단(para)이 둘 이상입니다")
      }
    }
    if c.problems.isEmpty, let titleKo { c.draft = Draft(titleKo: titleKo, units: parsed.units) }
    return c
  }

  // 페이지 단위 목록을 읽고 검사한다. 다시 만들기(예시 더, 그림으로, 단계 더)도 이것으로 새 단위를 본다.
  static func parseUnits(_ list: [JSONValue], concept: Concept, out: URL, math: MathChecker?, label: String) -> (
    units: [DraftUnit], paras: [String: Int], problems: [String]
  ) {
    var c = Checked()
    let unitIDs = Set(concept.units.map(\.id))
    var paras: [String: Int] = [:]
    var units: [DraftUnit] = []
    for (i, raw) in list.enumerated() {
      let at = "\(label)[\(i)]"
      guard let kindText = AgentJSON.string(raw["kind"]), let kind = PageUnitKind(rawValue: kindText), kind != .step else {
        c.problems.append("\(at).kind 는 para, note, block, check 가운데 하나다 (풀이 단계는 derivation 블록의 steps 에 쓴다)")
        continue
      }
      guard let from = AgentJSON.string(raw["from"]), unitIDs.contains(from) else {
        c.problems.append("\(at).from 은 input/concept.yaml 의 단위 id 다 (\(unitIDs.sorted().joined(separator: ", ")))")
        continue
      }
      switch kind {
      case .para:
        paras[from, default: 0] += 1
        units.append(DraftUnit(kind: .para, from: from, prov: "source"))
      case .step:
        continue
      case .check:
        // page.yaml 의 저장 모양(text 와 block 안의 answer)으로 써도 받는다
        let inner = raw["block"]
        guard let question = AgentJSON.string(raw["question"]) ?? AgentJSON.string(raw["text"]) ?? AgentJSON.string(inner?["question"]),
          let answer = AgentJSON.string(raw["answer"]) ?? AgentJSON.string(inner?["answer"])
        else {
          c.problems.append("\(at): 확인 문제에는 question 과 answer 가 있어야 한다")
          continue
        }
        let solution = AgentJSON.string(raw["solution"]) ?? AgentJSON.string(inner?["solution"])
        for (field, text) in [("question", question), ("answer", answer), ("solution", solution ?? "")] where !text.isEmpty {
          c.problems += TextChecks.englishProblems(text, field: "\(at).\(field)")
          if let math { c.problems += math.problems(inText: text, field: "\(at).\(field)") }
          c.problems += TexText.asciiMath(text, field: "\(at).\(field)")
        }
        var spec: YAMLMap = ["type": "check", "v": 1, "answer": .string(answer)]
        if let solution { spec["solution"] = .string(solution) }
        // 답을 계산으로 확인한다: verify.expr 의 값이 verify.equals 와 같아야 한다
        if let v = raw["verify"] ?? inner?["verify"], let expr = AgentJSON.string(v["expr"]), let equals = AgentJSON.string(v["equals"]) {
          c.problems += DerivationCheck.problems(
            steps: [.init(expr: expr, approx: false), .init(expr: equals, approx: equals.contains("."))], vars: [:], equation: nil, solution: [:],
            field: "\(at).verify")
          spec["verify"] = ["expr": .string(expr), "equals": .string(equals)]
        }
        let prov = AgentJSON.string(raw["prov"]) ?? "added"
        units.append(DraftUnit(kind: .check, from: from, prov: prov, text: question, spec: spec))
      case .block where AgentJSON.string(raw["block"]?["type"]) == "derivation":
        guard let block = raw["block"], let title = AgentJSON.string(block["title"]) else {
          c.problems.append("\(at).block.title 이 없습니다")
          continue
        }
        c.problems += TextChecks.englishProblems(title, field: "\(at).block.title")
        var vars: [String: ClosedRange<Double>] = [:]
        var varsYAML = YAMLMap([])
        for (name, range) in block["vars"]?.objectValue ?? [:] {
          let r = AgentJSON.numbers(range)
          guard r.count == 2, r[0] < r[1] else {
            c.problems.append("\(at).block.vars.\(name) 는 [아래, 위] 두 수다")
            continue
          }
          vars[name] = r[0]...r[1]
          varsYAML[name] = .array([.double(r[0]), .double(r[1])])
        }
        let rawSteps = block["steps"]?.arrayValue ?? []
        if rawSteps.count < 2 { c.problems.append("\(at).block.steps: 풀이 단계가 둘 이상 있어야 한다") }
        var steps: [DraftUnit] = []
        var checks: [DerivationCheck.Step] = []
        for (j, st) in rawSteps.enumerated() {
          guard let tex = AgentJSON.string(st["tex"]) else {
            c.problems.append("\(at).block.steps[\(j)].tex 가 없습니다")
            continue
          }
          // 까닭은 why 에 쓴다 (page.yaml 의 저장 모양인 text 로 써도 받는다)
          let why = AgentJSON.string(st["why"]) ?? AgentJSON.string(st["text"])
          if why == nil { c.problems.append("\(at).block.steps[\(j)].why 가 없습니다 (그 단계를 하는 까닭, 영어 한 문장)") }
          if let problem = math?.problem(tex, display: true) { c.problems.append("\(at).block.steps[\(j)].tex: 수식을 그릴 수 없습니다: \(problem)") }
          c.problems += TextChecks.englishProblems(tex, field: "\(at).block.steps[\(j)].tex")
          if let why {
            c.problems += TextChecks.englishProblems(why, field: "\(at).block.steps[\(j)].why")
            if let math { c.problems += math.problems(inText: why, field: "\(at).block.steps[\(j)].why") }
            c.problems += TexText.asciiMath(why, field: "\(at).block.steps[\(j)].why")
          }
          let expr = AgentJSON.string(st["expr"])
          let approx = tex.contains("\\approx") || st["approx"]?.boolValue == true
          checks.append(.init(expr: expr, approx: approx))
          var spec: YAMLMap = ["tex": .string(tex)]
          if let expr { spec["expr"] = .string(expr) }
          if approx { spec["approx"] = .bool(true) }
          steps.append(DraftUnit(kind: .step, from: from, prov: "source", text: why, spec: spec))
        }
        let equation = AgentJSON.string(block["check"]?["equation"])
        var solution: [String: String] = [:]
        for (k, v) in block["check"]?["solution"]?.objectValue ?? [:] { if let t = v.stringValue ?? v.numberValue.map({ YAML.formatNumber($0) }) { solution[k] = t } }
        c.problems += DerivationCheck.problems(steps: checks, vars: vars, equation: equation, solution: solution, field: "\(at).block")
        if checks.allSatisfy({ $0.expr == nil }) && equation == nil {
          c.problems.append("\(at).block: 계산으로 확인할 수 있게 단계의 expr 이나 check 를 하나 이상 둔다")
        }
        var spec: YAMLMap = ["type": "derivation", "v": 1, "title": .string(title)]
        if !varsYAML.isEmpty { spec["vars"] = .map(varsYAML.with(style: .flow)) }
        if let equation {
          spec["check"] = .map(["equation": .string(equation), "solution": .map(YAMLMap(solution.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }))])
        }
        units.append(DraftUnit(kind: .block, from: from, prov: "source", spec: spec))
        units += steps
      case .note:
        guard let noteText = AgentJSON.string(raw["note"]), let note = NoteKind(rawValue: noteText) else {
          c.problems.append("\(at).note 는 \(NoteKind.allCases.map(\.rawValue).joined(separator: ", ")) 가운데 하나다")
          continue
        }
        guard let text = AgentJSON.string(raw["text"]) else {
          c.problems.append("\(at).text 가 없습니다")
          continue
        }
        let prov = AgentJSON.string(raw["prov"]) ?? "source"
        if prov != "source" && prov != "added" { c.problems.append("\(at).prov 는 source 나 added 다") }
        c.problems += TextChecks.englishProblems(text, field: "\(at).text")
        for phrase in TextChecks.materialPhrases(text) { c.problems.append("\(at).text: 원래 자료가 있어야만 통하는 말입니다 (\"\(phrase)\")") }
        if let math { c.problems += math.problems(inText: text, field: "\(at).text") }
        c.problems += TexText.asciiMath(text, field: "\(at).text")
        units.append(DraftUnit(kind: .note, from: from, prov: prov, text: text, note: note))
      case .block where AgentJSON.string(raw["block"]?["type"]) == "figure":
        guard let file = AgentJSON.string(raw["block"]?["file"]), !file.contains("/"), !file.hasPrefix("."), file.hasSuffix(".html") else {
          c.problems.append("\(at).block.file 은 out/figures/ 안의 .html 파일 이름이다")
          continue
        }
        guard let data = try? Data(contentsOf: out.appending(path: "figures").appending(path: file)), let code = String(data: data, encoding: .utf8),
          !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          c.problems.append("\(at).block.file: out/figures/\(file) 가 없거나 비었습니다")
          continue
        }
        if data.count > figureSizeLimit { c.problems.append("\(at).block.file: 그림 코드가 너무 큽니다 (\(data.count / 1024)KB, 상한 \(figureSizeLimit / 1024)KB)") }
        if code.range(of: #"<\s*(html|head|body)[\s>]"#, options: [.regularExpression, .caseInsensitive]) != nil {
          c.problems.append("\(at).block.file: 그림 코드는 HTML 조각이다. <html>, <head>, <body> 를 쓰지 않는다")
        }
        guard let title = AgentJSON.string(raw["block"]?["title"]) else {
          c.problems.append("\(at).block.title 이 없습니다")
          continue
        }
        let caption = AgentJSON.string(raw["caption"])
        c.problems += TextChecks.englishProblems(title, field: "\(at).block.title")
        if let caption {
          c.problems += TextChecks.englishProblems(caption, field: "\(at).caption")
          if let math { c.problems += math.problems(inText: caption, field: "\(at).caption") }
          c.problems += TexText.asciiMath(caption, field: "\(at).caption")
        }
        if TextChecks.hasHangul(code) { c.problems.append("\(at).block.file: 그림 안의 글자는 영어다. 한글이 섞였습니다") }
        units.append(
          DraftUnit(kind: .block, from: from, prov: "source", figure: DraftFigure(file: file, title: title, code: code), caption: caption))
      case .block:
        let type = AgentJSON.string(raw["block"]?["type"])
        guard type == "math" else {
          c.problems.append("\(at).block.type 은 math, derivation, figure 가운데 하나다")
          continue
        }
        guard var tex = AgentJSON.string(raw["block"]?["tex"]) else {
          c.problems.append("\(at).block.tex 가 없습니다")
          continue
        }
        // \[ … \] 로 감싸 왔으면 벗긴다
        if tex.hasPrefix("\\[") && tex.hasSuffix("\\]") { tex = String(tex.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let problem = math?.problem(tex, display: true) { c.problems.append("\(at).block.tex: 수식을 그릴 수 없습니다: \(problem)") }
        c.problems += TextChecks.englishProblems(tex, field: "\(at).block.tex")
        units.append(DraftUnit(kind: .block, from: from, prov: "source", tex: tex))
      }
    }
    return (units, paras, c.problems)
  }

  // MARK: - 조합

  // 이전 페이지의 단위 id 를 이어 쓴다. (종류, 원문 단위, 그 안의 차례)가 같은 단위는 같은 id 이고, 내용이 바뀌었으면 판을 올린다.
  // 바뀌거나 빠진 이전 판은 history.jsonl 에 덧붙인다.
  // 살아 있는 요구(living)가 적용된 이전 단위는 원문 단위가 그대로면 그대로 옮긴다. 원문 단위가 바뀌었으면 새로 만들고 그 요구를 recheck 로 돌려준다.
  // 요구로 더해진 단위(inserting: 예시 더, 그림으로)는 초안의 단위와 짝짓지 않고, 이전 페이지에서 바로 앞에 있던 단위 뒤에 다시 넣는다.
  // 요구로 새 판이 된 풀이 블록은 그 단계들과 함께 옮기고, 초안의 그 풀이 단계는 버린다.
  static func assemble(
    _ draft: Draft, concept: Concept, old: Page?, provenance: YAMLMap, living: Set<String> = [], inserting: Set<String> = [],
    at: String = Clock.isoLocal()
  ) -> (page: Page, history: [JSONValue], figures: [(path: String, code: String)], recheck: [String]) {
    let unitByID = Dictionary(concept.units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    func key(_ kind: PageUnitKind, _ from: String, _ n: Int) -> String { "\(kind.rawValue)|\(from)|\(n)" }
    let oldUnits = old?.units ?? []
    func isLiving(_ u: PageUnit) -> Bool { !Set(u.directives).isDisjoint(with: living) }
    func isInserted(_ u: PageUnit) -> Bool { !Set(u.directives).isDisjoint(with: inserting) }
    let livingBlocks = Set(oldUnits.filter { $0.isDerivation && isLiving($0) && !isInserted($0) }.map(\.id))
    func isOwnedStep(_ u: PageUnit) -> Bool { u.parent.map(livingBlocks.contains) == true }
    var oldByKey: [String: PageUnit] = [:]
    var counts: [String: Int] = [:]
    for u in oldUnits where !isInserted(u) && !isOwnedStep(u) {
      let base = "\(u.kind.rawValue)|\(u.fromUnit)"
      counts[base, default: 0] += 1
      oldByKey[key(u.kind, u.fromUnit, counts[base]!)] = u
    }
    counts = [:]
    var next = old?.nextID ?? 1
    var units: [PageUnit] = []
    var history: [JSONValue] = []
    var kept: Set<String> = []
    var codes: [String: String] = [:]
    var recheck: [String] = []
    var skippingSteps = false
    for d in draft.units {
      guard let source = unitByID[d.from] else { continue }
      if d.kind == .step && skippingSteps { continue }
      skippingSteps = false
      let base = "\(d.kind.rawValue)|\(d.from)"
      counts[base, default: 0] += 1
      let previous = oldByKey[key(d.kind, d.from, counts[base]!)]
      var unit: PageUnit
      switch d.kind {
      case .para:
        unit = PageUnit(
          id: "", rev: 1, kind: .para, from: "\(source.id)@\(source.hash)", prov: source.claims.isEmpty ? "added" : "source", text: source.text,
          claims: source.claims, conditions: source.conditions)
      case .note:
        unit = PageUnit(id: "", rev: 1, kind: .note, from: "\(source.id)@\(source.hash)", prov: d.prov, text: d.text, note: d.note)
      case .step:
        unit = PageUnit(id: "", rev: 1, kind: .step, from: "\(source.id)@\(source.hash)", prov: "source", text: d.text, block: d.spec)
      case .check:
        unit = PageUnit(id: "", rev: 1, kind: .check, from: "\(source.id)@\(source.hash)", prov: d.prov, text: d.text, block: d.spec)
      case .block where d.spec != nil:
        unit = PageUnit(id: "", rev: 1, kind: .block, from: "\(source.id)@\(source.hash)", prov: "source", block: d.spec)
      case .block:
        if let f = d.figure {
          let block: YAMLMap = ["type": "figure", "v": 1, "title": .string(f.title), "code_hash": .string(Hash.short(Data(f.code.utf8))), "parts": .int(FigureFrame.partsVersion)]
          unit = PageUnit(id: "", rev: 1, kind: .block, from: "\(source.id)@\(source.hash)", prov: "source", block: block, caption: d.caption)
        } else {
          unit = PageUnit(id: "", rev: 1, kind: .block, from: "\(source.id)@\(source.hash)", prov: "source", block: ["type": "math", "v": 1, "tex": .string(d.tex ?? "")])
        }
      }
      if let previous, isLiving(previous) {
        if previous.fromHash == source.hash {
          kept.insert(previous.id)
          units.append(previous)
          if livingBlocks.contains(previous.id) {
            for s in oldUnits where s.parent == previous.id {
              kept.insert(s.id)
              units.append(s)
            }
            skippingSteps = true
          }
          continue
        }
        recheck += previous.directives.filter(living.contains)
      }
      if let previous {
        kept.insert(previous.id)
        unit = PageUnit(
          id: previous.id, rev: previous.rev, kind: unit.kind, from: unit.from, prov: unit.prov, text: unit.text, note: unit.note, block: unit.block,
          caption: unit.caption, claims: unit.claims, conditions: unit.conditions)
        if !unit.sameContent(previous) {
          unit.rev = previous.rev + 1
          history.append(historyLine(previous, reason: "replaced", at: at, provenance: provenance))
        }
      } else {
        unit = PageUnit(
          id: d.kind.prefix + String(next), rev: 1, kind: unit.kind, from: unit.from, prov: unit.prov, text: unit.text, note: unit.note, block: unit.block,
          caption: unit.caption, claims: unit.claims, conditions: unit.conditions)
        next += 1
      }
      if let f = d.figure {
        let path = "figures/\(unit.id)-r\(unit.rev).html"
        unit.block?["code"] = .string(path)
        codes[path] = f.code
      }
      units.append(unit)
    }
    // 요구로 더해졌거나 짝을 찾지 못한 살아 있는 이전 단위를 다시 넣는다. 이전 페이지에서 바로 앞에 있던 단위 뒤에 둔다.
    // 다시 만든 풀이 블록(id 가 남은 것)의 옛 단계는 넣지 않는다.
    for (i, u) in oldUnits.enumerated() where !kept.contains(u.id) && isLiving(u) {
      if let parent = u.parent, isOwnedStep(u), units.contains(where: { $0.id == parent }) { continue }
      guard let source = unitByID[u.fromUnit] else {
        recheck += u.directives.filter(living.contains)
        continue
      }
      if u.fromHash != source.hash { recheck += u.directives.filter(living.contains) }
      var at: Int?
      for prior in oldUnits[..<i].reversed() {
        guard let index = units.firstIndex(where: { $0.id == prior.id }) else { continue }
        at = index + 1
        // 앞 단위가 풀이 블록이나 그 단계면 이어지는 단계들 뒤에 둔다 (초안의 단계는 아직 parent 가 없다)
        while let j = at, j < units.count, units[j].kind == .step, prior.isDerivation || prior.kind == .step { at = j + 1 }
        break
      }
      let fallback = units.lastIndex { $0.fromUnit == u.fromUnit }.map { $0 + 1 } ?? units.count
      units.insert(u, at: min(at ?? fallback, units.count))
      kept.insert(u.id)
    }
    // 풀이 단계는 앞의 풀이 블록에 속한다
    var parent: String?
    for i in units.indices {
      if units[i].isDerivation { parent = units[i].id }
      if units[i].kind == .step { units[i].block?["parent"] = parent.map(YAMLValue.string) }
      if units[i].kind != .step && !units[i].isDerivation { parent = nil }
    }
    for u in old?.units ?? [] where !kept.contains(u.id) { history.append(historyLine(u, reason: "removed", at: at, provenance: provenance)) }
    return (
      Page(concept: concept.id, titleKo: draft.titleKo, nextID: next, units: units, provenance: provenance), history,
      codes.keys.sorted().map { ($0, codes[$0]!) }, Array(Set(recheck)).sorted()
    )
  }

  static func historyLine(_ unit: PageUnit, reason: String, at: String, provenance: YAMLMap) -> JSONValue {
    .object([
      "v": .number(1), "at": .string(at), "reason": .string(reason), "job": provenance["job"].map { $0.json } ?? .null,
      "unit": YAMLValue.map(unit.yaml).json,
    ])
  }
}
