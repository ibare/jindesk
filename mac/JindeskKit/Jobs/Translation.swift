// 번역 (translation, JOBS.md). 학습 페이지의 영어 단위마다 곁 층의 한국어를 쓴다. 개념마다 에이전트 하나, 셋씩 함께 돈다.
// 시작할 때 한국어가 없거나 낡은 단위를 고른다. 낡은 것은 한국어를 만든 단위의 판이나 해시가 지금과 다른 것이다.
// 러너 검사: 숫자와 수식이 영어와 같은지, 영어 문장이 남지 않았는지, 어휘의 용어를 정해진 한국어로 옮겼는지, 길이 비율.
import Foundation

public enum Translation {
  static let concurrency = 3
  static let prompt = "input/targets.json 의 단위들을 지침대로 한국어로 옮겨라. 맥락은 input/page.yaml, 용어는 input/glossary.yaml 에 있다. out/layers.json 을 쓴다."

  public static func prepare(subject: String, _ ctx: PrepareContext) throws -> PreparedJob {
    let id = try JobID.make(date: ctx.now, slugSource: "translate \(subject)", exists: ctx.taken)
    return PreparedJob(id: id, kind: .translation, title: subject, target: subject, coalesceKey: "translation:\(subject)") { c in
      try await run(subject: subject, c)
    }
  }

  // 옮길 단위: 글이 있는 단위(문단, 강조 상자, 그림 설명) 가운데 한국어가 없거나 낡은 것
  public static func targets(_ page: Page, layers: Layers?) -> [PageUnit] {
    page.units.filter { u in
      guard u.english != nil else { return false }
      guard let ko = layers?.ko[u.id] else { return true }
      return !ko.isCurrent(for: u)
    }
  }

  public static func pending(_ data: DataFolder, subject: String) -> [(Concept, Page)] {
    ConceptStore.all(data, subject: subject).compactMap { c in
      let folder = ConceptFolder(c.cid, in: data)
      guard let page = Page.load(folder), !targets(page, layers: Layers.load(folder)).isEmpty else { return nil }
      return (c, page)
    }
  }

  static func run(subject: String, _ ctx: JobContext) async throws {
    await ctx.setPhase("preparing")
    let todo = pending(ctx.data, subject: subject)
    if todo.isEmpty {
      await ctx.log(.info, "옮길 단위가 없습니다")
      await ctx.report(counts: [JobCount(key: "units", label: "단위", count: 0)])
      return
    }
    let (instructions, instructionsFile) = try await AgentStep.fixInstructions(.translation, ctx, into: ctx.folders.workDir(ctx.id))
    await ctx.log(.info, "페이지 \(todo.count)개: \(todo.map(\.0.cid.slug).joined(separator: ", "))")

    await ctx.setPhase("running")
    var done = 0
    var skipped = 0
    var warnings: [String] = []
    var proposedTerms: [(en: String, ko: String)] = []
    try await withThrowingTaskGroup(of: Outcome.self) { group in
      var next = 0
      func add() {
        guard next < todo.count else { return }
        let (concept, page) = todo[next]
        let n = next + 1
        next += 1
        group.addTask {
          do {
            return try await translateOne(concept, page: page, n: n, ctx: ctx, instructions: instructions, instructionsFile: instructionsFile)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            return Outcome(concept: concept.id, written: 0, skipped: 0, terms: [], warnings: ["\(concept.id): \(error.localizedDescription)"])
          }
        }
      }
      for _ in 0..<concurrency { add() }
      while let o = try await group.next() {
        done += o.written
        skipped += o.skipped
        warnings += o.warnings
        proposedTerms += o.terms
        add()
      }
    }

    await ctx.setPhase("finalizing")
    if !proposedTerms.isEmpty {
      let merged = try Glossary.lock.withLock {
        var glossary = Glossary.load(ctx.data)
        let result = glossary.merge(proposedTerms, subject: subject)
        if !result.added.isEmpty || !result.aliased.isEmpty { try glossary.write(ctx.data) }
        return result
      }
      if !merged.added.isEmpty { await ctx.log(.info, "새 용어 \(merged.added.count)개: \(merged.added.joined(separator: ", "))") }
      for c in merged.conflicts { await ctx.log(.warn, "용어: \(c)") }
    }
    for w in warnings { await ctx.log(.warn, w) }
    await ctx.report(
      counts: [JobCount(key: "units", label: "단위", count: done), JobCount(key: "skipped", label: "못 옮김", count: skipped)],
      warnings: warnings.isEmpty ? nil : warnings)
    if done == 0 && !warnings.isEmpty { throw ToolError("한 단위도 옮기지 못했습니다") }
  }

