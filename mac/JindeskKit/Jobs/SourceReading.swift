// 자료 읽기 (source-reading, JOBS.md). 묶음 하나를 에이전트 하나가 쪽 이미지 중심으로 읽고(DECISIONS.md 35),
// 개념 엔트리(영어, 여러 자료에 걸칠 수 있다)와 묶음 요약(한국어)을 쓴다.
// 입력 고정 → 1차 → 2차(새 에이전트가 먼저 혼자 읽은 뒤 1차를 반박·보완) → 러너 검사(틀리면 2차 세션으로 한 번 고쳐 쓰기)
// → 학생 독자 시험(실패한 엔트리는 한 번 고쳐 쓰고, 그래도 실패하면 보류로 넣는다) → 엔트리 반영과 기록 → 그 묶음의 개념 정리를 뒤따라 넣는다.
import Foundation

public enum SourceReading {
  static let prompt =
    "input/request.md 의 묶음을 지침대로 읽어라 (1차). 먼저 자료마다 input/sources/<자료 id>/index.md 를 읽고, 쪽마다 그 자료의 pages/ 의 쪽 이미지(.png)를 본다. "
    + "out/bundle.json, out/sources/<자료 id>.json, out/entries/<slug>.json, out/report.md 를 쓴다."

  static let secondPrompt =
    "너는 2차 읽기다. 지침의 \"2차 절차\"대로 input/request.md 의 묶음을 먼저 혼자 읽은 뒤, input/first-pass/ 의 1차 결과를 열어 반박·보완하라. "
    + "최종 out/bundle.json, out/sources/<자료 id>.json, out/entries/<slug>.json, out/report.md 를 쓴다."

  // 묶음의 읽지 않은 자료를 읽는다. sources 를 주면 그 자료를 (다시) 읽는다.
  public static func prepare(bundle bundleID: String, sources only: [String]? = nil, _ ctx: PrepareContext) throws -> PreparedJob {
    let library = SourceLibrary.load(ctx.data)
    guard let bundle = BundleStore.bundle(ctx.data, id: bundleID, library: library) else { throw RequestError("묶음을 찾지 못했습니다: \(bundleID)") }
    let members = bundle.sources.compactMap(library.source)
    guard let first = members.first else { throw RequestError("묶음에 자료가 없습니다: \(bundleID)") }
    guard first.labels.labels.subjectID != nil else { throw RequestError("과목 꼬리표가 없는 자료는 읽지 않습니다: \(first.meta.original.name)") }
    let stem = bundle.title ?? (first.meta.original.name as NSString).deletingPathExtension
    let id = try JobID.make(date: ctx.now, slugSource: "read \(stem)", exists: ctx.taken)
    let title = bundle.title ?? (members.count == 1 ? first.meta.original.name : "\(first.meta.original.name) 외 \(members.count - 1)개")
    let key = "source-reading:\(bundleID)" + (only.map { ":" + $0.sorted().joined(separator: ",") } ?? "")
    return PreparedJob(id: id, kind: .sourceReading, title: title, target: bundleID, coalesceKey: key) { c in
      try await run(bundle: bundleID, only: only, c)
    }
  }

