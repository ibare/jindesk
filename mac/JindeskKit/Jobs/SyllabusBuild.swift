// 목차 만들기 (syllabus-build, JOBS.md). 과목의 근거 문서(자료 넣기에서 "목차의 근거"로 표시한 과목 가이드, 공개 과목 요약,
// 선생님의 과정·단원 안내, MYP 단원 안내)로 강의 계획 목차를 만든다. 처음 만든 목차는 확인 전으로 두고 화면에서 확인한다.
// 보강: 목차 밖 개념을 넣을 항목이 생겼으면 그 항목으로 옮긴다.
import Foundation

public enum SyllabusBuild {
  static let prompt =
    "input/request.md 의 근거 문서로 지침대로 이 과목의 강의 계획 목차를 만들어라. 문서마다 input/sources/<자료 id>/ 에 index.md 와 쪽 이미지가 있다. "
    + "out/syllabus.json 과 out/report.md 를 쓴다."

  static let levels: Set<String> = ["SL", "HL", "SL+HL", "Standard", "Extended", "Standard+Extended"]

  public static func prepare(subject: String, _ ctx: PrepareContext) throws -> PreparedJob {
    let id = try JobID.make(date: ctx.now, slugSource: "syllabus \(subject)", exists: ctx.taken)
    return PreparedJob(id: id, kind: .syllabusBuild, title: subject, target: subject, coalesceKey: "syllabus-build:\(subject)", recipe: .syllabusBuild(subject: subject)) { c in
      try await run(subject: subject, c)
    }
  }

  public static func basis(_ library: SourceLibrary, subject: String) -> [SourceSummary] {
    library.sources.filter { $0.labels.labels.subjectID == subject && $0.labels.syllabusBasis }.sorted { $0.meta.received < $1.meta.received }
  }

  // 근거 문서가 목차보다 새로 들어왔으면 다시 만든다
  public static func needed(_ data: DataFolder, subject: String, library: SourceLibrary) -> Bool {
    let docs = basis(library, subject: subject)
    guard !docs.isEmpty else { return false }
    guard let syllabus = Syllabus.load(data, subject: subject) else { return true }
    let used = Set(syllabus.sources.map(\.id))
    return docs.contains { !used.contains($0.id) }
  }