  struct Outcome: Sendable {
    let concept: String
    let written: Int
    let skipped: Int
    let terms: [(en: String, ko: String)]
    let warnings: [String]
  }

  static func translateOne(_ concept: Concept, page: Page, n: Int, ctx: JobContext, instructions: Instructions, instructionsFile: URL) async throws -> Outcome {
    let folder = ConceptFolder(concept.cid, in: ctx.data)
    let layers = Layers.load(folder) ?? Layers(concept: concept.id)
    let targets = targets(page, layers: layers)
    let glossary = Glossary.load(ctx.data)
    let dirs = AgentDirs(ctx.folders, ctx.id, sub: "c\(n)")
    try dirs.make()
    try FileOps.copy(folder.page, to: dirs.input.appending(path: "page.yaml"))
    try AgentStep.writeGlossary(ctx.data, into: dirs.input)
    let list: JSONValue = .array(targets.map { .object(["id": .string($0.id), "kind": .string($0.isFigure ? "caption" : $0.kind.rawValue), "text": .string($0.english ?? "")]) })
    try FileOps.write(JSONText.record(list), to: dirs.input.appending(path: "targets.json"))

    let tag = concept.cid.slug
    let options = AgentOptions(
      config: ctx.config, workspace: dirs.workspace, configDir: dirs.configDir, systemPromptFile: instructionsFile, eventsFile: dirs.events("translate"),
      prompt: prompt, onEvent: { kind, message in if kind != .text { await ctx.log(kind, "[\(tag)] \(message)") } })
    let result = try await AgentStep.run(options, ctx, label: "\(tag) 번역")
    var checked = check(out: dirs.out, targets: targets, glossary: glossary)
    if !checked.problems.isEmpty {
      await ctx.log(.warn, "[\(tag)] 검사에서 \(checked.problems.count)건이 나와 고쳐 쓰게 합니다: \(checked.problems.prefix(3).joined(separator: " · "))")
      try await AgentStep.fix(options, session: result.sessionID, problems: checked.problems, ctx: ctx, label: "\(tag) 번역", events: "translate-fix")
      checked = check(out: dirs.out, targets: targets, glossary: glossary)
    }
    // 반영 직전에 페이지가 그대로인지 다시 본다
    guard let current = Page.load(folder), current == page else {
      return Outcome(concept: concept.id, written: 0, skipped: targets.count, terms: [], warnings: ["\(concept.id): 옮기는 사이 페이지가 바뀌어 쓰지 않았습니다"])
    }
    var fresh = Layers.load(folder) ?? Layers(concept: concept.id)
    let prov: YAMLMap = ["job": .string(ctx.id), "instructions": .map(instructions.provenance(.translation)), "model": .string(ctx.config.model)]
    for u in targets {
      guard let text = checked.accepted[u.id] else { continue }
      fresh.ko[u.id] = LayerText(from: u.ref, unitHash: u.hash, text: text, prov: prov)
    }
    if !checked.accepted.isEmpty { try fresh.write(folder, order: page.units.map(\.id)) }
    let rejected = targets.filter { checked.accepted[$0.id] == nil }
    await ctx.log(.info, "[\(tag)] 한국어 \(checked.accepted.count)개\(rejected.isEmpty ? "" : ", 못 옮김 \(rejected.count)개")")
    return Outcome(
      concept: concept.id, written: checked.accepted.count, skipped: rejected.count, terms: checked.terms,
      warnings: rejected.map { u in "\(concept.id)#\(u.id): \(checked.unitProblems[u.id]?.prefix(2).joined(separator: " · ") ?? "옮기지 못했습니다")" })
  }

  // MARK: - 검사

  struct Checked: Sendable {
    var accepted: [String: String] = [:]
    var unitProblems: [String: [String]] = [:]
    var terms: [(en: String, ko: String)] = []
    var general: [String] = []

