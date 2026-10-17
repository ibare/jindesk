// 자료 읽기 (source-reading, JOBS.md). 자료 하나를 에이전트가 쪽 이미지 중심으로 읽고, 개념 엔트리(영어)와 자료 요약(한국어)을 쓴다.
// 입력 고정 → 1차 → 2차(새 에이전트가 먼저 혼자 읽은 뒤 1차를 반박·보완) → 러너 검사(틀리면 2차 세션으로 한 번 고쳐 쓰기)
// → 학생 독자 시험(실패한 엔트리는 한 번 고쳐 쓰고, 그래도 실패하면 넣지 않는다) → 엔트리 반영과 기록 → 개념 정리를 뒤따라 넣는다.
import Foundation

public enum SourceReading {
  static let prompt =
    "input/request.md 의 자료를 지침대로 읽어라 (1차). 먼저 input/index.md 를 읽고, 쪽마다 input/pages/ 의 쪽 이미지(.png)를 본다. "
    + "out/source.json, out/entries/<slug>.json, out/report.md 를 쓴다."

  static let secondPrompt =
    "너는 2차 읽기다. 지침의 \"2차 절차\"대로 input/request.md 의 자료를 먼저 혼자 읽은 뒤, input/first-pass/ 의 1차 결과를 열어 반박·보완하라. "
    + "최종 out/source.json, out/entries/<slug>.json, out/report.md 를 쓴다."

  public static func prepare(sourceID: String, _ ctx: PrepareContext) throws -> PreparedJob {
    let folder = SourceFolder(id: sourceID, in: ctx.data)
    guard let meta = try? SourceMeta.read(folder) else { throw RequestError("자료를 찾지 못했습니다: \(sourceID)") }
    let labels = (try? SourceLabelsFile.read(folder))?.labels ?? SourceLabels()
    guard labels.subjectID != nil else { throw RequestError("과목 꼬리표가 없는 자료는 읽지 않습니다: \(meta.original.name)") }
    let stem = (meta.original.name as NSString).deletingPathExtension
    let id = try JobID.make(date: ctx.now, slugSource: "read \(stem)", exists: ctx.taken)
    return PreparedJob(id: id, kind: .sourceReading, title: meta.original.name, target: sourceID, coalesceKey: "source-reading:\(sourceID)") { c in
      try await run(sourceID: sourceID, c)
    }
  }