  static func run(bundle bundleID: String, only: [String]?, _ ctx: JobContext) async throws {
    await ctx.setPhase("preparing")
    let library = SourceLibrary.load(ctx.data)
    guard let bundle = BundleStore.bundle(ctx.data, id: bundleID, library: library) else { throw RequestError("묶음을 찾지 못했습니다: \(bundleID)") }
    let read = readSources(ctx.data)
    let members = bundle.sources.compactMap(library.source)
    let targets = only.map { ids in members.filter { ids.contains($0.id) } } ?? members.filter { read[$0.id] == nil }
    guard let lead = targets.first else {
      await ctx.log(.info, "읽을 자료가 없습니다")
      await ctx.report(counts: [JobCount(key: "entries", label: "엔트리", count: 0)])
      return
    }
    guard let subject = lead.labels.labels.subjectID else { throw RequestError("과목 꼬리표가 없는 자료는 읽지 않습니다") }
    if let other = targets.first(where: { $0.labels.labels.subjectID != subject }) {
      throw RequestError("묶음의 자료들의 과목 꼬리표가 다릅니다: \(other.meta.original.name). 꼬리표를 맞춘 뒤 다시 읽습니다")
    }
    // 같은 묶음에서 이미 읽은 자료와 그 엔트리 (나중에 자료를 더했을 때)
    let earlier = members.filter { m in !targets.contains(m) && read[m.id] != nil }
    let earlierIDs = Set(earlier.map(\.id))
    let earlierEntries = EntryStore.all(ctx.data, subject: subject).filter { earlierIDs.contains($0.source) }

    let dirs = AgentDirs(ctx.folders, ctx.id)
    try dirs.make()
    let (instructions, instructionsFile) = try await AgentStep.fixInstructions(.sourceReading, ctx, into: dirs.run)
    let request = requestMarkdown(bundle, targets: targets, earlier: earlier, earlierEntries: earlierEntries)
    try FileOps.write(request, to: dirs.input.appending(path: "request.md"))
    for s in targets {
      let base = dirs.input.appending(path: "sources/\(s.id)")
      try FileOps.copy(s.folder.index, to: base.appending(path: "index.md"))
      for n in 1...max(s.meta.pages, 1) {
        try FileOps.copy(s.folder.pageText(n), to: base.appending(path: "pages/\(SourceFolder.pageName(n)).txt"))
        let image = try SourcePages.image(s.folder, page: n, folders: ctx.folders)
        try FileOps.copy(image, to: base.appending(path: "pages/\(SourceFolder.pageName(n)).png"))
      }
    }
    for e in earlierEntries {
      try FileOps.write(e.markdown, to: dirs.input.appending(path: "bundle/entries/\(e.id.replacingOccurrences(of: "/", with: "__")).md"))
    }
    if FileOps.exists(ctx.data.syllabusFile(subject)) {
      try FileOps.copy(ctx.data.syllabusFile(subject), to: dirs.input.appending(path: "syllabus.yaml"))
    }
    try FileOps.write(conceptList(ctx.data, subject: subject), to: dirs.input.appending(path: "concepts.md"))
    try AgentStep.writeGlossary(ctx.data, into: dirs.input)
    let pages = targets.map(\.meta.pages).reduce(0, +)
    await ctx.log(.info, "묶음 \(bundleID): 자료 \(targets.count)개, \(pages)쪽, 과목 \(subject)\(earlier.isEmpty ? "" : ", 이미 읽은 자료 \(earlier.count)개")")
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
    let metas = targets.map(\.meta)
    var checked = check(out: dirs.out, sources: metas, math: math)
    if !checked.allProblems.isEmpty {
      await ctx.log(.warn, "검사에서 \(checked.allProblems.count)건이 나와 고쳐 쓰게 합니다")
      for p in checked.allProblems.prefix(20) { await ctx.log(.warn, p) }
      await ctx.setPhase("fixing")
      try await AgentStep.fix(options, session: result.sessionID, problems: checked.allProblems, ctx: ctx, label: "자료 읽기", events: "read-fix")
      await ctx.setPhase("checking")
      checked = check(out: dirs.out, sources: metas, math: math)
    }
    if !checked.problems.isEmpty { throw ToolError("자료 읽기 검사 실패: " + checked.problems.joined(separator: " · ")) }

    // 학생 독자 시험: 엔트리 본문만으로 그 학년·수준의 학생이 이해하는가. 고쳐 써도 떨어지면 버리지 않고 보류로 넣는다.
    let level = ReaderTest.level(lead.labels.labels)
    let subjectName = lead.labels.labels.subject ?? subject
    var held: [String: String] = [:]
    var readerFailed = await readerTest(checked.entries, level: level, subject: subjectName, ctx: ctx, scratch: dirs.run.appending(path: "reader-1"))
    if !readerFailed.isEmpty {
      await ctx.log(.warn, "학생 독자 시험에서 엔트리 \(readerFailed.count)개가 실패해 고쳐 쓰게 합니다")
      await ctx.setPhase("fixing")
      let problems = readerFailed.sorted { $0.key < $1.key }.flatMap { file, lines in lines.map { "out/entries/\(file): \($0)" } }
      try await AgentStep.fix(options, session: result.sessionID, problems: problems, ctx: ctx, label: "자료 읽기", events: "read-reader-fix")
      await ctx.setPhase("checking")
      checked = check(out: dirs.out, sources: metas, math: math)
      if !checked.problems.isEmpty { throw ToolError("자료 읽기 검사 실패: " + checked.problems.joined(separator: " · ")) }
      let again = checked.entries.filter { readerFailed[$0.file] != nil }
      readerFailed = await readerTest(again, level: level, subject: subjectName, ctx: ctx, scratch: dirs.run.appending(path: "reader-2"))
      for (file, lines) in readerFailed { held[file] = "학생 독자 시험 실패: " + lines.joined(separator: " · ") }
    }
    var warnings: [String] = []
    for (file, problems) in checked.rejected {
      warnings.append("엔트리 \(file) 를 넣지 않았습니다: \(problems.joined(separator: " · "))")
    }
    for (file, reason) in held.sorted(by: { $0.key < $1.key }) { warnings.append("엔트리 \(file) 를 보류로 넣었습니다: \(reason)") }

    await ctx.setPhase("finalizing")
    let events = ["read", "read2", "read-fix", "read-reader-fix"].map(dirs.events)
    let readFiles = EventCoverage.readFiles(events, workspace: dirs.workspace).union(EventCoverage.readFiles(events, workspace: firstPass.workspace))
    let coverages = metas.map { meta in
      Coverage.make(
        meta: meta, read: readFiles, cited: Set(checked.entries.flatMap { $0.pages[meta.id] ?? [] }), skipped: checked.notes[meta.id]?.skipped ?? [],
        prefix: "input/sources/\(meta.id)/pages/")
    }
    for (meta, c) in zip(metas, coverages) where !c.unread.isEmpty {
      warnings.append("읽지 않은 쪽 (\(meta.original.name)): \(c.unread.map(String.init).joined(separator: ", "))")
    }
    for w in warnings { await ctx.log(.warn, w) }

    let placed = try place(
      checked.entries, held: held, subject: subject, data: ctx.data, jobID: ctx.id, provenance: AgentStep.provenance(ctx, .sourceReading, instructions))
    if let title = checked.bundleTitle { try BundleStore.name(ctx.data, id: bundleID, title: title) }
    let record = ctx.data.record(JobKind.sourceReading.rawValue, ctx.id)
    let head = FrontMatter.render([
      "kind": "reading-request", "v": 1, "bundle": .string(bundleID), "sources": .array(targets.map { .string($0.id) }), "subject": .string(subject),
      "job": .string(ctx.id),
    ])
    try FileOps.writeNew(head + "\n" + request, to: record.appending(path: "request.md"))
    let report = reportMarkdown(
      checked.report ?? "", bundle: bundleID, checked: checked, metas: metas, entries: placed, coverages: coverages, warnings: warnings,
      instructions: instructions, ctx: ctx)
    try FileOps.writeNew(report, to: record.appending(path: "report.md"))
    try FileOps.writeNew(
      JSONText.record(.object(["v": .number(1), "bundle": .string(bundleID), "sources": .array(zip(metas, coverages).map { $1.json(source: $0.id) })])),
      to: record.appending(path: "coverage.json"))
    if let firstReport = FileOps.readIfExists(dirs.input.appending(path: "first-pass/report.md")) {
      try FileOps.writeNew(firstReport, to: record.appending(path: "report.first-pass.md"))
    }

    let unplaced = placed.filter { $0.item == nil }.count
    await ctx.report(
      counts: [
        JobCount(key: "entries", label: "엔트리", count: placed.filter { $0.held == nil }.count), JobCount(key: "unplaced", label: "목차 밖", count: unplaced),
        JobCount(key: "held", label: "보류", count: placed.filter { $0.held != nil }.count),
        JobCount(key: "rejected", label: "넣지 않음", count: checked.rejected.count),
      ],
      warnings: warnings.isEmpty ? nil : warnings)
    await ctx.log(.info, "엔트리 \(placed.count)개를 넣었습니다")
    if checked.notes.values.contains(where: \.assessment) { await ctx.log(.info, "평가 과제로 표시한 자료가 있습니다. 과제의 답과 풀이는 쓰지 않았습니다") }

    if placed.contains(where: { $0.held == nil }),
      await ctx.queueFollowUp("개념 정리", { try ConceptCuration.prepare(bundle: bundleID, $0) }) != nil
    {
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

  static func requestMarkdown(_ bundle: SourceBundle, targets: [SourceSummary], earlier: [SourceSummary], earlierEntries: [Entry]) -> String {
    var lines = ["# 자료 읽기 요청", ""]
    lines.append("- 묶음 id: \(bundle.id)")
    if let lead = targets.first {
      let tags = lead.labels.labels.entries.map { "\(SourceLabels.displayName($0.name)) \($0.value)" }
      lines.append("- 꼬리표: \(tags.isEmpty ? "없음" : tags.joined(separator: " · "))")
    }
    if let memo = bundle.memo { lines.append("- 묶음 메모: \(memo)") }
    lines += ["", "## 읽을 자료", "", "| 자료 id | 원본 파일 | 쪽 | 목차의 근거 | 메모 |", "|---|---|---|---|---|"]
    for s in targets {
      lines.append("| \(s.id) | \(s.meta.original.name) | \(s.meta.pages) | \(s.labels.syllabusBasis ? "예" : "아니오") | \(s.labels.memo ?? "") |")
    }
    if !earlier.isEmpty {
      lines += ["", "## 같은 묶음에서 이미 읽은 자료", "", "이 자료들은 다시 읽지 않는다. 그 엔트리는 input/bundle/entries/ 에 있다. 같은 개념이면 같은 제목을 쓴다.", ""]
      for s in earlier { lines.append("- \(s.id) (\(s.meta.original.name), \(s.meta.pages)쪽)") }
      lines += ["", "엔트리 제목: " + (earlierEntries.isEmpty ? "없음" : earlierEntries.map(\.title).joined(separator: " · "))]
    }
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

  // 자료 하나를 읽은 결과 (out/sources/<자료 id>.json)
  struct Note: Sendable {
    let title: String?
    let kind: String?
    let assessment: Bool
    let skipped: [Int]
    // 자료가 밝힌 학습 목표 (DECISIONS.md 25)
    var outcomes: [LearningOutcome] = []
  }

  struct DraftClaim: Sendable {
    let text: String
    let source: String
    let pages: [Int]
    let conditions: [String]
  }

  struct Draft: Sendable {
    let file: String
    let slug: String
    let title: String
    let item: String?
    let body: String
    let claims: [DraftClaim]
    let symbols: [SymbolDef]
    let examples: [String]
    let misconceptions: [String]
    // 자료 id → 쪽
    let pages: [String: [Int]]
    // 자료의 차례대로
    let sources: [String]
  }

  struct Checked: Sendable {
    var bundleTitle: String?
    // 자료 id → 읽은 결과
    var notes: [String: Note] = [:]
    var report: String?
    var entries: [Draft] = []
    // 작업 전체의 문제 (고쳐 써도 남으면 실패)
    var problems: [String] = []
    // 엔트리별 문제 (고쳐 써도 남으면 그 엔트리만 넣지 않는다)
    var rejected: [(file: String, problems: [String])] = []

    var allProblems: [String] { problems + rejected.flatMap { r in r.problems.map { "out/entries/\(r.file): \($0)" } } }
  }

  static func check(out: URL, sources metas: [SourceMeta], math: MathChecker?) -> Checked {
    var c = Checked()
    switch AgentJSON.read(out.appending(path: "bundle.json"), label: "out/bundle.json") {
    case .failure(let p): c.problems.append(p.message)
    case .success(let v):
      if let t = AgentJSON.string(v["title"]) {
        c.bundleTitle = t
        c.problems += TextChecks.englishProblems(t, field: "out/bundle.json title")
      } else {
        c.problems.append("out/bundle.json: title(묶음의 영어 이름)이 있어야 한다")
      }
    }
    for meta in metas {
      let label = "out/sources/\(meta.id).json"
      switch AgentJSON.read(out.appending(path: "sources/\(meta.id).json"), label: label) {
      case .failure(let p): c.problems.append(p.message)
      case .success(let v):
        let pages = 1...max(meta.pages, 1)
        let skipped = (v["skipped_pages"]?.arrayValue ?? []).compactMap { $0["page"]?.numberValue.map { Int($0) } ?? $0.numberValue.map { Int($0) } }
        var note = Note(
          title: AgentJSON.string(v["title"]), kind: AgentJSON.string(v["kind"]), assessment: v["assessment"]?.boolValue ?? false, skipped: skipped)
        if let t = note.title { c.problems += TextChecks.englishProblems(t, field: "\(label) title") }
        for (i, o) in (v["outcomes"]?.arrayValue ?? []).enumerated() {
          guard let text = AgentJSON.string(o["text"]) else {
            c.problems.append("\(label) outcomes[\(i)]: text 가 있어야 한다")
            continue
          }
          let ps = AgentJSON.ints(o["pages"])
          c.problems += TextChecks.englishProblems(text, field: "\(label) outcomes[\(i)].text")
          for p in ps where !pages.contains(p) { c.problems.append("\(label) outcomes[\(i)].pages: 없는 쪽입니다 (\(p))") }
          note.outcomes.append(LearningOutcome(text: text, pages: ps, source: meta.id))
        }
        for p in skipped where !pages.contains(p) { c.problems.append("\(label) skipped_pages: 없는 쪽입니다 (\(p))") }
        c.notes[meta.id] = note
      }
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
    // 개념이 없는 자료(단원 계획서 같은 것)와 평가 과제는 엔트리가 없어도 된다. 그때는 자료마다 평가 과제이거나 모든 쪽이 skipped_pages 에 있어야 한다.
    let nothingToWrite = metas.allSatisfy { meta in
      guard let note = c.notes[meta.id] else { return false }
      return note.assessment || Set(1...max(meta.pages, 1)).isSubset(of: Set(note.skipped))
    }
    if files.isEmpty && !nothingToWrite {
      c.problems.append("out/entries/ 에 엔트리가 없습니다. 개념이 없는 자료이면 그 자료의 모든 쪽을 out/sources/<자료 id>.json 의 skipped_pages 에 까닭과 함께 적는다")
    }
    for file in files {
      switch AgentJSON.read(entriesDir.appending(path: file), label: "out/entries/\(file)") {
      case .failure(let p): c.rejected.append((file, [p.message]))
      case .success(let v):
        let (draft, problems) = checkEntry(v, file: file, sources: metas, math: math)
        if let draft, problems.isEmpty { c.entries.append(draft) } else { c.rejected.append((file, problems)) }
      }
    }
    return c
  }

  static func checkEntry(_ v: JSONValue, file: String, sources metas: [SourceMeta], math: MathChecker?) -> (Draft?, [String]) {
    var problems: [String] = []
    let pageCount = Dictionary(metas.map { ($0.id, $0.pages) }, uniquingKeysWith: { a, _ in a })
    // 자료가 하나뿐이면 자료 id 를 빠뜨려도 그 자료로 본다
    let only = metas.count == 1 ? metas[0].id : nil
    func valid(_ source: String, _ page: Int) -> Bool { (1...max(pageCount[source] ?? 0, 1)).contains(page) }
    let title = AgentJSON.string(v["title"])
    let body = AgentJSON.string(v["body"])
    if title == nil { problems.append("title 이 없습니다") }
    if body == nil { problems.append("body 가 없습니다") }
    var claims: [DraftClaim] = []
    for (i, raw) in (v["claims"]?.arrayValue ?? []).enumerated() {
      guard let text = AgentJSON.string(raw["text"]) else {
        problems.append("claims[\(i)]: text 가 없습니다")
        continue
      }
      guard let source = AgentJSON.string(raw["source"]) ?? only else {
        problems.append("claims[\(i)]: 자료 id(source)가 없습니다")
        continue
      }
      guard pageCount[source] != nil else {
        problems.append("claims[\(i)]: 읽을 자료 표에 없는 자료입니다 (\(source))")
        continue
      }
      let ps = AgentJSON.ints(raw["pages"])
      if ps.isEmpty { problems.append("claims[\(i)]: 출처 쪽(pages)이 없습니다") }
      for p in ps where !valid(source, p) { problems.append("claims[\(i)]: 없는 쪽입니다 (\(source) \(p))") }
      claims.append(DraftClaim(text: text, source: source, pages: ps, conditions: AgentJSON.strings(raw["conditions"])))
    }
    if claims.isEmpty { problems.append("claims 가 없습니다. 주장마다 자료와 쪽을 단다") }
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
    // 자료마다 쪽: 엔트리의 pages(자료 id → 쪽, 자료가 하나면 쪽 목록)와 주장의 쪽
    var pages: [String: Set<Int>] = [:]
    if let map = v["pages"]?.objectValue {
      for (source, list) in map where pageCount[source] != nil { pages[source, default: []].formUnion(AgentJSON.ints(list).filter { valid(source, $0) }) }
    } else if let only {
      pages[only, default: []].formUnion(AgentJSON.ints(v["pages"]).filter { valid(only, $0) })
    }
    for c in claims { pages[c.source, default: []].formUnion(c.pages) }
    // 자료의 차례: 주장에 처음 나온 차례
    var order: [String] = []
    for c in claims where !order.contains(c.source) { order.append(c.source) }
    for s in metas.map(\.id) where pages[s] != nil && !order.contains(s) { order.append(s) }
    return (
      Draft(
        file: file, slug: slug, title: title, item: item, body: body, claims: claims, symbols: symbols, examples: examples,
        misconceptions: misconceptions, pages: pages.mapValues { $0.sorted() }, sources: order), []
    )
  }

  // MARK: - 반영

  // 엔트리를 쓴다. held 에 있는 파일(학생 독자 시험에 떨어진 엔트리)은 보류 까닭을 달아 쓴다.
  static func place(_ drafts: [Draft], held: [String: String] = [:], subject: String, data: DataFolder, jobID: String, provenance: YAMLMap) throws -> [Entry] {
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
            id: id, subject: subject, item: item?.code, itemProposed: item == nil ? d.item : nil, title: d.title,
            sources: d.sources.map { EntrySource(source: $0, pages: d.pages[$0] ?? []) },
            claims: d.claims.map { c in EntryClaim(text: c.text, src: c.pages.map { SourceRef.make(c.source, page: $0) }, conditions: c.conditions) },
            symbols: d.symbols, examples: d.examples, misconceptions: d.misconceptions, body: d.body, recorded: recorded, provenance: provenance,
            held: held[d.file]))
      }
      for e in entries { try FileOps.writeNew(e.markdown, to: data.entryFile(e.id)) }
      return entries
    }
  }