    var problems: [String] { general + unitProblems.keys.sorted().flatMap { id in unitProblems[id]!.map { "\(id): \($0)" } } }
  }

  static func check(out: URL, targets: [PageUnit], glossary: Glossary) -> Checked {
    var c = Checked()
    let v: JSONValue
    switch AgentJSON.read(out.appending(path: "layers.json"), label: "out/layers.json") {
    case .failure(let p):
      c.general.append(p.message)
      for u in targets { c.unitProblems[u.id] = ["번역이 없습니다"] }
      return c
    case .success(let value): v = value
    }
    let units = v["units"]?.objectValue ?? [:]
    for u in targets {
      guard let ko = AgentJSON.string(units[u.id]) else {
        c.unitProblems[u.id] = ["번역이 없습니다"]
        continue
      }
      let problems = unitProblems(en: u.english ?? "", ko: ko, glossary: glossary)
      if problems.isEmpty { c.accepted[u.id] = ko } else { c.unitProblems[u.id] = problems }
    }
    for t in v["terms"]?.arrayValue ?? [] {
      guard let en = AgentJSON.string(t["en"]), let ko = AgentJSON.string(t["ko"]) else { continue }
      if TextChecks.hasHangul(ko) && !TextChecks.hasHanOrKana(ko) && !TextChecks.hasHangul(en) { c.terms.append((en, ko)) }
    }
    return c
  }

  // 영어 단위 하나와 그 한국어를 견준다
  static func unitProblems(en: String, ko: String, glossary: Glossary) -> [String] {
    var out = TextChecks.koreanProblems(ko, field: "한국어")
    let enTex = TexText.segments(en).map { TexText.key($0.tex) }.sorted()
    let koTex = TexText.segments(ko).map { TexText.key($0.tex) }.sorted()
    if enTex != koTex { out.append("수식이 영어와 다릅니다. 수식은 \\( … \\), \\[ … \\] 그대로 옮긴다 (영어 \(enTex.count)개, 한국어 \(koTex.count)개)") }
    let enNumbers = TexText.numbers(en).sorted()
    let koNumbers = TexText.numbers(ko).sorted()
    if enNumbers != koNumbers { out.append("수식 밖의 숫자가 영어와 다릅니다 (영어 \(enNumbers.joined(separator: " ")), 한국어 \(koNumbers.joined(separator: " ")))") }
    if let left = leftoverEnglish(ko) { out.append("영어 문장이 남았습니다: \"\(left)\"") }
    for term in glossary.terms where mentions(en, term) && !ko.contains(term.ko) {
      out.append("용어 \(term.en) 는 \(term.ko) 로 옮긴다")
    }
    let enLength = TexText.strip(en).count
    let koLength = TexText.strip(ko).count
    if enLength >= 40 {
      let ratio = Double(koLength) / Double(enLength)
      if ratio < 0.15 || ratio > 1.5 { out.append("길이가 영어와 너무 다릅니다 (영어 \(enLength)자, 한국어 \(koLength)자). 빠지거나 더한 내용이 없게 옮긴다") }
    }
    return out
  }

  // 괄호 밖에 영어 낱말이 여섯 개 이상 이어지면 옮기지 않은 문장으로 본다
  static func leftoverEnglish(_ ko: String) -> String? {
    var plain = TexText.strip(ko)
    plain = plain.replacingOccurrences(of: #"\([^()]*\)"#, with: " ", options: .regularExpression)
    let regex = try! NSRegularExpression(pattern: #"(?:[A-Za-z][A-Za-z'’-]*[\s,]+){5,}[A-Za-z][A-Za-z'’-]*"#)
    guard let m = regex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)), let r = Range(m.range, in: plain) else { return nil }
    return FileOps.prefix(String(plain[r]), 80)
  }

  // 영어 글에 그 용어(또는 다른 이름)가 나오는가. 복수형(-s, -es)도 같게 본다.
  static func mentions(_ en: String, _ term: GlossaryTerm) -> Bool {
    let plain = TexText.strip(en)
    return term.names.contains { name in
      let escaped = NSRegularExpression.escapedPattern(for: name)
      return plain.range(of: "\\b\(escaped)(?:s|es)?\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
  }
}