  static func run(sourceID: String, _ ctx: JobContext) async throws {
    await ctx.setPhase("preparing")
    let folder = SourceFolder(id: sourceID, in: ctx.data)
    let meta = try SourceMeta.read(folder)
    let labelsFile = try SourceLabelsFile.read(folder)
    guard let subject = labelsFile.labels.subjectID else { throw RequestError("과목 꼬리표가 없는 자료는 읽지 않습니다") }
    let dirs = AgentDirs(ctx.folders, ctx.id)
    try dirs.make()
    let (instructions, instructionsFile) = try await AgentStep.fixInstructions(.sourceReading, ctx, into: dirs.run)
    let request = requestMarkdown(meta, labelsFile)
    try FileOps.write(request, to: dirs.input.appending(path: "request.md"))
    try FileOps.copy(folder.index, to: dirs.input.appending(path: "index.md"))
    for n in 1...max(meta.pages, 1) {
      try FileOps.copy(folder.pageText(n), to: dirs.input.appending(path: "pages/\(SourceFolder.pageName(n)).txt"))
      let image = try SourcePages.image(folder, page: n, folders: ctx.folders)
      try FileOps.copy(image, to: dirs.input.appending(path: "pages/\(SourceFolder.pageName(n)).png"))
    }
    if FileOps.exists(ctx.data.syllabusFile(subject)) {
      try FileOps.copy(ctx.data.syllabusFile(subject), to: dirs.input.appending(path: "syllabus.yaml"))
    }
    try FileOps.write(conceptList(ctx.data, subject: subject), to: dirs.input.appending(path: "concepts.md"))
    try AgentStep.writeGlossary(ctx.data, into: dirs.input)
    await ctx.log(.info, "\(meta.original.name): \(meta.pages)쪽, 과목 \(subject)")
    try ctx.checkCancellation()

    await ctx.setPhase("running")
    let first = AgentStep.options(ctx, dirs, instructions: instructionsFile, prompt: prompt, events: "read")
    _ = try await AgentStep.run(first, ctx, label: "자료 읽기 1차")
    let firstPass = try handOff(dirs)
    await ctx.log(.info, "1차: 엔트리 \(firstPass.entries)개. 2차가 먼저 혼자 읽은 뒤 1차를 반박·보완합니다")

    let options = AgentStep.options(ctx, dirs, instructions: instructionsFile, prompt: secondPrompt, events: "read2")
    let result = try await AgentStep.run(options, ctx, label: "자료 읽기 2차")

    await ctx.setPhase("checking")
    let math = ctx.config.katex.flatMap(MathChecker.init(katex:))
    var checked = check(out: dirs.out, meta: meta, math: math)
    if !checked.allProblems.isEmpty {
      await ctx.log(.warn, "검사에서 \(checked.allProblems.count)건이 나와 고쳐 쓰게 합니다")
      for p in checked.allProblems.prefix(20) { await ctx.log(.warn, p) }
      await ctx.setPhase("fixing")
      try await AgentStep.fix(options, session: result.sessionID, problems: checked.allProblems, ctx: ctx, label: "자료 읽기", events: "read-fix")
      await ctx.setPhase("checking")
      checked = check(out: dirs.out, meta: meta, math: math)
    }
    if !checked.problems.isEmpty { throw ToolError("자료 읽기 검사 실패: " + checked.problems.joined(separator: " · ")) }

    // 학생 독자 시험: 엔트리 본문만으로 그 학년·수준의 학생이 이해하는가
    let level = ReaderTest.level(labelsFile.labels)
    let subjectName = labelsFile.labels.subject ?? subject
    var readerFailed = await readerTest(checked.entries, level: level, subject: subjectName, ctx: ctx, scratch: dirs.run.appending(path: "reader-1"))
    if !readerFailed.isEmpty {
      await ctx.log(.warn, "학생 독자 시험에서 엔트리 \(readerFailed.count)개가 실패해 고쳐 쓰게 합니다")
      await ctx.setPhase("fixing")
      let problems = readerFailed.sorted { $0.key < $1.key }.flatMap { file, lines in lines.map { "out/entries/\(file): \($0)" } }
      try await AgentStep.fix(options, session: result.sessionID, problems: problems, ctx: ctx, label: "자료 읽기", events: "read-reader-fix")
      await ctx.setPhase("checking")
      checked = check(out: dirs.out, meta: meta, math: math)
      if !checked.problems.isEmpty { throw ToolError("자료 읽기 검사 실패: " + checked.problems.joined(separator: " · ")) }
      let again = checked.entries.filter { readerFailed[$0.file] != nil }
      readerFailed = await readerTest(again, level: level, subject: subjectName, ctx: ctx, scratch: dirs.run.appending(path: "reader-2"))
      for (file, lines) in readerFailed {
        checked.entries.removeAll { $0.file == file }
        checked.rejected.append((file, lines))
      }
    }
    var warnings: [String] = []
    for (file, problems) in checked.rejected {
      warnings.append("엔트리 \(file) 를 넣지 않았습니다: \(problems.joined(separator: " · "))")
    }

    await ctx.setPhase("finalizing")
    let events = ["read", "read2", "read-fix", "read-reader-fix"].map(dirs.events)
    let coverage = Coverage.make(
      meta: meta, read: EventCoverage.readFiles(events, workspace: dirs.workspace).union(EventCoverage.readFiles(events, workspace: firstPass.workspace)),
      cited: Set(checked.entries.flatMap(\.pages)), skipped: checked.note?.skipped ?? [])
    if !coverage.unread.isEmpty { warnings.append("읽지 않은 쪽: \(coverage.unread.map(String.init).joined(separator: ", "))") }
    for w in warnings { await ctx.log(.warn, w) }

    let placed = try place(
      checked.entries, subject: subject, source: sourceID, data: ctx.data, jobID: ctx.id, provenance: AgentStep.provenance(ctx, .sourceReading, instructions))
    let record = ctx.data.record(JobKind.sourceReading.rawValue, ctx.id)
    let head = FrontMatter.render([
      "kind": "reading-request", "v": 1, "source": .string(sourceID), "subject": .string(subject), "job": .string(ctx.id),
    ])
    try FileOps.writeNew(head + "\n" + request, to: record.appending(path: "request.md"))
    let report = reportMarkdown(checked.report ?? "", entries: placed, coverage: coverage, warnings: warnings, note: checked.note, instructions: instructions, ctx: ctx)
    try FileOps.writeNew(report, to: record.appending(path: "report.md"))
    try FileOps.writeNew(JSONText.record(coverage.json(source: sourceID)), to: record.appending(path: "coverage.json"))
    if let firstReport = FileOps.readIfExists(dirs.input.appending(path: "first-pass/report.md")) {
      try FileOps.writeNew(firstReport, to: record.appending(path: "report.first-pass.md"))
    }

    let unplaced = placed.filter { $0.item == nil }.count
    await ctx.report(
      counts: [
        JobCount(key: "entries", label: "엔트리", count: placed.count), JobCount(key: "unplaced", label: "목차 밖", count: unplaced),
        JobCount(key: "rejected", label: "넣지 않음", count: checked.rejected.count),
      ],
      warnings: warnings.isEmpty ? nil : warnings)
    await ctx.log(.info, "엔트리 \(placed.count)개를 넣었습니다")
    if checked.note?.assessment == true { await ctx.log(.info, "평가 과제로 표시했습니다. 과제의 답과 풀이는 쓰지 않았습니다") }

    if !placed.isEmpty, await ctx.queueFollowUp("개념 정리", { try ConceptCuration.prepare(subject: subject, $0) }) != nil {
      await ctx.log(.info, "개념 정리를 대기열에 넣었습니다")
    }
  }