  static func reportMarkdown(
    _ body: String, bundle: String, checked: Checked, metas: [SourceMeta], entries: [Entry], coverages: [Coverage], warnings: [String],
    instructions: Instructions, ctx: JobContext
  ) -> String {
    let materials: [YAMLValue] = metas.map { meta in
      let note = checked.notes[meta.id]
      return .map([
        "source": .string(meta.id),
        "title": note?.title.map(YAMLValue.string) ?? .null,
        "kind": note?.kind.map(YAMLValue.string) ?? .null,
        "assessment": .bool(note?.assessment ?? false),
        "outcomes": .array((note?.outcomes ?? []).map { .map(["text": .string($0.text), "pages": .array($0.pages.map(YAMLValue.int))]) }),
      ])
    }
    var unread = YAMLMap([])
    for (meta, c) in zip(metas, coverages) where !c.unread.isEmpty { unread[meta.id] = YAMLValue.array(c.unread.map(YAMLValue.int)) }
    let head: YAMLMap = [
      "kind": "reading-report",
      "v": 1,
      "job": .string(ctx.id),
      "bundle": .string(bundle),
      "bundle_title": checked.bundleTitle.map(YAMLValue.string) ?? .null,
      "materials": .array(materials),
      "entries": .array(entries.filter { $0.held == nil }.map { .string($0.id) }),
      "held_entries": .array(entries.filter { $0.held != nil }.map { .string($0.id) }),
      "unread_pages": .map(unread),
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
      let list = head["materials"]?.array?.first { $0["source"]?.string == source }?["outcomes"]?.array ?? []
      for o in list {
        guard let t = o["text"]?.string else { continue }
        let key = t.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard seen.insert(key).inserted else { continue }
        out.append(LearningOutcome(text: t, pages: (o["pages"]?.array ?? []).compactMap(\.int), source: source))
      }
    }
    return out
  }