  static func run(subject: String, _ ctx: JobContext) async throws {
    await ctx.setPhase("preparing")
    let library = SourceLibrary.load(ctx.data)
    let docs = basis(library, subject: subject)
    guard !docs.isEmpty else {
      await ctx.log(.info, "근거 문서가 없습니다. 자료 넣기에서 \"목차의 근거\"로 표시한 자료가 있어야 합니다")
      return
    }
    let old = Syllabus.load(ctx.data, subject: subject)
    let concepts = ConceptStore.all(ctx.data, subject: subject)
    let entries = EntryStore.all(ctx.data, subject: subject)
    let usedCodes = Set(concepts.compactMap(\.item) + entries.compactMap(\.item))
    let unplaced = concepts.filter { $0.item == nil }

    let dirs = AgentDirs(ctx.folders, ctx.id)
    try dirs.make()
    let (instructions, instructionsFile) = try await AgentStep.fixInstructions(.syllabusBuild, ctx, into: dirs.run)
    var request = ["# 목차 만들기 요청", "", "- 과목 id: \(subject)"]
    if let s = library.subjects.first(where: { $0.id == subject }) {
      request.append("- 과목 꼬리표: \(s.name)")
      if !s.grades.isEmpty { request.append("- 학년: \(s.grades.joined(separator: ", "))") }
      if !s.levels.isEmpty { request.append("- 수준: \(s.levels.joined(separator: ", "))") }
    }
    request += ["", "## 근거 문서", ""]
    for d in docs {
      request.append("- `\(d.id)` \(d.meta.original.name) (\(d.meta.pages)쪽)\(d.labels.memo.map { " — 메모: \($0)" } ?? "")")
      let dir = dirs.input.appending(path: "sources/\(d.id)")
      try FileOps.copy(d.folder.index, to: dir.appending(path: "index.md"))
      for n in 1...max(d.meta.pages, 1) {
        try FileOps.copy(d.folder.pageText(n), to: dir.appending(path: "pages/\(SourceFolder.pageName(n)).txt"))
        try FileOps.copy(try SourcePages.image(d.folder, page: n, folders: ctx.folders), to: dir.appending(path: "pages/\(SourceFolder.pageName(n)).png"))
      }
    }
    request += ["", "## 이미 쓰인 항목 코드 (사라지면 안 된다. 바뀌었으면 renamed_from 을 단다)", ""]
    request.append(usedCodes.isEmpty ? "없다." : usedCodes.sorted().map { "`\($0)`" }.joined(separator: ", "))
    request += ["", "## 목차 밖 개념 (넣을 항목이 있으면 placements 에 적는다)", ""]
    if unplaced.isEmpty { request.append("없다.") }
    for c in unplaced { request.append("- `\(c.id)` \(c.title)\(c.itemProposed.map { " (단원 제안: \($0))" } ?? "")") }
    request.append("")
    request.append("- 지금 목차: \(old == nil ? "없다" : "input/syllabus.yaml")")
    try FileOps.write(request.joined(separator: "\n") + "\n", to: dirs.input.appending(path: "request.md"))
    if old != nil { try FileOps.copy(ctx.data.syllabusFile(subject), to: dirs.input.appending(path: "syllabus.yaml")) }
    await ctx.log(.info, "근거 문서 \(docs.count)개, 이미 쓰인 코드 \(usedCodes.count)개, 목차 밖 개념 \(unplaced.count)개")
    try ctx.checkCancellation()

    await ctx.setPhase("running")
    let options = AgentStep.options(ctx, dirs, instructions: instructionsFile, prompt: prompt, events: "syllabus")
    let result = try await AgentStep.run(options, ctx, label: "목차 만들기")
    await ctx.setPhase("checking")
    let pages = Dictionary(docs.map { ($0.id, $0.meta.pages) }, uniquingKeysWith: { a, _ in a })
    var checked = check(out: dirs.out, pages: pages, usedCodes: usedCodes, unplaced: Set(unplaced.map(\.id)))
    if !checked.problems.isEmpty {
      await ctx.log(.warn, "검사에서 \(checked.problems.count)건이 나와 고쳐 쓰게 합니다")
      await ctx.setPhase("fixing")
      try await AgentStep.fix(options, session: result.sessionID, problems: checked.problems, ctx: ctx, label: "목차 만들기", events: "syllabus-fix")
      await ctx.setPhase("checking")
      checked = check(out: dirs.out, pages: pages, usedCodes: usedCodes, unplaced: Set(unplaced.map(\.id)))
    }
    guard checked.problems.isEmpty, let draft = checked.draft else {
      throw ToolError("목차 만들기 검사 실패: " + checked.problems.prefix(8).joined(separator: " · "))
    }

    await ctx.setPhase("finalizing")
    let syllabus = Syllabus(
      subject: subject, programme: draft.programme, sources: docs.map { ($0.id, (($0.meta.original.name as NSString).deletingPathExtension)) },
      tree: draft.tree, confirmed: nil, provenance: AgentStep.provenance(ctx, .syllabusBuild, instructions))
    try syllabus.write(ctx.data)
    // 보강: 목차 밖 개념을 항목으로 옮긴다
    var moved = 0
    let former = Moves.formerConcepts(ctx.data)
    for (conceptID, code) in draft.placements {
      guard let cid = ConceptID(conceptID), let item = syllabus.item(code) else { continue }
      // 옮기거나 없앤 개념의 옛 id 면 뒤에 수를 붙인다
      var to = ConceptID(subject: subject, item: ItemPath.dir(item.code), slug: cid.slug)
      var n = 2
      while former.contains(to.text) {
        to = ConceptID(subject: subject, item: ItemPath.dir(item.code), slug: "\(cid.slug)-\(n)")
        n += 1
      }
      do {
        try ConceptMove.move(ctx.data, from: cid, to: to, why: "목차 \(item.code)")
        moved += 1
      } catch {
        await ctx.log(.warn, "\(conceptID) 를 \(item.code) 로 옮기지 못했습니다: \(error.localizedDescription)")
      }
    }
    let record = ctx.data.record(JobKind.syllabusBuild.rawValue, ctx.id)
    try FileOps.writeNew(JSONText.record(draft.record(docs: docs.map(\.id))), to: record.appending(path: "decisions.json"))
    if let report = FileOps.readIfExists(dirs.out.appending(path: "report.md")) { try FileOps.writeNew(report, to: record.appending(path: "report.md")) }
    await ctx.report(counts: [
      JobCount(key: "items", label: "항목", count: syllabus.items.count), JobCount(key: "moved", label: "옮긴 개념", count: moved),
    ])
    await ctx.log(.info, "목차: 항목 \(syllabus.items.count)개 (확인 전), 목차 밖 개념 \(moved)개를 옮겼습니다")
  }