  // 1차 결과를 2차의 입력(input/first-pass/)으로 넘기고, 1차의 out/ 과 작업 메모는 작업 공간 밖(pass1/)으로 옮긴다.
  struct FirstPass {
    let entries: Int
    let workspace: URL
  }

  static func handOff(_ dirs: AgentDirs) throws -> FirstPass {
    let pass1 = dirs.run.appending(path: "pass1")
    FileOps.remove(pass1)
    try FileOps.makeDirectory(pass1)
    let firstInput = dirs.input.appending(path: "first-pass")
    FileOps.remove(firstInput)
    try FileOps.copy(dirs.out, to: firstInput)
    try FileOps.move(dirs.out, to: pass1.appending(path: "out"))
    try FileOps.move(dirs.work, to: pass1.appending(path: "work"))
    try FileOps.makeDirectory(dirs.out)
    try FileOps.makeDirectory(dirs.work)
    let entries = FileOps.list(firstInput.appending(path: "entries")).filter { $0.hasSuffix(".json") }.count
    return FirstPass(entries: entries, workspace: dirs.workspace)
  }

  // 엔트리마다 학생 독자 시험. 실패한 엔트리의 파일 이름 → 문제 줄
  static func readerTest(_ entries: [Draft], level: String, subject: String, ctx: JobContext, scratch: URL) async -> [String: [String]] {
    guard !entries.isEmpty else { return [:] }
    let items = entries.map { ReaderTest.Item(key: $0.file, text: "# \($0.title)\n\n\($0.body)") }
    let (verdicts, error) = await ReaderTest.check(items, level: level, subject: subject, config: ctx.config, scratch: scratch)
    if let error {
      await ctx.log(.warn, "학생 독자 시험을 하지 못했습니다: \(error)")
      return [:]
    }
    for v in verdicts where !v.pass { await ctx.log(.warn, "학생 독자: \(v.key) — \(v.reason)") }
    return ReaderTest.problems(verdicts)
  }

  // MARK: - 입력

  static func requestMarkdown(_ meta: SourceMeta, _ labels: SourceLabelsFile) -> String {
    var lines = ["# 자료 읽기 요청", ""]
    lines.append("- 자료 id: \(meta.id)")
    lines.append("- 원본 파일: \(meta.original.name)")
    lines.append("- 쪽: \(meta.pages)")
    let tags = labels.labels.entries.map { "\(SourceLabels.displayName($0.name)) \($0.value)" }
    lines.append("- 꼬리표: \(tags.isEmpty ? "없음" : tags.joined(separator: " · "))")
    lines.append("- 목차의 근거로 표시: \(labels.syllabusBasis ? "예" : "아니오")")
    if let memo = labels.memo { lines.append("- 학생 메모: \(memo)") }
    return lines.joined(separator: "\n") + "\n"
  }

