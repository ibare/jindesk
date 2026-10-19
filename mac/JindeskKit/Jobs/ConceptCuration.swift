// 개념 정리 (concept-curation, JOBS.md). 묶음 하나의 아직 정리하지 않은 엔트리를 모두 한 번에 같은 개념끼리 묶어
// 개념 원문(concept.yaml)을 새로 쓰거나 보강한다 (DECISIONS.md 35). 그 과목의 보류된 엔트리도 까닭과 함께 다시 받아, 맞는 개념이 있으면 붙인다.
// 시작할 때 할 일을 다시 고른다. 할 일이 없으면 실패 없이 끝난다.
import Foundation

public enum ConceptCuration {
  static let prompt =
    "input/request.md 의 엔트리들을 지침대로 개념으로 정리하라. 정리할 엔트리는 input/entries/, 보류된 엔트리는 input/held/, 이미 있는 개념은 input/concepts/ 에 있다. "
    + "결정은 out/plan.json 에, 짧은 기록은 out/report.md 에 쓴다."

  public static func prepare(bundle: String, _ ctx: PrepareContext) throws -> PreparedJob {
    let library = SourceLibrary.load(ctx.data)
    let found = BundleStore.bundle(ctx.data, id: bundle, library: library)
    let name = found?.title ?? found?.sources.first.flatMap { library.source($0)?.meta.original.name } ?? bundle
    let id = try JobID.make(date: ctx.now, slugSource: "curate \(found?.title ?? bundle)", exists: ctx.taken)
    return PreparedJob(id: id, kind: .conceptCuration, title: name, target: bundle, coalesceKey: "concept-curation:\(bundle)", recipe: .conceptCuration(bundle: bundle)) { c in
      try await run(bundle: bundle, c)
    }
  }

  // 그 묶음의 아직 개념에도, 보류에도 들어가지 않은 엔트리. 엔트리의 묶음은 첫 자료로 정한다.
  public static func pending(_ data: DataFolder, bundle: SourceBundle) -> [Entry] {
    let library = SourceLibrary.load(data)
    guard let subject = BundleStore.subject(bundle, library: library) else { return [] }
    return pending(bundle: bundle, in: SubjectEntries(data, subject: subject))
  }

