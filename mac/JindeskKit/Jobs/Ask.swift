// 물어보기 (ask, JOBS.md). 학생이 단위에 단 질문에, 그 개념과 그 개념이 나온 자료의 쪽으로 답한다. 영어로 답하고 한국어를 붙인다.
// 웹을 찾지 않는다. 이 개념의 자료로 답할 수 없으면 그렇다고 답한다. 대화 대기열에서 돌고, 같은 개념의 질문은 차례로 돈다.
import Foundation

public enum Ask {
  static let prompt = "input/question.md 의 질문에 지침대로 답하라. 개념은 input/concept.yaml, 페이지는 input/page.yaml, 자료의 쪽은 input/sources/ 에 있다. out/answer.json 을 쓴다."

  public static func prepare(commentID: String, _ ctx: PrepareContext) throws -> PreparedJob {
    guard let comment = CommentStore.load(ctx.data).first(where: { $0.id == commentID }), comment.kind == .ask, let anchor = comment.anchor else {
      throw RequestError("질문을 찾지 못했습니다: \(commentID)")
    }
    guard let cid = ConceptID(anchor.concept), ConceptStore.load(ctx.data, id: cid) != nil else { throw RequestError("개념을 찾지 못했습니다: \(anchor.concept)") }
    let id = try JobID.make(date: ctx.now, slugSource: "ask \(cid.slug)", exists: ctx.taken)
    let title = FileOps.prefix(comment.text ?? "", 40)
    return PreparedJob(id: id, kind: .ask, title: title, serialKey: anchor.concept, target: anchor.concept, coalesceKey: "ask:\(commentID)", recipe: .ask(comment: commentID)) { c in
      try await run(comment: comment, cid: cid, c)
    }
  }

  // 아직 답이 없는 질문
  public static func unanswered(_ data: DataFolder) -> [Comment] {
    let comments = CommentStore.load(data)
    let answered = Set(comments.compactMap { $0.kind == .answer ? $0.replyTo : nil })
    return comments.filter { $0.kind == .ask && !answered.contains($0.id) }
  }