  // 이 과목에 이미 정리된 개념 (id 와 제목). 같은 개념을 같은 이름으로 부르게 돕는다.
  static func conceptList(_ data: DataFolder, subject: String) -> String {
    let concepts = ConceptStore.all(data, subject: subject)
    var lines = ["# 이 과목에 이미 정리된 개념", ""]
    if concepts.isEmpty { lines.append("아직 없다.") }
    for c in concepts {
      let group = c.item.map { "항목 \($0)" } ?? c.itemProposed.map { "단원 제안: \($0)" } ?? "목차 밖"
      lines.append("- \(c.title) (\(group))")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: - 검사

  struct Note: Sendable {
    let title: String?
    let kind: String?
    let assessment: Bool
    let skipped: [Int]
    // 자료가 밝힌 학습 목표 (DECISIONS.md 25)
    var outcomes: [LearningOutcome] = []
  }

  struct Draft: Sendable {
    let file: String
    let slug: String
    let title: String
    let item: String?
    let body: String
    let claims: [(text: String, pages: [Int], conditions: [String])]
    let symbols: [SymbolDef]
    let examples: [String]
    let misconceptions: [String]
    let pages: [Int]
  }

  struct Checked: Sendable {
    var note: Note?
    var report: String?
    var entries: [Draft] = []
    // 작업 전체의 문제 (고쳐 써도 남으면 실패)
    var problems: [String] = []
    // 엔트리별 문제 (고쳐 써도 남으면 그 엔트리만 넣지 않는다)
    var rejected: [(file: String, problems: [String])] = []

    var allProblems: [String] { problems + rejected.flatMap { r in r.problems.map { "out/entries/\(r.file): \($0)" } } }
  }

  static func check(out: URL, meta: SourceMeta, math: MathChecker?) -> Checked {
    var c = Checked()
    switch AgentJSON.read(out.appending(path: "source.json"), label: "out/source.json") {
    case .failure(let p): c.problems.append(p.message)
    case .success(let v):
      let skipped = (v["skipped_pages"]?.arrayValue ?? []).compactMap { $0["page"]?.numberValue.map { Int($0) } ?? $0.numberValue.map { Int($0) } }
      var note = Note(
        title: AgentJSON.string(v["title"]), kind: AgentJSON.string(v["kind"]), assessment: v["assessment"]?.boolValue ?? false, skipped: skipped)
      if let t = note.title { c.problems += TextChecks.englishProblems(t, field: "out/source.json title") }
      for (i, o) in (v["outcomes"]?.arrayValue ?? []).enumerated() {
        guard let text = AgentJSON.string(o["text"]) else {
          c.problems.append("out/source.json outcomes[\(i)]: text 가 있어야 한다")
          continue
        }
        let pages = AgentJSON.ints(o["pages"])
        c.problems += TextChecks.englishProblems(text, field: "out/source.json outcomes[\(i)].text")
        for p in pages where !(1...max(meta.pages, 1)).contains(p) { c.problems.append("out/source.json outcomes[\(i)].pages: 없는 쪽입니다 (\(p))") }
        note.outcomes.append(LearningOutcome(text: text, pages: pages, source: meta.id))
      }
      for p in skipped where !(1...max(meta.pages, 1)).contains(p) { c.problems.append("out/source.json skipped_pages: 없는 쪽입니다 (\(p))") }
      c.note = note
    }

    if let report = FileOps.readIfExists(out.appending(path: "report.md"))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
      c.report = report
      if !TextChecks.hasHangul(report) { c.problems.append("out/report.md: 한국어로 써야 합니다") }
      c.problems += TextChecks.recordProblems(report, field: "out/report.md")
    } else {
      c.problems.append("out/report.md 를 쓰지 않았습니다")
    }

    let entriesDir = out.appending(path: "entries")
    let files = FileOps.list(entriesDir).filter { $0.hasSuffix(".json") }.sorted()
    // 개념이 없는 자료(단원 계획서 같은 것)는 엔트리가 없어도 된다. 그때는 모든 쪽이 skipped_pages 에 까닭과 함께 있어야 한다.
    let allSkipped = Set(1...max(meta.pages, 1)).isSubset(of: Set(c.note?.skipped ?? []))
    if files.isEmpty && c.note?.assessment != true && !allSkipped {
      c.problems.append("out/entries/ 에 엔트리가 없습니다. 개념이 없는 자료이면 모든 쪽을 out/source.json 의 skipped_pages 에 까닭과 함께 적는다")
    }
    for file in files {
      switch AgentJSON.read(entriesDir.appending(path: file), label: "out/entries/\(file)") {
      case .failure(let p): c.rejected.append((file, [p.message]))
      case .success(let v):
        let (draft, problems) = checkEntry(v, file: file, pages: meta.pages, math: math)
        if let draft, problems.isEmpty { c.entries.append(draft) } else { c.rejected.append((file, problems)) }
      }
    }
    return c
  }

  static func checkEntry(_ v: JSONValue, file: String, pages: Int, math: MathChecker?) -> (Draft?, [String]) {
    var problems: [String] = []
    let title = AgentJSON.string(v["title"])
    let body = AgentJSON.string(v["body"])
    if title == nil { problems.append("title 이 없습니다") }
    if body == nil { problems.append("body 가 없습니다") }
    var claims: [(text: String, pages: [Int], conditions: [String])] = []
    for (i, raw) in (v["claims"]?.arrayValue ?? []).enumerated() {
      guard let text = AgentJSON.string(raw["text"]) else {
        problems.append("claims[\(i)]: text 가 없습니다")
        continue
      }
      let ps = AgentJSON.ints(raw["pages"])
      if ps.isEmpty { problems.append("claims[\(i)]: 출처 쪽(pages)이 없습니다") }
      for p in ps where !(1...max(pages, 1)).contains(p) { problems.append("claims[\(i)]: 없는 쪽입니다 (\(p))") }
      claims.append((text, ps, AgentJSON.strings(raw["conditions"])))
    }
    if claims.isEmpty { problems.append("claims 가 없습니다. 주장마다 출처 쪽을 단다") }
    let symbols = AgentJSON.symbols(v["symbols"])
    let examples = AgentJSON.strings(v["examples"])
    let misconceptions = AgentJSON.strings(v["misconceptions"])
    let item = AgentJSON.string(v["item"])

    var english: [(String, String)] = []
    if let title { english.append(("title", title)) }
    if let body { english.append(("body", body)) }
    for (i, c) in claims.enumerated() {
      english.append(("claims[\(i)].text", c.text))
      for cond in c.conditions { english.append(("claims[\(i)].conditions", cond)) }
    }
    for s in symbols { english.append(("symbols \(s.symbol)", s.meaning)) }
    for (i, e) in examples.enumerated() { english.append(("examples[\(i)]", e)) }
    for (i, m) in misconceptions.enumerated() { english.append(("misconceptions[\(i)]", m)) }
    if let item { english.append(("item", item)) }
    for (field, text) in english {
      problems += TextChecks.englishProblems(text, field: field)
      for phrase in TextChecks.materialPhrases(text) { problems.append("\(field): 원래 자료가 있어야만 통하는 말입니다 (\"\(phrase)\")") }
      if let math { problems += math.problems(inText: text, field: field) }
    }
    guard let title, let body, problems.isEmpty else { return (nil, problems) }
    let slugSource = AgentJSON.string(v["slug"]) ?? title
    let slug = JobID.slugify(slugSource, maxLength: 60).nilIfEmpty ?? JobID.slugify(title, maxLength: 60).nilIfEmpty ?? "entry"
    var allPages = AgentJSON.ints(v["pages"]) + claims.flatMap(\.pages)
    allPages = Array(Set(allPages.filter { (1...max(pages, 1)).contains($0) })).sorted()
    return (
      Draft(
        file: file, slug: slug, title: title, item: item, body: body, claims: claims, symbols: symbols, examples: examples,
        misconceptions: misconceptions, pages: allPages), []
    )
  }

  // MARK: - 반영

  static func place(_ drafts: [Draft], subject: String, source: String, data: DataFolder, jobID: String, provenance: YAMLMap) throws -> [Entry] {
    let syllabus = Syllabus.load(data, subject: subject)
    let recorded = Clock.isoLocal()
    return try EntryStore.lock.withLock {
      var planned: Set<String> = []
      var entries: [Entry] = []
      for d in drafts {
        let item = syllabus?.item(d.item)
        let id = EntryStore.placeID(data, subject: subject, itemDir: ItemPath.dir(item?.code), slug: d.slug, jobID: jobID, planned: planned)
        planned.insert(id)
        entries.append(
          Entry(
            id: id, subject: subject, item: item?.code, itemProposed: item == nil ? d.item : nil, title: d.title, source: source, pages: d.pages,
            claims: d.claims.map { EntryClaim(text: $0.text, src: $0.pages.map { SourceRef.make(source, page: $0) }, conditions: $0.conditions) },
            symbols: d.symbols, examples: d.examples, misconceptions: d.misconceptions, body: d.body, recorded: recorded, provenance: provenance))
      }
      for e in entries { try FileOps.writeNew(e.markdown, to: data.entryFile(e.id)) }
      return entries
    }
  }

  static func reportMarkdown(
    _ body: String, entries: [Entry], coverage: Coverage, warnings: [String], note: Note?, instructions: Instructions, ctx: JobContext
  ) -> String {
    let head: YAMLMap = [
      "kind": "reading-report",
      "v": 1,
      "job": .string(ctx.id),
      "material_title": note?.title.map(YAMLValue.string) ?? .null,
      "material_kind": note?.kind.map(YAMLValue.string) ?? .null,
      "assessment": .bool(note?.assessment ?? false),
      "outcomes": .array((note?.outcomes ?? []).map { .map(["text": .string($0.text), "pages": .array($0.pages.map(YAMLValue.int))]) }),
      "entries": .array(entries.map { .string($0.id) }),
      "unread_pages": .array(coverage.unread.map(YAMLValue.int)),
      "provenance": .map(AgentStep.provenance(ctx, .sourceReading, instructions)),
    ]
    var text = FrontMatter.render(head) + "\n" + body + "\n"
    if !warnings.isEmpty {
      text += "\n## 러너 검사\n\n" + warnings.map { "- \($0)" }.joined(separator: "\n") + "\n"
    }
    return text
  }

  // MARK: - 상태

  // 자료들이 밝힌 학습 목표 (자료마다 마지막 자료 읽기 기록의 report.md 머리말). 같은 글은 한 번만.
  public static func outcomes(_ data: DataFolder, sources: Set<String>) -> [LearningOutcome] {
    let root = data.records.appending(path: JobKind.sourceReading.rawValue)
    let read = readSources(data)
    var out: [LearningOutcome] = []
    var seen = Set<String>()
    for source in sources.sorted() {
      guard let job = read[source]?.last, let text = FileOps.readIfExists(root.appending(path: job).appending(path: "report.md")),
        let (head, _) = FrontMatter.split(text)
      else { continue }
      for o in head["outcomes"]?.array ?? [] {
        guard let t = o["text"]?.string else { continue }
        let key = t.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard seen.insert(key).inserted else { continue }
        out.append(LearningOutcome(text: t, pages: (o["pages"]?.array ?? []).compactMap(\.int), source: source))
      }
    }
    return out
  }

  // 자료마다 끝난 자료 읽기 작업 id (기록의 request.md 머리말에서 읽는다)
  public static func readSources(_ data: DataFolder) -> [String: [String]] {
    let root = data.records.appending(path: JobKind.sourceReading.rawValue)
    var out: [String: [String]] = [:]
    for job in FileOps.list(root).sorted() where JobID.isValid(job) {
      guard let text = FileOps.readIfExists(root.appending(path: job).appending(path: "request.md")), let (head, _) = FrontMatter.split(text),
        let source = head["source"]?.string
      else { continue }
      out[source, default: []].append(job)
    }
    return out
  }
}

// 자료가 밝힌 학습 목표 하나 (자료의 영어 그대로)
public struct LearningOutcome: Sendable, Equatable {
  public let text: String
  public let pages: [Int]
  public let source: String