  public static func pending(bundle: SourceBundle, in subject: SubjectEntries) -> [Entry] {
    let members = Set(bundle.sources)
    let order = Dictionary(bundle.sources.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    return subject.entries.filter { members.contains($0.source) && !subject.done.contains($0.id) }.sorted {
      (order[$0.source] ?? 0, $0.id) < (order[$1.source] ?? 0, $1.id)
    }
  }

  // 과목의 엔트리와, 이미 개념이나 보류에 든 엔트리 id. 묶음마다 다시 읽지 않도록 과목마다 한 번 읽어 둔다.
  public struct SubjectEntries: Sendable {
    public let entries: [Entry]
    public let done: Set<String>

    public init(_ data: DataFolder, subject: String) {
      done = ConceptStore.curatedEntries(ConceptStore.all(data, subject: subject)).union(heldReasons(data, subject: subject).keys)
      entries = EntryStore.all(data, subject: subject)
    }
  }

  // 그 과목의 보류된 엔트리와 까닭: 지난 정리의 보류(기록의 plan.json)와 자료 읽기의 보류(엔트리의 held). 개념에 붙은 것은 뺀다.
  public static func heldEntries(_ data: DataFolder, subject: String) -> [(entry: Entry, reason: String)] {
    let reasons = heldReasons(data, subject: subject)
    let curated = ConceptStore.curatedEntries(ConceptStore.all(data, subject: subject))
    return EntryStore.all(data, subject: subject).compactMap { e in
      guard !curated.contains(e.id), let reason = reasons[e.id] else { return nil }
      return (e, reason)
    }.sorted { $0.entry.id < $1.entry.id }
  }

  // 엔트리 id → 보류 까닭 (가장 나중 것)
  static func heldReasons(_ data: DataFolder, subject: String) -> [String: String] {
    var out: [String: String] = [:]
    for e in EntryStore.all(data, subject: subject) { if let h = e.held { out[e.id] = h } }
    let root = data.records.appending(path: JobKind.conceptCuration.rawValue)
    for job in FileOps.list(root).sorted() where JobID.isValid(job) {
      guard let bytes = try? Data(contentsOf: root.appending(path: job).appending(path: "plan.json")), let plan = try? JSONValue.parse(bytes),
        plan["subject"]?.stringValue == subject
      else { continue }
      for h in plan["held"]?.arrayValue ?? [] {
        if let e = h["entry"]?.stringValue { out[e] = h["reason"]?.stringValue ?? "보류" }
      }
    }
    return out
  }

  struct Input: Sendable {
    let subject: String
    var bundle: String = ""
    // e01 → 정리할 엔트리
    let entries: [(key: String, entry: Entry)]
    // k01 → 개념
    let concepts: [(key: String, concept: Concept)]
    let conceptHashes: [String: String]
    // 다른 과목의 개념 (과목 사이 연결의 후보)
    var others: [Concept] = []
    // h01 → 보류된 엔트리와 까닭. 개념에 붙이거나 그대로 둔다
    var held: [(key: String, entry: Entry, reason: String)] = []

    // 키 → 엔트리 (정리할 것과 보류된 것)
    var entryByKey: [String: Entry] {
      Dictionary(entries.map { ($0.key, $0.entry) } + held.map { ($0.key, $0.entry) }, uniquingKeysWith: { a, _ in a })
    }

    // 정리할 엔트리와 이미 있는 개념이 나온 자료
    var sources: Set<String> {
      Set(entries.flatMap { $0.entry.sources.map(\.source) }).union(concepts.flatMap { $0.concept.occurrences.map(\.source) })
    }
  }

  static func run(bundle bundleID: String, _ ctx: JobContext) async throws {
    await ctx.setPhase("preparing")
    let library = SourceLibrary.load(ctx.data)
    guard let bundle = BundleStore.bundle(ctx.data, id: bundleID, library: library), let subject = BundleStore.subject(bundle, library: library) else {
      await ctx.log(.info, "정리할 묶음이 없습니다: \(bundleID)")
      await ctx.report(counts: [JobCount(key: "entries", label: "엔트리", count: 0)])
      return
    }
    let chosen = pending(ctx.data, bundle: bundle)
    if chosen.isEmpty {
      await ctx.log(.info, "정리할 엔트리가 없습니다")
      await ctx.report(counts: [JobCount(key: "entries", label: "엔트리", count: 0)])
      return
    }
    let held = heldEntries(ctx.data, subject: subject)
    let concepts = ConceptStore.all(ctx.data, subject: subject)
    let input = Input(
      subject: subject, bundle: bundleID, entries: chosen.enumerated().map { (String(format: "e%02d", $0.offset + 1), $0.element) },
      concepts: concepts.enumerated().map { (String(format: "k%02d", $0.offset + 1), $0.element) },
      conceptHashes: Dictionary(concepts.compactMap { c in ConceptStore.fileHash(ctx.data, id: c.cid).map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a }),
      others: ConceptStore.everything(ctx.data).filter { $0.subject != subject },
      held: held.enumerated().map { (String(format: "h%02d", $0.offset + 1), $0.element.entry, $0.element.reason) })
    let dirs = AgentDirs(ctx.folders, ctx.id)
    try dirs.make()
    let (instructions, instructionsFile) = try await AgentStep.fixInstructions(.conceptCuration, ctx, into: dirs.run)
    try writeInput(input, dirs: dirs, data: ctx.data)
    await ctx.log(.info, "묶음 \(bundleID): 엔트리 \(chosen.count)개, 보류된 엔트리 \(held.count)개, 이미 있는 개념 \(concepts.count)개")
    try ctx.checkCancellation()

    await ctx.setPhase("running")
    let options = AgentStep.options(ctx, dirs, instructions: instructionsFile, prompt: prompt, events: "curate")
    let result = try await AgentStep.run(options, ctx, label: "개념 정리")

    await ctx.setPhase("checking")
    let math = ctx.config.katex.flatMap(MathChecker.init(katex:))
    var checked = check(out: dirs.out, input: input, math: math)
    // 부드러운 검사(빠진 주장)도 한 번 고쳐 쓰게 한다. 그래도 남으면 기록에만 남긴다 (DECISIONS.md 38)
    if !checked.problems.isEmpty || !checked.soft.isEmpty {
      let all = checked.problems + checked.soft
      await ctx.log(.warn, "검사에서 \(all.count)건이 나와 고쳐 쓰게 합니다")
      for p in all.prefix(20) { await ctx.log(.warn, p) }
      await ctx.setPhase("fixing")
      try await AgentStep.fix(options, session: result.sessionID, problems: all, ctx: ctx, label: "개념 정리", events: "curate-fix")
      await ctx.setPhase("checking")
      checked = check(out: dirs.out, input: input, math: math)
    }
    guard checked.problems.isEmpty, var plan = checked.plan else {
      throw ToolError("개념 정리 검사 실패: " + checked.problems.prefix(10).joined(separator: " · "))
    }

    // 학생 독자 시험(새로 쓰거나 바뀐 단위)과 학습 목표 시험(새로 쓰거나 바뀐 개념). 실패하면 함께 한 번 고쳐 쓰게 하고,
    // 그래도 실패하면 기록에 남긴다.
    let labels = SourceLibrary.load(ctx.data).sources.first { $0.labels.labels.subjectID == subject }?.labels.labels
    let level = ReaderTest.level(labels)
    var readerWarnings: [String] = []
    var failed = await readerTest(plan, input: input, level: level, subject: labels?.subject ?? subject, ctx: ctx, scratch: dirs.run.appending(path: "reader-1"))
    var gaps = await outcomeTest(plan, input: input, level: level, subject: labels?.subject ?? subject, ctx: ctx, scratch: dirs.run.appending(path: "outcome-1"))
    if !failed.isEmpty || !gaps.isEmpty {
      if !failed.isEmpty { await ctx.log(.warn, "학생 독자 시험에서 단위 \(failed.count)개가 실패해 고쳐 쓰게 합니다") }
      for g in gaps { await ctx.log(.warn, "학습 목표 시험: \(g)") }
      await ctx.setPhase("fixing")
      let problems = failed.sorted { $0.key < $1.key }.flatMap { key, lines in lines.map { "\(key): \($0)" } } + gaps
      try await AgentStep.fix(options, session: result.sessionID, problems: problems, ctx: ctx, label: "개념 정리", events: "curate-reader-fix")
      await ctx.setPhase("checking")
      checked = check(out: dirs.out, input: input, math: math)
      guard checked.problems.isEmpty, let fixed = checked.plan else {
        throw ToolError("개념 정리 검사 실패: " + checked.problems.prefix(10).joined(separator: " · "))
      }
      plan = fixed
      failed = await readerTest(plan, input: input, level: level, subject: labels?.subject ?? subject, ctx: ctx, scratch: dirs.run.appending(path: "reader-2"))
      gaps = await outcomeTest(plan, input: input, level: level, subject: labels?.subject ?? subject, ctx: ctx, scratch: dirs.run.appending(path: "outcome-2"))
      readerWarnings = failed.sorted { $0.key < $1.key }.map { "학생 독자 시험 실패: \($0.key) — \($0.value.first ?? "")" }
      readerWarnings += gaps.map { "학습 목표 시험 실패: \($0)" }
      for w in readerWarnings { await ctx.log(.warn, w) }
    }
    // 고쳐 써도 남은 빠진 주장은 기록에 남긴다
    if !checked.soft.isEmpty {
      readerWarnings += checked.soft
      for w in checked.soft { await ctx.log(.warn, w) }
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
    let attached = Set(plan.concepts.flatMap(\.entries)).intersection(input.held.map(\.key)).count
    await ctx.report(
      counts: [
        JobCount(key: "entries", label: "엔트리", count: chosen.count), JobCount(key: "created", label: "새 개념", count: created),
        JobCount(key: "updated", label: "보강", count: plan.concepts.count - created), JobCount(key: "held", label: "보류", count: plan.held.count),
        JobCount(key: "attached", label: "보류에서 붙임", count: attached),
      ], warnings: readerWarnings.isEmpty ? nil : readerWarnings)
    for c in written { await ctx.log(.info, "개념: \(c.id) (단위 \(c.units.count)개)") }
    for h in plan.held { await ctx.log(.info, "보류: \(h.entry) — \(h.reason)") }

    if !written.isEmpty, await ctx.queueFollowUp("학습 페이지 만들기", { try PageBuild.prepare(subject: subject, $0) }) != nil {
      await ctx.log(.info, "학습 페이지 만들기를 대기열에 넣었습니다")
    }
  }

  // 새로 쓰거나 바뀐 단위의 학생 독자 시험. 실패한 단위 → 문제 줄. 키는 "concepts[i].units[j]".
  static func readerTest(_ plan: Plan, input: Input, level: String, subject: String, ctx: JobContext, scratch: URL) async -> [String: [String]] {
    let conceptByKey = Dictionary(input.concepts.map { ($0.key, $0.concept) }, uniquingKeysWith: { a, _ in a })
    var items: [ReaderTest.Item] = []
    for (i, p) in plan.concepts.enumerated() {
      let old = p.existing.flatMap { conceptByKey[$0] }
      for (j, u) in p.units.enumerated() {
        if let id = u.id, old?.units.first(where: { $0.id == id })?.text == u.text { continue }
        items.append(ReaderTest.Item(key: "concepts[\(i)].units[\(j)]", text: "(\(p.title))\n\n\(u.text)"))
      }
    }
    guard !items.isEmpty else { return [:] }
    let (verdicts, error) = await ReaderTest.check(items, level: level, subject: subject, config: ctx.config, scratch: scratch)
    if let error {
      await ctx.log(.warn, "학생 독자 시험을 하지 못했습니다: \(error)")
      return [:]
    }
    return ReaderTest.problems(verdicts)
  }

  // 학습 목표 시험: 개념마다 그 개념이 나온 자료의 학습 목표를 받아, 해당하는데 개념의 글만으로 해낼 수 없는 목표를 문제 줄로 돌려준다.
  static func outcomeTest(_ plan: Plan, input: Input, level: String, subject: String, ctx: JobContext, scratch: URL) async -> [String] {
    let entryByKey = input.entryByKey
    let conceptByKey = Dictionary(input.concepts.map { ($0.key, $0.concept) }, uniquingKeysWith: { a, _ in a })
    var problems: [String] = []
    for (i, p) in plan.concepts.enumerated() {
      let sources = Set(p.entries.flatMap { entryByKey[$0]?.sources.map(\.source) ?? [] })
        .union(p.existing.flatMap { conceptByKey[$0] }?.occurrences.map(\.source) ?? [])
      let outcomes = SourceReading.outcomes(ctx.data, sources: sources)
      guard !outcomes.isEmpty else { continue }
      let goals = outcomes.enumerated().map { OutcomeTest.Goal(key: "o\($0.offset + 1)", text: $0.element.text) }
      let text = "# \(p.title)\n\n" + p.units.map(\.text).joined(separator: "\n\n")
      // 같은 과목의 다른 개념: 이번에 함께 쓰는 개념과, 보강하지 않는 기존 개념
      let touched = Set(plan.concepts.compactMap(\.existing))
      let others = plan.concepts.enumerated().filter { $0.offset != i }.map(\.element.title)
        + input.concepts.filter { !touched.contains($0.key) }.map(\.concept.title)
      let (verdicts, error) = await OutcomeTest.check(
        text: text, goals: goals, level: level, subject: subject, others: others, config: ctx.config, scratch: scratch.appending(path: "c\(i)"))
      if let error {
        await ctx.log(.warn, "학습 목표 시험을 하지 못했습니다 (\(p.title)): \(error)")
        continue
      }
      problems += OutcomeTest.unmet(verdicts, goals: goals).map { "concepts[\(i)] (\(p.title)): \($0)" }
    }
    return problems
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
    if !input.bundle.isEmpty { request.append("- 묶음: \(input.bundle) (같은 내용을 다룬다고 학생이 묶어 넣은 자료들. 주제 하나의 경계는 아니다)") }
    func where_(_ e: Entry) -> String {
      e.sources.map { s in "\(s.source) (\(library.source(s.source)?.meta.original.name ?? s.source)) \(s.pages.map(String.init).joined(separator: ", "))" }
        .joined(separator: " / ")
    }
    request += ["", "## 정리할 엔트리", "", "| 키 | 제목 | 자료와 쪽 |", "|---|---|---|"]
    for (key, e) in input.entries {
      request.append("| \(key) | \(e.title) | \(where_(e)) |")
      try FileOps.write(e.markdown, to: dirs.input.appending(path: "entries/\(key).md"))
    }
    request += ["", "## 보류된 엔트리", "", "지난 정리나 자료 읽기가 보류한 엔트리다. 맞는 개념이 있으면 그 개념의 entries 에 넣어 붙이고, 없으면 적지 않는다(계속 보류로 남는다).", ""]
    if input.held.isEmpty { request.append("없다.") } else { request += ["| 키 | 제목 | 자료와 쪽 | 보류 까닭 |", "|---|---|---|---|"] }
    for h in input.held {
      request.append("| \(h.key) | \(h.entry.title) | \(where_(h.entry)) | \(h.reason) |")
      try FileOps.write(h.entry.markdown, to: dirs.input.appending(path: "held/\(h.key).md"))
    }
    request += ["", "## 이미 있는 개념", ""]
    if input.concepts.isEmpty { request.append("아직 없다.") } else {
      request += ["| 키 | 제목 | 항목·단원 제안 | 단위 수 |", "|---|---|---|---|"]
    }
    for (key, c) in input.concepts {
      request.append("| \(key) | \(c.title) | \(c.item ?? c.itemProposed ?? "") | \(c.units.count) |")
      try FileOps.write(YAML.stringify(c.yaml), to: dirs.input.appending(path: "concepts/\(key).yaml"))
    }
    request += ["", "## 다른 과목의 개념 (과목 사이 연결에 쓴다)", ""]
    if input.others.isEmpty { request.append("아직 없다.") }
    for c in input.others { request.append("- `\(c.id)` \(c.title)") }
    // 자료가 밝힌 학습 목표: 개념이 해당하는 목표를 학생이 글만 읽고 해낼 수 있게 쓴다 (지침 1장의 9)
    let outcomes = SourceReading.outcomes(data, sources: input.sources)
    request += ["", "## 학습 목표 (자료가 밝힌 것)", ""]
    if outcomes.isEmpty { request.append("자료가 밝힌 학습 목표가 없다.") }
    for o in outcomes {
      let name = library.source(o.source)?.meta.original.name ?? o.source
      request.append("- \(o.text) (\(name))")
    }
    try FileOps.write(request.joined(separator: "\n") + "\n", to: dirs.input.appending(path: "request.md"))
    if FileOps.exists(data.syllabusFile(input.subject)) { try FileOps.copy(data.syllabusFile(input.subject), to: dirs.input.appending(path: "syllabus.yaml")) }
    try AgentStep.writeGlossary(data, into: dirs.input)
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
    // 키(k01), 개념 id, "new:<slug>", "missing:<제목>"
    var prerequisites: [String] = []
    var links: [ConceptLink] = []
  }

  struct Plan: Sendable {
    let concepts: [PlannedConcept]
    let held: [(entry: String, reason: String)]

    func recordJSON(input: Input, written: [Concept]) -> JSONValue {
      let entryID = input.entryByKey.mapValues(\.id)
      let conceptID = Dictionary(input.concepts.map { ($0.key, $0.concept.id) }, uniquingKeysWith: { a, _ in a })
      return .object([
        "v": .number(1),
        "subject": .string(input.subject),
        "bundle": .string(input.bundle),
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
    // 고쳐 쓰게 하되 정리를 실패시키지 않는 문제: 엔트리의 주장이 그 엔트리를 쓰는 개념들에 남지 않았다
    var soft: [String] = []
  }

  static func check(out: URL, input: Input, math: MathChecker?) -> Checked {
    var c = Checked()
    let v: JSONValue
    switch AgentJSON.read(out.appending(path: "plan.json"), label: "out/plan.json") {
    case .failure(let p):
      c.problems.append(p.message)
      return c
    case .success(let value): v = value
    }
    let entryKeys = Set(input.entries.map(\.key))
    let heldKeys = Set(input.held.map(\.key))
    let conceptByKey = Dictionary(input.concepts.map { ($0.key, $0.concept) }, uniquingKeysWith: { a, _ in a })
    let entryByKey = input.entryByKey
    // 엔트리 키 → 그 엔트리를 쓰는 개념 수. 엔트리 하나를 여러 개념이 나눠 쓸 수 있다 (DECISIONS.md 38)
    var placedEntries: [String: Int] = [:]
    var heldEntries: Set<String> = []
    var usedConcepts: Set<String> = []
    // 이미 있는 개념들의 출처. 너무 커진 개념을 나눌 때 옮긴 단위가 원래 출처를 그대로 쓴다.
    let existingRefs = input.concepts.reduce(into: Set<String>()) { $0.formUnion($1.concept.refs) }
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
        if !entryKeys.contains(e) && !heldKeys.contains(e) { problems.append("\(at).entries: 없는 엔트리 키입니다 (\(e))") }
        placedEntries[e, default: 0] += 1
      }
      if entries.isEmpty && existing == nil { problems.append("\(at).entries 가 비었습니다") }

      // 출처로 쓸 수 있는 쪽: 이 개념에 넣은 엔트리의 출처와 이미 있는 개념들의 출처. 정리가 새 출처를 만들지는 못한다.
      var allowed = existingRefs
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
            problems.append("\(uat).claims[\(k)]: 이 개념에 넣은 엔트리에도, 이미 있는 개념에도 없는 출처입니다 (\(s)). 정리는 새 출처를 만들지 못한다")
          }
          claims.append((ct, src))
        }
        let conditions = AgentJSON.strings(u["conditions"])
        var english = [("\(uat).text", text)] + conditions.map { ("\(uat).conditions", $0) }
        english += claims.enumerated().map { ("\(uat).claims[\($0.offset)].text", $0.element.text) }
        for (field, t) in english {
          problems += TextChecks.englishProblems(t, field: field)
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
      let prerequisites = AgentJSON.strings(raw["prerequisites"])
      for p in prerequisites {
        let known = conceptByKey[p] != nil || p.hasPrefix("new:") || p.hasPrefix("missing:") || ConceptID(p) != nil
        if !known { problems.append("\(at).prerequisites: \(p) 는 개념 키(k01), 개념 id, \"new:<slug>\", \"missing:<제목>\" 가운데 하나다") }
      }
      var links: [ConceptLink] = []
      for l in raw["links"]?.arrayValue ?? [] {
        guard let target = AgentJSON.string(l["concept"]), let note = AgentJSON.string(l["note"]) else { continue }
        if !input.others.contains(where: { $0.id == target }) { problems.append("\(at).links: 다른 과목의 개념 목록에 없는 id 입니다 (\(target))") }
        problems += TextChecks.englishProblems(note, field: "\(at).links.note")
        links.append(ConceptLink(concept: target, note: note))
      }
      if let title { problems += TextChecks.englishProblems(title, field: "\(at).title") }
      if let item { problems += TextChecks.englishProblems(item, field: "\(at).item") }
      for s in symbols { problems += TextChecks.englishProblems(s.meaning, field: "\(at).symbols \(s.symbol)") }
      c.problems += problems
      if problems.isEmpty, let title {
        concepts.append(
          PlannedConcept(
            existing: existing == nil ? nil : existingKey, slug: slug, title: title, item: item, entries: entries, symbols: symbols, units: units,
            removed: removed, prerequisites: prerequisites, links: links))
      }
    }

    var held: [(entry: String, reason: String)] = []
    for h in v["held"]?.arrayValue ?? [] {
      guard let e = AgentJSON.string(h["entry"]) else { continue }
      // 보류된 엔트리는 적지 않아도 그대로 보류로 남는다
      if heldKeys.contains(e) { continue }
      if !entryKeys.contains(e) { c.problems.append("held: 없는 엔트리 키입니다 (\(e))") }
      guard let reason = AgentJSON.string(h["reason"]) else {
        c.problems.append("held: \(e) 를 보류한 까닭(reason)이 없습니다")
        continue
      }
      c.problems += TextChecks.recordProblems(reason, field: "held \(e)")
      heldEntries.insert(e)
      held.append((e, reason))
    }
    for key in entryKeys.sorted() {
      let used = placedEntries[key] ?? 0
      if used == 0 && !heldEntries.contains(key) { c.problems.append("엔트리 \(key) 가 어느 개념에도, 보류에도 없습니다") }
      if used > 0 && heldEntries.contains(key) { c.problems.append("엔트리 \(key) 가 개념과 보류에 함께 들어갔습니다. 개념에 쓰면 보류에서 뺀다") }
    }
    if c.problems.isEmpty {
      c.plan = Plan(concepts: concepts, held: held)
      c.soft = missingClaims(concepts, entryByKey: entryByKey)
    }
    return c
  }

  // 엔트리의 주장 가운데 그 엔트리를 쓰는 개념들의 단위 어디에도 출처가 남지 않은 것 (DECISIONS.md 38)
  static func missingClaims(_ concepts: [PlannedConcept], entryByKey: [String: Entry]) -> [String] {
    var cited: [String: Set<String>] = [:]
    for p in concepts {
      let refs = Set(p.units.flatMap { $0.claims.flatMap(\.src) })
      for e in p.entries { cited[e, default: []].formUnion(refs) }
    }
    var out: [String] = []
    for (key, refs) in cited.sorted(by: { $0.key < $1.key }) {
      guard let entry = entryByKey[key] else { continue }
      let missing = entry.claims.filter { !$0.src.isEmpty && Set($0.src).isDisjoint(with: refs) }
      guard !missing.isEmpty else { continue }
      let shown = missing.prefix(3).map { "\"\($0.text.prefix(60))\"" }.joined(separator: ", ")
      out.append("엔트리 \(key) (\(entry.title)) 의 주장 \(missing.count)개가 이 엔트리를 쓰는 개념의 단위에 출처로 남지 않았습니다: \(shown)")
    }
    return out
  }

  // MARK: - 반영

  static func apply(_ plan: Plan, input: Input, data: DataFolder, provenance: YAMLMap) throws -> [Concept] {
    let syllabus = Syllabus.load(data, subject: input.subject)
    let conceptByKey = Dictionary(input.concepts.map { ($0.key, $0.concept) }, uniquingKeysWith: { a, _ in a })
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
      concept.provenance = provenance
      out.append(concept)
    }
    // 선수 개념: 키와 새 개념의 slug 를 id 로 바꾼다
    let slugToID = Dictionary(zip(plan.concepts, out).map { ($0.slug, $1.id) }, uniquingKeysWith: { a, _ in a })
    for (i, p) in zip(out.indices, plan.concepts) {
      out[i].prerequisites = p.prerequisites.compactMap { ref -> String? in
        if let c = conceptByKey[ref] { return c.id }
        if ref.hasPrefix("new:") { return slugToID[String(ref.dropFirst(4))] }
        return ref
      }.filter { $0 != out[i].id }
      out[i].links = p.links
    }
    occurrences(&out, plan: plan, input: input, data: data)
    for c in out { try c.write(data) }
    return out
  }

  // 출현 목록은 러너가 계산한다: 이 개념에 넣은 엔트리와, 주장의 출처가 이 개념의 출처와 겹치는 엔트리.
  // 이전에 개념에 들어 있던 엔트리가 이번 정리로 어디에도 남지 않으면(그 출처의 단위가 모두 빠졌을 때) 원래 개념에 그대로 둔다.
  static func occurrences(_ concepts: inout [Concept], plan: Plan, input: Input, data: DataFolder) {
    let entryByKey = input.entryByKey
    var pool: [Entry] = input.entries.map(\.entry) + input.held.map(\.entry)
    var previous: [String: String] = [:]
    for (_, c) in input.concepts {
      for o in c.occurrences {
        previous[o.entry] = previous[o.entry] ?? c.id
        guard !pool.contains(where: { $0.id == o.entry }), let text = FileOps.readIfExists(data.entryFile(o.entry)), let e = try? Entry.parse(text) else { continue }
        pool.append(e)
      }
    }
    for (i, p) in zip(concepts.indices, plan.concepts) {
      let assigned = Set(p.entries.compactMap { entryByKey[$0]?.id })
      let refs = concepts[i].refs
      concepts[i].occurrences = pool.filter { assigned.contains($0.id) || !$0.refs.isDisjoint(with: refs) }.flatMap(Self.occurrences(of:))
    }
    let placed = Set(concepts.flatMap { $0.occurrences.map(\.entry) })
    for (entry, conceptID) in previous where !placed.contains(entry) {
      guard let i = concepts.firstIndex(where: { $0.id == conceptID }), let e = pool.first(where: { $0.id == entry }) else { continue }
      concepts[i].occurrences += Self.occurrences(of: e)
    }
  }

  // 엔트리 하나의 출현: 자료마다 하나
  static func occurrences(of e: Entry) -> [Occurrence] {
    e.sources.map { Occurrence(entry: e.id, source: $0.source, pages: $0.pages) }
  }
}