  struct Draft: Sendable {
    let programme: String?
    let tree: [SyllabusItem]
    let placements: [(concept: String, item: String)]

    func record(docs: [String]) -> JSONValue {
      .object([
        "v": .number(1), "sources": .array(docs.map(JSONValue.string)), "programme": programme.map(JSONValue.string) ?? .null,
        "items": .number(Double(tree.count)),
        "placements": .array(placements.map { .object(["concept": .string($0.concept), "item": .string($0.item)]) }),
      ])
    }
  }

  struct Checked: Sendable {
    var draft: Draft?
    var problems: [String] = []
  }

  static func check(out: URL, pages: [String: Int], usedCodes: Set<String>, unplaced: Set<String>) -> Checked {
    var c = Checked()
    let v: JSONValue
    switch AgentJSON.read(out.appending(path: "syllabus.json"), label: "out/syllabus.json") {
    case .failure(let p):
      c.problems.append(p.message)
      return c
    case .success(let value): v = value
    }
    var seen: Set<String> = []
    var renamed: [String: String] = [:]
    func item(_ raw: JSONValue, at: String, parent: String?) -> SyllabusItem? {
      guard let code = AgentJSON.string(raw["code"]), let title = AgentJSON.string(raw["title"]) else {
        c.problems.append("\(at): code 와 title 이 있어야 한다")
        return nil
      }
      if !seen.insert(ItemPath.dir(code)).inserted { c.problems.append("\(at): 코드가 겹칩니다 (\(code))") }
      c.problems += TextChecks.englishProblems(title, field: "\(at).title")
      let level = AgentJSON.string(raw["level"])
      if let level, !levels.contains(level) { c.problems.append("\(at).level 은 \(levels.sorted().joined(separator: ", ")) 가운데 하나다 (\(level))") }
      let src = AgentJSON.strings(raw["src"])
      if src.isEmpty { c.problems.append("\(at): 출처 쪽(src)이 없습니다") }
      for s in src {
        guard let (doc, page) = SourceRef.parse(s), let count = pages[doc], (1...count).contains(page) else {
          c.problems.append("\(at).src: 근거 문서에 없는 쪽입니다 (\(s))")
          continue
        }
      }
      if let renamedFrom = AgentJSON.string(raw["renamed_from"]) { renamed[renamedFrom] = code }
      var myp: MYPUnit?
      if let m = raw["myp"], m.objectValue != nil {
        myp = MYPUnit(
          keyConcept: AgentJSON.string(m["key_concept"]), relatedConcepts: AgentJSON.strings(m["related_concepts"]),
          globalContext: AgentJSON.string(m["global_context"]), statementOfInquiry: AgentJSON.string(m["statement_of_inquiry"]))
      }
      let children = (raw["children"]?.arrayValue ?? []).enumerated().compactMap { item($0.element, at: "\(at).children[\($0.offset)]", parent: code) }
      return SyllabusItem(code: code, title: title, level: level, src: src, myp: myp, children: children, renamedFrom: AgentJSON.string(raw["renamed_from"]))
    }
    let tree = (v["items"]?.arrayValue ?? []).enumerated().compactMap { item($0.element, at: "items[\($0.offset)]", parent: nil) }
    if tree.isEmpty { c.problems.append("items 가 비었습니다") }
    for code in usedCodes.sorted() where !seen.contains(ItemPath.dir(code)) && renamed[code] == nil {
      c.problems.append("이미 쓰인 코드 \(code) 가 목차에서 사라졌습니다. 이름이 바뀌었으면 새 항목에 renamed_from 을 단다")
    }
    var placements: [(concept: String, item: String)] = []
    for (i, p) in (v["placements"]?.arrayValue ?? []).enumerated() {
      guard let concept = AgentJSON.string(p["concept"]), let code = AgentJSON.string(p["item"]) else { continue }
      if !unplaced.contains(concept) { c.problems.append("placements[\(i)]: 목차 밖 개념이 아닙니다 (\(concept))") }
      if !seen.contains(ItemPath.dir(code)) { c.problems.append("placements[\(i)]: 목차에 없는 항목입니다 (\(code))") }
      placements.append((concept, code))
    }
    let programme = AgentJSON.string(v["programme"])
    if c.problems.isEmpty { c.draft = Draft(programme: programme, tree: tree, placements: placements) }
    return c
  }
}