  // 읽기가 알아낸 자료의 영어 제목과 종류 (마지막 읽기 기록의 report.md 머리말의 materials)
  public static func material(_ data: DataFolder, source: String, read: [String: [String]]? = nil) -> (title: String?, kind: String?)? {
    let root = data.records.appending(path: JobKind.sourceReading.rawValue)
    guard let job = (read ?? readSources(data))[source]?.last, let text = FileOps.readIfExists(root.appending(path: job).appending(path: "report.md")),
      let (head, _) = FrontMatter.split(text)
    else { return nil }
    guard let m = head["materials"]?.array?.first(where: { $0["source"]?.string == source }) else { return nil }
    return (m["title"]?.string, m["kind"]?.string)
  }

  // 자료마다 끝난 자료 읽기 작업 id (기록의 request.md 머리말에서 읽는다)
  public static func readSources(_ data: DataFolder) -> [String: [String]] {
    let root = data.records.appending(path: JobKind.sourceReading.rawValue)
    var out: [String: [String]] = [:]
    for job in FileOps.list(root).sorted() where JobID.isValid(job) {
      guard let text = FileOps.readIfExists(root.appending(path: job).appending(path: "request.md")), let (head, _) = FrontMatter.split(text) else { continue }
      for source in head["sources"]?.strings ?? [] { out[source, default: []].append(job) }
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

  // prefix: 그 자료의 쪽 파일이 놓인 작업 공간 경로 (input/sources/<자료 id>/pages/)
  static func make(meta: SourceMeta, read files: Set<String>, cited: Set<Int>, skipped: [Int], prefix: String = "input/pages/") -> Coverage {
    var read: Set<Int> = []
    for f in files where f.hasPrefix(prefix) {
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
