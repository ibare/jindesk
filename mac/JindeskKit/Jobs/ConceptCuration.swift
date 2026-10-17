// 개념 정리 (concept-curation, JOBS.md). 아직 개념에 들어가지 않은 엔트리를 같은 개념끼리 묶어 개념 원문(concept.yaml)을 새로 쓰거나 보강한다.
// 시작할 때 할 일을 다시 고른다. 할 일이 없으면 실패 없이 끝난다. 한 건에 엔트리 열두 개까지 하고, 남으면 다음 건을 뒤따라 넣는다.
import Foundation

public enum ConceptCuration {
  static let batch = 12
  static let prompt =
    "input/request.md 의 엔트리들을 지침대로 개념으로 정리하라. 엔트리는 input/entries/, 이미 있는 개념은 input/concepts/ 에 있다. "
    + "결정은 out/plan.json 에, 짧은 기록은 out/report.md 에 쓴다."

  public static func prepare(subject: String, _ ctx: PrepareContext) throws -> PreparedJob {
    let id = try JobID.make(date: ctx.now, slugSource: "curate \(subject)", exists: ctx.taken)
    return PreparedJob(id: id, kind: .conceptCuration, title: subject, target: subject, coalesceKey: "concept-curation:\(subject)") { c in
      try await run(subject: subject, c)
    }
  }

  // 아직 개념에도, 보류에도 들어가지 않은 엔트리
  public static func pending(_ data: DataFolder, subject: String) -> [Entry] {
    let done = ConceptStore.curatedEntries(ConceptStore.all(data, subject: subject)).union(held(data, subject: subject))
    let library = SourceLibrary.load(data)
    let received = Dictionary(library.sources.map { ($0.id, $0.meta.received) }, uniquingKeysWith: { a, _ in a })
    return EntryStore.all(data, subject: subject).filter { !done.contains($0.id) }.sorted {
      (received[$0.source] ?? "", $0.source, $0.id) < (received[$1.source] ?? "", $1.source, $1.id)
    }
  }

  // 지난 개념 정리가 보류한 엔트리 (기록의 plan.json)
  static func held(_ data: DataFolder, subject: String) -> Set<String> {
    let root = data.records.appending(path: JobKind.conceptCuration.rawValue)
    var out: Set<String> = []
    for job in FileOps.list(root) where JobID.isValid(job) {
      guard let bytes = try? Data(contentsOf: root.appending(path: job).appending(path: "plan.json")), let plan = try? JSONValue.parse(bytes),
        plan["subject"]?.stringValue == subject
      else { continue }
      for h in plan["held"]?.arrayValue ?? [] { if let e = h["entry"]?.stringValue { out.insert(e) } }
    }
    return out
  }

  struct Input: Sendable {
    let subject: String
    // e01 → 엔트리
    let entries: [(key: String, entry: Entry)]
    // k01 → 개념
    let concepts: [(key: String, concept: Concept)]
    let conceptHashes: [String: String]
  }