  public init(text: String, pages: [Int], source: String) {
    self.text = text
    self.pages = pages
    self.source = source
  }
}

// 읽은 쪽 세기 (Assayer PR 리뷰의 coverage.json 처럼). 쪽 이미지나 글자층을 Read 했으면 읽은 것으로 본다.
// 이어 채운 쪽 묶음은 마지막 쪽을 읽었으면 앞 쪽도 읽은 것으로 본다. 에이전트가 까닭과 함께 건너뛴 쪽(표지 등)은 세지 않는다.
struct Coverage: Sendable {
  let pages: Int
  let read: [Int]
  let cited: [Int]
  let skipped: [Int]
  let unread: [Int]

  static func make(meta: SourceMeta, read files: Set<String>, cited: Set<Int>, skipped: [Int]) -> Coverage {
    var read: Set<Int> = []
    for f in files where f.hasPrefix("input/pages/") {
      if let n = Int((f as NSString).lastPathComponent.prefix(4)) { read.insert(n) }
    }
    var covered = read
    for run in meta.buildUps where run.last.map(read.contains) == true { covered.formUnion(run) }
    let unread = (1...max(meta.pages, 1)).filter { !covered.contains($0) && !skipped.contains($0) }
    return Coverage(pages: meta.pages, read: read.sorted(), cited: cited.sorted(), skipped: skipped.sorted(), unread: unread)
  }

  func json(source: String) -> JSONValue {
    .object([
      "v": .number(1), "source": .string(source), "pages": .number(Double(pages)),
      "read": .array(read.map { .number(Double($0)) }), "cited": .array(cited.map { .number(Double($0)) }),
      "skipped": .array(skipped.map { .number(Double($0)) }), "unread": .array(unread.map { .number(Double($0)) }),
    ])
  }
}