  static func run(comment: Comment, cid: ConceptID, _ ctx: JobContext) async throws {
    await ctx.setPhase("preparing")
    guard let anchor = comment.anchor, let concept = ConceptStore.load(ctx.data, id: cid) else { throw ToolError("개념을 찾지 못했습니다") }
    if !unanswered(ctx.data).contains(where: { $0.id == comment.id }) {
      await ctx.log(.info, "이미 답한 질문입니다")
      return
    }
    let folder = ConceptFolder(cid, in: ctx.data)
    let dirs = AgentDirs(ctx.folders, ctx.id)
    try dirs.make()
    let (instructions, instructionsFile) = try await AgentStep.fixInstructions(.ask, ctx, into: dirs.run)
    let page = Page.load(folder)
    let unit = page?.units.first { $0.id == anchor.unit }
    var q = ["# 질문", "", comment.text ?? "", "", "## 질문한 자리", "", "- 개념: \(concept.id) (\(concept.title))", "- 단위: \(anchor.unit) (판 \(anchor.rev))"]
    if let text = unit?.english { q += ["", "> " + text.split(separator: "\n").joined(separator: "\n> ")] }
    if !anchor.quote.isEmpty && unit == nil { q += ["", "> \(anchor.quote)"] }
    // 같은 단위의 앞선 질문과 답 (이어지는 질문일 수 있다)
    let earlier = CommentStore.load(ctx.data).filter { $0.anchor?.concept == concept.id && $0.anchor?.unit == anchor.unit && $0.id != comment.id }
    let answers = Dictionary(CommentStore.load(ctx.data).compactMap { c in c.replyTo.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
    if !earlier.isEmpty { q += ["", "## 이 자리의 앞선 코멘트", ""] }
    for e in earlier.suffix(5) {
      q.append("- (\(e.kind.label)) \(e.text ?? "")")
      if let a = answers[e.id], let en = a.textEn { q.append("  - 답: \(FileOps.prefix(en, 400))") }
    }
    q += ["", "## 자료", ""]
    var pagesBySource: [String: Set<Int>] = [:]
    for o in concept.occurrences { pagesBySource[o.source, default: []].formUnion(o.pages) }
    for ref in concept.refs { if let (s, p) = SourceRef.parse(ref) { pagesBySource[s, default: []].insert(p) } }
    let library = SourceLibrary.load(ctx.data)
    for (source, pages) in pagesBySource.sorted(by: { $0.key < $1.key }) {
      guard let summary = library.source(source) else { continue }
      let list = pages.sorted().filter { $0 >= 1 && $0 <= summary.meta.pages }
      q.append("- `\(source)` \(summary.meta.original.name): 쪽 \(list.map(String.init).joined(separator: ", "))")
      for n in list {
        let dir = dirs.input.appending(path: "sources/\(source)/pages")
        try FileOps.copy(summary.folder.pageText(n), to: dir.appending(path: "\(SourceFolder.pageName(n)).txt"))
        try FileOps.copy(try SourcePages.image(summary.folder, page: n, folders: ctx.folders), to: dir.appending(path: "\(SourceFolder.pageName(n)).png"))
      }
    }
    try FileOps.write(q.joined(separator: "\n") + "\n", to: dirs.input.appending(path: "question.md"))
    try FileOps.copy(folder.concept, to: dirs.input.appending(path: "concept.yaml"))
    if FileOps.exists(folder.page) { try FileOps.copy(folder.page, to: dirs.input.appending(path: "page.yaml")) }
    try AgentStep.writeGlossary(ctx.data, into: dirs.input)

    await ctx.setPhase("running")
    let options = AgentStep.options(ctx, dirs, instructions: instructionsFile, prompt: prompt, events: "ask")
    let result = try await AgentStep.run(options, ctx, label: "물어보기")
    await ctx.setPhase("checking")
    let available = Set(pagesBySource.flatMap { s, ps in ps.map { SourceRef.make(s, page: $0) } })
    var checked = check(out: dirs.out, available: available, glossary: Glossary.load(ctx.data))
    if !checked.problems.isEmpty {
      await ctx.setPhase("fixing")
      try await AgentStep.fix(options, session: result.sessionID, problems: checked.problems, ctx: ctx, label: "물어보기", events: "ask-fix")
      await ctx.setPhase("checking")
      checked = check(out: dirs.out, available: available, glossary: Glossary.load(ctx.data))
    }
    guard checked.problems.isEmpty, let answer = checked.answer else { throw ToolError("물어보기 검사 실패: " + checked.problems.prefix(5).joined(separator: " · ")) }

    await ctx.setPhase("finalizing")
    let reply = Comment(
      id: Comment.makeID(), at: Clock.isoLocal(), by: "job:ask", kind: .answer, replyTo: comment.id, job: ctx.id, textEn: answer.en, textKo: answer.ko,
      src: answer.src, supplementary: answer.supplementary)
    try CommentStore.append(ctx.data, reply)
    let record = ctx.data.record(JobKind.ask.rawValue, ctx.id)
    try FileOps.writeNew(JSONText.record(comment.json), to: record.appending(path: "question.json"))
    try FileOps.writeNew(JSONText.record(reply.json), to: record.appending(path: "answer.json"))
    let read = EventCoverage.readFiles([dirs.events("ask"), dirs.events("ask-fix")], workspace: dirs.workspace)
    try FileOps.writeNew(
      JSONText.record(.object(["v": .number(1), "read": .array(read.sorted().map(JSONValue.string)), "cited": .array(answer.src.map(JSONValue.string))])),
      to: record.appending(path: "coverage.json"))
    _ = instructions
    await ctx.log(.info, answer.outside ? "이 개념의 자료로는 답할 수 없는 질문이라고 답했습니다" : "답을 달았습니다")
  }

  struct Answer: Sendable {
    let en: String
    let ko: String
    let src: [String]
    let supplementary: Bool
    let outside: Bool
  }

  struct Checked: Sendable {
    var answer: Answer?
    var problems: [String] = []
  }

  static func check(out: URL, available: Set<String>, glossary: Glossary) -> Checked {
    var c = Checked()
    let v: JSONValue
    switch AgentJSON.read(out.appending(path: "answer.json"), label: "out/answer.json") {
    case .failure(let p):
      c.problems.append(p.message)
      return c
    case .success(let value): v = value
    }
    guard let en = AgentJSON.string(v["en"]), let ko = AgentJSON.string(v["ko"]) else {
      c.problems.append("en 과 ko 가 있어야 한다")
      return c
    }
    c.problems += TextChecks.englishProblems(en, field: "en")
    c.problems += Translation.unitProblems(en: en, ko: ko, glossary: glossary).map { "ko: \($0)" }
    let src = AgentJSON.strings(v["src"])
    for s in src where !available.contains(s) { c.problems.append("src: input/sources/ 에 없는 쪽입니다 (\(s))") }
    let supplementary = v["supplementary"]?.boolValue ?? false
    let outside = v["outside"]?.boolValue ?? false
    if src.isEmpty && !supplementary && !outside { c.problems.append("자료의 쪽(src)이 없으면 supplementary 를 true 로 둔다") }
    if c.problems.isEmpty { c.answer = Answer(en: en, ko: ko, src: src, supplementary: supplementary, outside: outside) }
    return c
  }
}