  static func run(subject: String, _ ctx: JobContext) async throws {
    await ctx.setPhase("preparing")
    let all = pending(ctx.data, subject: subject)
    if all.isEmpty {
      await ctx.log(.info, "정리할 엔트리가 없습니다")
      await ctx.report(counts: [JobCount(key: "entries", label: "엔트리", count: 0)])
      return
    }
    let chosen = Array(all.prefix(batch))
    let concepts = ConceptStore.all(ctx.data, subject: subject)
    let input = Input(
      subject: subject, entries: chosen.enumerated().map { (String(format: "e%02d", $0.offset + 1), $0.element) },
      concepts: concepts.enumerated().map { (String(format: "k%02d", $0.offset + 1), $0.element) },
      conceptHashes: Dictionary(concepts.compactMap { c in ConceptStore.fileHash(ctx.data, id: c.cid).map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a }))
    let dirs = AgentDirs(ctx.folders, ctx.id)
    try dirs.make()
    let (instructions, instructionsFile) = try await AgentStep.fixInstructions(.conceptCuration, ctx, into: dirs.run)
    try writeInput(input, dirs: dirs, data: ctx.data)
    await ctx.log(.info, "엔트리 \(chosen.count)개 (남은 것 \(all.count - chosen.count)개), 이미 있는 개념 \(concepts.count)개")
    try ctx.checkCancellation()

    await ctx.setPhase("running")
    let options = AgentStep.options(ctx, dirs, instructions: instructionsFile, prompt: prompt, events: "curate")
    let result = try await AgentStep.run(options, ctx, label: "개념 정리")

    await ctx.setPhase("checking")
    let math = ctx.config.katex.flatMap(MathChecker.init(katex:))
    var checked = check(out: dirs.out, input: input, privacy: ctx.config.privacyTerms, math: math)
    if !checked.problems.isEmpty {
      await ctx.log(.warn, "검사에서 \(checked.problems.count)건이 나와 고쳐 쓰게 합니다")
      for p in checked.problems.prefix(20) { await ctx.log(.warn, p) }
      await ctx.setPhase("fixing")
      try await AgentStep.fix(options, session: result.sessionID, problems: checked.problems, ctx: ctx, label: "개념 정리", events: "curate-fix")
      await ctx.setPhase("checking")
      checked = check(out: dirs.out, input: input, privacy: ctx.config.privacyTerms, math: math)
    }
    guard checked.problems.isEmpty, let plan = checked.plan else {
      throw ToolError("개념 정리 검사 실패: " + checked.problems.prefix(10).joined(separator: " · "))
    }

    await ctx.setPhase("finalizing")
    // 반영 직전에 기준이 그대로인지 다시 본다
    for (_, c) in input.concepts where ConceptStore.fileHash(ctx.data, id: c.cid) != input.conceptHashes[c.id] {
      throw ToolError("정리하는 사이 개념이 바뀌었습니다: \(c.id). 다시 정리합니다")
    }
    let written = try apply(plan, input: input, data: ctx.data, provenance: AgentStep.provenance(ctx, .conceptCuration, instructions))
    let record = ctx.data.record(JobKind.conceptCuration.rawValue, ctx.id)
    try FileOps.writeNew(JSONText.record(plan.recordJSON(input: input, written: written)), to: record.appending(path: "plan.json"))
    let report = FileOps.readIfExists(dirs.out.appending(path: "report.md")) ?? ""
    let head: YAMLMap = [
      "kind": "curation-report", "v": 1, "job": .string(ctx.id), "subject": .string(subject),
      "concepts": .array(written.map { .string($0.id) }), "provenance": .map(AgentStep.provenance(ctx, .conceptCuration, instructions)),
    ]
    try FileOps.writeNew(FrontMatter.render(head) + "\n" + report.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", to: record.appending(path: "report.md"))

    let created = plan.concepts.filter { $0.existing == nil }.count
    await ctx.report(counts: [
      JobCount(key: "entries", label: "엔트리", count: chosen.count), JobCount(key: "created", label: "새 개념", count: created),
      JobCount(key: "updated", label: "보강", count: plan.concepts.count - created), JobCount(key: "held", label: "보류", count: plan.held.count),
    ])
    for c in written { await ctx.log(.info, "개념: \(c.id) (단위 \(c.units.count)개)") }
    for h in plan.held { await ctx.log(.info, "보류: \(h.entry) — \(h.reason)") }

    if !written.isEmpty, await ctx.queueFollowUp("학습 페이지 만들기", { try PageBuild.prepare(subject: subject, $0) }) != nil {
      await ctx.log(.info, "학습 페이지 만들기를 대기열에 넣었습니다")
    }
    if all.count > chosen.count, await ctx.queueFollowUp("개념 정리", { try prepare(subject: subject, $0) }) != nil {
      await ctx.log(.info, "남은 엔트리 \(all.count - chosen.count)개의 개념 정리를 대기열에 넣었습니다")
    }
  }

  // MARK: - 입력

  static func writeInput(_ input: Input, dirs: AgentDirs, data: DataFolder) throws {
    var request = ["# 개념 정리 요청", "", "- 과목 id: \(input.subject)"]
    let library = SourceLibrary.load(data)
    if let s = library.subjects.first(where: { $0.id == input.subject }) {
      request.append("- 과목 꼬리표: \(s.name)")
      if !s.grades.isEmpty { request.append("- 학년: \(s.grades.joined(separator: ", "))") }
      if !s.levels.isEmpty { request.append("- 수준: \(s.levels.joined(separator: ", "))") }
    }
    request.append("- 목차: \(FileOps.exists(data.syllabusFile(input.subject)) ? "input/syllabus.yaml" : "아직 없다. 모든 개념이 목차 밖이다")")
    request += ["", "## 정리할 엔트리", "", "| 키 | 제목 | 자료 | 쪽 |", "|---|---|---|---|"]
    for (key, e) in input.entries {
      let name = library.source(e.source)?.meta.original.name ?? e.source
      request.append("| \(key) | \(e.title) | \(e.source) (\(name)) | \(e.pages.map(String.init).joined(separator: ", ")) |")
      try FileOps.write(e.markdown, to: dirs.input.appending(path: "entries/\(key).md"))
    }
    request += ["", "## 이미 있는 개념", ""]
    if input.concepts.isEmpty { request.append("아직 없다.") } else {
      request += ["| 키 | 제목 | 항목·단원 제안 | 단위 수 |", "|---|---|---|---|"]
    }
    for (key, c) in input.concepts {
      request.append("| \(key) | \(c.title) | \(c.item ?? c.itemProposed ?? "") | \(c.units.count) |")
      try FileOps.write(YAML.stringify(c.yaml), to: dirs.input.appending(path: "concepts/\(key).yaml"))
    }
    try FileOps.write(request.joined(separator: "\n") + "\n", to: dirs.input.appending(path: "request.md"))
    if FileOps.exists(data.syllabusFile(input.subject)) { try FileOps.copy(data.syllabusFile(input.subject), to: dirs.input.appending(path: "syllabus.yaml")) }
    if FileOps.exists(data.glossaryFile) { try FileOps.copy(data.glossaryFile, to: dirs.input.appending(path: "glossary.yaml")) }
  }

  // MARK: - 검사

  struct PlannedUnit: Sendable {
    let id: String?
    let text: String
    let conditions: [String]
    let claims: [(text: String, src: [String])]
  }

  struct PlannedConcept: Sendable {
    // 보강하는 기존 개념의 키 (k01). 새 개념이면 nil
    let existing: String?
    let slug: String
    let title: String
    let item: String?
    let entries: [String]
    let symbols: [SymbolDef]
    let units: [PlannedUnit]
    let removed: [(id: String, reason: String)]
  }

  struct Plan: Sendable {
    let concepts: [PlannedConcept]
    let held: [(entry: String, reason: String)]

    func recordJSON(input: Input, written: [Concept]) -> JSONValue {
      let entryID = Dictionary(input.entries.map { ($0.key, $0.entry.id) }, uniquingKeysWith: { a, _ in a })
      let conceptID = Dictionary(input.concepts.map { ($0.key, $0.concept.id) }, uniquingKeysWith: { a, _ in a })
      return .object([
        "v": .number(1),
        "subject": .string(input.subject),
        "concepts": .array(
          zip(concepts, written).map { p, c in
            .object([
              "concept": .string(c.id), "action": .string(p.existing == nil ? "new" : "update"),
              "previous": p.existing.flatMap { conceptID[$0] }.map(JSONValue.string) ?? .null,
              "entries": .array(p.entries.compactMap { entryID[$0] }.map(JSONValue.string)),
              "removed_units": .array(p.removed.map { .object(["id": .string($0.id), "reason": .string($0.reason)]) }),
            ])
          }),
        "held": .array(held.map { .object(["entry": .string(entryID[$0.entry] ?? $0.entry), "reason": .string($0.reason)]) }),
      ])
    }
  }

  struct Checked: Sendable {
    var plan: Plan?
    var problems: [String] = []
  }

  static func check(out: URL, input: Input, privacy: [String], math: MathChecker?) -> Checked {
    var c = Checked()
    let v: JSONValue
    switch AgentJSON.read(out.appending(path: "plan.json"), label: "out/plan.json") {
    case .failure(let p):
      c.problems.append(p.message)
      return c
    case .success(let value): v = value
    }
    let entryKeys = Set(input.entries.map(\.key))
    let conceptByKey = Dictionary(input.concepts.map { ($0.key, $0.concept) }, uniquingKeysWith: { a, _ in a })
    let entryByKey = Dictionary(input.entries.map { ($0.key, $0.entry) }, uniquingKeysWith: { a, _ in a })
    var placedEntries: [String: Int] = [:]
    var usedConcepts: Set<String> = []
    var concepts: [PlannedConcept] = []

    for (i, raw) in (v["concepts"]?.arrayValue ?? []).enumerated() {
      let at = "concepts[\(i)]"
      var problems: [String] = []
      let existingKey = AgentJSON.string(raw["concept"])
      let existing = existingKey.flatMap { conceptByKey[$0] }
      if let key = existingKey {
        if existing == nil { problems.append("\(at).concept: 없는 개념 키입니다 (\(key))") }
        if !usedConcepts.insert(key).inserted { problems.append("\(at).concept: 같은 개념(\(key))이 두 번 나옵니다") }
      }
      let title = AgentJSON.string(raw["title"]) ?? existing?.title
      if title == nil { problems.append("\(at).title 이 없습니다") }
      let slugSource = AgentJSON.string(raw["slug"]) ?? title ?? ""
      let slug = existing?.cid.slug ?? JobID.slugify(slugSource, maxLength: 60)
      if slug.isEmpty { problems.append("\(at).slug 가 없습니다") }
      let entries = AgentJSON.strings(raw["entries"])
      for e in entries {
        if !entryKeys.contains(e) { problems.append("\(at).entries: 없는 엔트리 키입니다 (\(e))") }
        placedEntries[e, default: 0] += 1
      }
      if entries.isEmpty && existing == nil { problems.append("\(at).entries 가 비었습니다") }

      // 출처로 쓸 수 있는 쪽: 이 개념에 넣은 엔트리의 출처와 기존 개념의 출처
      var allowed = existing?.refs ?? []
      for e in entries { allowed.formUnion(entryByKey[e]?.refs ?? []) }

      var units: [PlannedUnit] = []
      let existingIDs = Set(existing?.units.map(\.id) ?? [])
      var seenIDs: Set<String> = []
      for (j, u) in (raw["units"]?.arrayValue ?? []).enumerated() {
        let uat = "\(at).units[\(j)]"
        let id = AgentJSON.string(u["id"])
        if let id {
          if !existingIDs.contains(id) { problems.append("\(uat).id: 이 개념에 없는 단위입니다 (\(id)). 새 단위는 id 를 null 로 둔다") }
          if !seenIDs.insert(id).inserted { problems.append("\(uat).id: 같은 단위(\(id))가 두 번 나옵니다") }
        }
        guard let text = AgentJSON.string(u["text"]) else {
          problems.append("\(uat).text 가 없습니다")
          continue
        }
        var claims: [(text: String, src: [String])] = []
        for (k, cl) in (u["claims"]?.arrayValue ?? []).enumerated() {
          guard let ct = AgentJSON.string(cl["text"]) else {
            problems.append("\(uat).claims[\(k)].text 가 없습니다")
            continue
          }
          let src = AgentJSON.strings(cl["src"])
          if src.isEmpty { problems.append("\(uat).claims[\(k)]: 출처(src)가 없습니다") }
          for s in src where !allowed.contains(s) {
            problems.append("\(uat).claims[\(k)]: 이 개념에 넣은 엔트리에 없는 출처입니다 (\(s)). 정리는 새 출처를 만들지 못한다")
          }
          claims.append((ct, src))
        }
        let conditions = AgentJSON.strings(u["conditions"])
        var english = [("\(uat).text", text)] + conditions.map { ("\(uat).conditions", $0) }
        english += claims.enumerated().map { ("\(uat).claims[\($0.offset)].text", $0.element.text) }
        for (field, t) in english {
          problems += TextChecks.englishProblems(t, field: field, privacy: privacy)
          for phrase in TextChecks.materialPhrases(t) { problems.append("\(field): 원래 자료가 있어야만 통하는 말입니다 (\"\(phrase)\")") }
          if let math { problems += math.problems(inText: t, field: field) }
        }
        units.append(PlannedUnit(id: id, text: text, conditions: conditions, claims: claims))
      }
      if units.isEmpty { problems.append("\(at).units 가 비었습니다") }
      var removed: [(id: String, reason: String)] = []
      for r in raw["removed_units"]?.arrayValue ?? [] {
        guard let id = AgentJSON.string(r["id"]) else { continue }
        let reason = AgentJSON.string(r["reason"])
        if reason == nil { problems.append("\(at).removed_units: \(id) 를 뺀 까닭(reason)이 없습니다") }
        if !existingIDs.contains(id) { problems.append("\(at).removed_units: 이 개념에 없는 단위입니다 (\(id))") }
        removed.append((id, reason ?? ""))
      }
      for id in existingIDs.subtracting(seenIDs).subtracting(removed.map(\.id)).sorted() {
        problems.append("\(at): 기존 단위 \(id) 가 빠졌습니다. 그대로 두려면 units 에 id 와 함께 넣고, 빼려면 removed_units 에 까닭을 적는다")
      }
      let symbols = AgentJSON.symbols(raw["symbols"])
      let item = AgentJSON.string(raw["item"])
      if let title { problems += TextChecks.englishProblems(title, field: "\(at).title", privacy: privacy) }
      if let item { problems += TextChecks.englishProblems(item, field: "\(at).item", privacy: privacy) }
      for s in symbols { problems += TextChecks.englishProblems(s.meaning, field: "\(at).symbols \(s.symbol)", privacy: privacy) }
      c.problems += problems
      if problems.isEmpty, let title {
        concepts.append(
          PlannedConcept(
            existing: existing == nil ? nil : existingKey, slug: slug, title: title, item: item, entries: entries, symbols: symbols, units: units,
            removed: removed))
      }
    }

    var held: [(entry: String, reason: String)] = []
    for h in v["held"]?.arrayValue ?? [] {
      guard let e = AgentJSON.string(h["entry"]) else { continue }
      if !entryKeys.contains(e) { c.problems.append("held: 없는 엔트리 키입니다 (\(e))") }
      guard let reason = AgentJSON.string(h["reason"]) else {
        c.problems.append("held: \(e) 를 보류한 까닭(reason)이 없습니다")
        continue
      }
      c.problems += TextChecks.recordProblems(reason, field: "held \(e)", privacy: privacy)
      placedEntries[e, default: 0] += 1
      held.append((e, reason))
    }
    for key in entryKeys.sorted() {
      switch placedEntries[key] ?? 0 {
      case 0: c.problems.append("엔트리 \(key) 가 어느 개념에도, 보류에도 없습니다")
      case 1: break
      default: c.problems.append("엔트리 \(key) 가 두 곳 이상에 들어갔습니다")
      }
    }
    if c.problems.isEmpty { c.plan = Plan(concepts: concepts, held: held) }
    return c
  }

  // MARK: - 반영

  static func apply(_ plan: Plan, input: Input, data: DataFolder, provenance: YAMLMap) throws -> [Concept] {
    let syllabus = Syllabus.load(data, subject: input.subject)
    let conceptByKey = Dictionary(input.concepts.map { ($0.key, $0.concept) }, uniquingKeysWith: { a, _ in a })
    let entryByKey = Dictionary(input.entries.map { ($0.key, $0.entry) }, uniquingKeysWith: { a, _ in a })
    var taken = Set(input.concepts.map { $0.concept.cid.slug })
    var out: [Concept] = []
    for p in plan.concepts {
      var concept: Concept
      if let key = p.existing, let old = conceptByKey[key] {
        concept = old
        concept.title = p.title
        if old.item == nil { concept.itemProposed = p.item ?? old.itemProposed }
      } else {
        var slug = p.slug
        if taken.contains(slug) {
          var n = 2
          while taken.contains("\(p.slug)-\(n)") { n += 1 }
          slug = "\(p.slug)-\(n)"
        }
        taken.insert(slug)
        let item = syllabus?.item(p.item)
        concept = Concept(
          cid: ConceptID(subject: input.subject, item: ItemPath.dir(item?.code), slug: slug), title: p.title,
          itemProposed: item == nil ? p.item : nil, level: item?.level, occurrences: [], symbols: [], nextID: 1, units: [], provenance: provenance)
      }
      var next = concept.nextID
      concept.units = p.units.map { u in
        let id: String
        if let existing = u.id {
          id = existing
        } else {
          id = "u\(next)"
          next += 1
        }
        let claims = u.claims.enumerated().map { UnitClaim(id: "c\($0.offset + 1)", text: $0.element.text, src: $0.element.src) }
        return ConceptUnit(id: id, text: u.text, conditions: u.conditions, claims: claims)
      }
      concept.nextID = next
      if !p.symbols.isEmpty { concept.symbols = p.symbols }
      for key in p.entries {
        guard let e = entryByKey[key], !concept.occurrences.contains(where: { $0.entry == e.id }) else { continue }
        concept.occurrences.append(Occurrence(entry: e.id, source: e.source, pages: e.pages))
      }
      concept.provenance = provenance
      out.append(concept)
    }
    for c in out { try c.write(data) }
    return out
  }
}
