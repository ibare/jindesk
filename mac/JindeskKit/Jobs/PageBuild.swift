// 학습 페이지 만들기 (page-build, JOBS.md). 개념 원문(concept.yaml)에서 학습 페이지(page.yaml)를 만든다. 개념마다 에이전트 하나, 셋씩 함께 돈다.
// 문단은 원문 단위의 글을 그대로 쓴다. 에이전트는 문단의 차례와 수식 블록, 강조 상자, 한국어 제목을 정하고, 러너가 원문 글을 넣는다.
// 시작할 때 페이지가 없거나 낡은 개념을 고른다. 낡은 것은 원문 단위의 해시가 바뀌었거나 지침 판이 바뀐 것이다.
// 지금은 글 블록 가운데 math 만 있다. 풀이(derivation)와 그림 블록은 다음에 붙인다.
import Foundation

public enum PageBuild {
  static let concurrency = 3
  static let prompt =
    "input/concept.yaml 의 개념으로 지침대로 학습 페이지를 짜라. 이전 페이지가 있으면 input/page.yaml 에 있다. out/page.json 을 쓴다."

  public static func prepare(subject: String, _ ctx: PrepareContext) throws -> PreparedJob {
    let id = try JobID.make(date: ctx.now, slugSource: "page \(subject)", exists: ctx.taken)
    return PreparedJob(id: id, kind: .pageBuild, title: subject, target: subject, coalesceKey: "page-build:\(subject)") { c in
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
    if old != nil { try FileOps.copy(folder.page, to: dirs.input.appending(path: "page.yaml")) }
    try AgentStep.writeGlossary(ctx.data, into: dirs.input)
    var request = ["# 학습 페이지 요청", "", "- 개념: \(concept.id)", "- 제목: \(concept.title)"]
    if let labels {
      request.append("- 과목: \(labels.name)")
      if !(labels.grades + labels.levels).isEmpty { request.append("- 학년·수준: \((labels.grades + labels.levels).joined(separator: ", "))") }
    }
    request.append("- 원문 단위: \(concept.units.map(\.id).joined(separator: ", "))")
    request.append("- 이전 페이지: \(old == nil ? "없다. 처음 만든다" : "input/page.yaml")")
    try FileOps.write(request.joined(separator: "\n") + "\n", to: dirs.input.appending(path: "request.md"))

    let tag = concept.cid.slug
    let options = AgentOptions(
      config: ctx.config, workspace: dirs.workspace, configDir: dirs.configDir, systemPromptFile: instructionsFile, eventsFile: dirs.events("page"),
      prompt: prompt, onEvent: { kind, message in if kind != .text { await ctx.log(kind, "[\(tag)] \(message)") } })
    let result = try await AgentStep.run(options, ctx, label: "\(tag) 페이지")
    var checked = check(out: dirs.out, concept: concept, math: math)
    if !checked.problems.isEmpty {
      await ctx.log(.warn, "[\(tag)] 검사에서 \(checked.problems.count)건이 나와 고쳐 쓰게 합니다: \(checked.problems.prefix(3).joined(separator: " · "))")
      try await AgentStep.fix(options, session: result.sessionID, problems: checked.problems, ctx: ctx, label: "\(tag) 페이지", events: "page-fix")
      checked = check(out: dirs.out, concept: concept, math: math)
    }
    guard checked.problems.isEmpty, let draft = checked.draft else {
      return .failed(concept.id, "검사 실패: " + checked.problems.prefix(5).joined(separator: " · "))
    }
    let built = assemble(draft, concept: concept, old: old, provenance: AgentStep.provenance(ctx, .pageBuild, instructions))
    // 쓰기 직전에 개념 원문이 그대로인지 다시 본다
    guard ConceptStore.fileHash(ctx.data, id: concept.cid) == conceptHash else { return .changed(concept.id) }
    for line in built.history { try FileOps.appendLine(JSONText.line(line), to: folder.history) }
    try built.page.write(folder)
    await ctx.log(.info, "[\(tag)] 페이지: 단위 \(built.page.units.count)개")
    return .written(concept.id)
  }

  // MARK: - 검사

  struct DraftUnit: Sendable {
    let kind: PageUnitKind
    let from: String
    let prov: String
    let text: String?
    let note: NoteKind?
    let tex: String?
  }

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
    let unitIDs = Set(concept.units.map(\.id))
    var paras: [String: Int] = [:]
    var units: [DraftUnit] = []
    for (i, raw) in (v["units"]?.arrayValue ?? []).enumerated() {
      let at = "units[\(i)]"
      guard let kindText = AgentJSON.string(raw["kind"]), let kind = PageUnitKind(rawValue: kindText) else {
        c.problems.append("\(at).kind 는 para, note, block 가운데 하나다")
        continue
      }
      guard let from = AgentJSON.string(raw["from"]), unitIDs.contains(from) else {
        c.problems.append("\(at).from 은 input/concept.yaml 의 단위 id 다 (\(unitIDs.sorted().joined(separator: ", ")))")
        continue
      }
      switch kind {
      case .para:
        paras[from, default: 0] += 1
        units.append(DraftUnit(kind: .para, from: from, prov: "source", text: nil, note: nil, tex: nil))
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
        units.append(DraftUnit(kind: .note, from: from, prov: prov, text: text, note: note, tex: nil))
      case .block:
        let type = AgentJSON.string(raw["block"]?["type"])
        guard type == "math" else {
          c.problems.append("\(at).block.type: 지금은 math 블록만 쓸 수 있다")
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
        units.append(DraftUnit(kind: .block, from: from, prov: "source", text: nil, note: nil, tex: tex))
      }
    }
    for id in concept.units.map(\.id) {
      switch paras[id] ?? 0 {
      case 0: c.problems.append("원문 단위 \(id) 의 문단(para)이 없습니다. 원문 단위마다 문단 하나를 둔다")
      case 1: break
      default: c.problems.append("원문 단위 \(id) 의 문단(para)이 둘 이상입니다")
      }
    }
    if c.problems.isEmpty, let titleKo { c.draft = Draft(titleKo: titleKo, units: units) }
    return c
  }

  // MARK: - 조합

  // 이전 페이지의 단위 id 를 이어 쓴다. (종류, 원문 단위, 그 안의 차례)가 같은 단위는 같은 id 이고, 내용이 바뀌었으면 판을 올린다.
  // 바뀌거나 빠진 이전 판은 history.jsonl 에 덧붙인다.
  static func assemble(_ draft: Draft, concept: Concept, old: Page?, provenance: YAMLMap, at: String = Clock.isoLocal()) -> (page: Page, history: [JSONValue]) {
    let unitByID = Dictionary(concept.units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    func key(_ kind: PageUnitKind, _ from: String, _ n: Int) -> String { "\(kind.rawValue)|\(from)|\(n)" }
    var oldByKey: [String: PageUnit] = [:]
    var counts: [String: Int] = [:]
    for u in old?.units ?? [] {
      let base = "\(u.kind.rawValue)|\(u.fromUnit)"
      counts[base, default: 0] += 1
      oldByKey[key(u.kind, u.fromUnit, counts[base]!)] = u
    }
    counts = [:]
    var next = old?.nextID ?? 1
    var units: [PageUnit] = []
    var history: [JSONValue] = []
    var kept: Set<String> = []
    for d in draft.units {
      guard let source = unitByID[d.from] else { continue }
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
      case .block:
        unit = PageUnit(id: "", rev: 1, kind: .block, from: "\(source.id)@\(source.hash)", prov: "source", block: ["type": "math", "v": 1, "tex": .string(d.tex ?? "")])
      }
      if let previous {
        kept.insert(previous.id)
        unit = PageUnit(
          id: previous.id, rev: previous.rev, kind: unit.kind, from: unit.from, prov: unit.prov, text: unit.text, note: unit.note, block: unit.block,
          claims: unit.claims, conditions: unit.conditions)
        if !unit.sameContent(previous) {
          unit.rev = previous.rev + 1
          history.append(historyLine(previous, reason: "replaced", at: at, provenance: provenance))
        }
      } else {
        unit = PageUnit(
          id: d.kind.prefix + String(next), rev: 1, kind: unit.kind, from: unit.from, prov: unit.prov, text: unit.text, note: unit.note, block: unit.block,
          claims: unit.claims, conditions: unit.conditions)
        next += 1
      }
      units.append(unit)
    }
    for u in old?.units ?? [] where !kept.contains(u.id) { history.append(historyLine(u, reason: "removed", at: at, provenance: provenance)) }
    return (Page(concept: concept.id, titleKo: draft.titleKo, nextID: next, units: units, provenance: provenance), history)
  }

  static func historyLine(_ unit: PageUnit, reason: String, at: String, provenance: YAMLMap) -> JSONValue {
    .object([
      "v": .number(1), "at": .string(at), "reason": .string(reason), "job": provenance["job"].map { $0.json } ?? .null,
      "unit": YAMLValue.map(unit.yaml).json,
    ])
  }
}
