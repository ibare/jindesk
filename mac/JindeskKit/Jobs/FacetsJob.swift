// 관점 붙이기 (facets, JOBS.md). Assayer 의 기술 추출과 같은 모양이다. 관점은 고정이고, 값은 어휘로 맞춘다.
// 1. 개념 여덟 개씩 에이전트가 관점을 붙인다 (웹 없음).
// 2. 레퍼런스 찾기: 아직 찾지 않은 개념을 열두 개씩 묶어 새 에이전트가 대표 공개 자료를 셋까지 찾는다. 웹을 쓰는 곳은 여기뿐이다.
//    러너는 https 주소이면서 그 에이전트의 이벤트 기록에서 WebFetch 가 성공한 주소만 받는다. 찾지 못한 개념은 빈 목록으로 둔다.
import Foundation

public enum Facets {
  static let batch = 8
  static let referenceBatch = 12
  static let prompt = "input/request.md 의 개념들에 지침의 \"관점\"대로 관점을 붙여라. 개념은 input/concepts/ 에 있다. out/facets.json 을 쓴다."
  static let referencePrompt =
    "input/request.md 의 개념들마다 지침의 \"레퍼런스 찾기\"대로 학생이 볼 만한 대표 공개 자료를 셋까지 찾아라. 웹 검색과 웹 조회를 쓴다. out/references.json 을 쓴다."

  public static func prepare(subject: String, _ ctx: PrepareContext) throws -> PreparedJob {
    let id = try JobID.make(date: ctx.now, slugSource: "facets \(subject)", exists: ctx.taken)
    return PreparedJob(id: id, kind: .facets, title: subject, target: subject, coalesceKey: "facets:\(subject)") { c in
      try await run(subject: subject, c)
    }
  }

  // 관점이 없거나 개념 원문이 바뀐 개념
  public static func pendingFacets(_ data: DataFolder, subject: String) -> [Concept] {
    ConceptStore.all(data, subject: subject).filter { c in
      let f = ConceptFacets.load(ConceptFolder(c.cid, in: data))
      return f == nil || f?.from != ConceptStore.fileHash(data, id: c.cid)
    }
  }

  public static func pendingReferences(_ data: DataFolder, subject: String) -> [Concept] {
    let refs = References.load(data)
    return ConceptStore.all(data, subject: subject).filter { refs.concepts[$0.id] == nil }
  }

  static func run(subject: String, _ ctx: JobContext) async throws {
    await ctx.setPhase("preparing")
    let todo = pendingFacets(ctx.data, subject: subject)
    let toSearch = pendingReferences(ctx.data, subject: subject)
    if todo.isEmpty && toSearch.isEmpty {
      await ctx.log(.info, "붙일 관점과 찾을 레퍼런스가 없습니다")
      return
    }
    let (instructions, instructionsFile) = try await AgentStep.fixInstructions(.facets, ctx, into: ctx.folders.workDir(ctx.id))
    let syllabus = Syllabus.load(ctx.data, subject: subject)
    var tagged = 0
    for (n, chunk) in stride(from: 0, to: todo.count, by: batch).map({ Array(todo[$0..<min($0 + batch, todo.count)]) }).enumerated() {
      await ctx.setPhase("running")
      tagged += try await tag(chunk, n: n, subject: subject, syllabus: syllabus, ctx: ctx, instructions: instructions, instructionsFile: instructionsFile)
    }
    var found = 0
    for (n, chunk) in stride(from: 0, to: toSearch.count, by: referenceBatch).map({ Array(toSearch[$0..<min($0 + referenceBatch, toSearch.count)]) }).enumerated() {
      await ctx.setPhase("running")
      found += try await search(chunk, n: n, ctx: ctx, instructionsFile: instructionsFile)
    }
    await ctx.report(counts: [JobCount(key: "facets", label: "관점", count: tagged), JobCount(key: "references", label: "레퍼런스", count: found)])
  }

  // MARK: - 관점

  static func tag(
    _ concepts: [Concept], n: Int, subject: String, syllabus: Syllabus?, ctx: JobContext, instructions: Instructions, instructionsFile: URL
  ) async throws -> Int {
    let dirs = AgentDirs(ctx.folders, ctx.id, sub: "facets-\(n + 1)")
    try dirs.make()
    let vocab = FacetVocab.load(ctx.data)
    var r = ["# 관점 붙이기", "", "- 과목 id: \(subject)", "", "## 개념", ""]
    for (i, c) in concepts.enumerated() {
      let key = String(format: "k%02d", i + 1)
      r.append("- \(key): \(c.title)")
      try FileOps.copy(ConceptFolder(c.cid, in: ctx.data).concept, to: dirs.input.appending(path: "concepts/\(key).yaml"))
    }
    r += ["", "## 이 과목의 관련 개념 어휘 (맞는 것이 있으면 이 표기를 쓴다)", "", (vocab.related[subject] ?? []).joined(separator: ", ").nilIfEmpty ?? "아직 없다."]
    r += ["", "## 이 과목의 NOS 어휘", "", (vocab.nos[subject] ?? []).joined(separator: ", ").nilIfEmpty ?? "아직 없다."]
    if let syllabus, let programme = syllabus.programme { r += ["", "- 과정: \(programme)"] }
    try FileOps.write(r.joined(separator: "\n") + "\n", to: dirs.input.appending(path: "request.md"))
    let options = AgentStep.options(ctx, dirs, instructions: instructionsFile, prompt: prompt, events: "facets")
    let result = try await AgentStep.run(options, ctx, label: "관점 붙이기")
    await ctx.setPhase("checking")
    var checked = check(out: dirs.out, keys: concepts.indices.map { String(format: "k%02d", $0 + 1) })
    if !checked.problems.isEmpty {
      await ctx.setPhase("fixing")
      try await AgentStep.fix(options, session: result.sessionID, problems: checked.problems, ctx: ctx, label: "관점 붙이기", events: "facets-fix")
      checked = check(out: dirs.out, keys: concepts.indices.map { String(format: "k%02d", $0 + 1) })
    }
    guard checked.problems.isEmpty else { throw ToolError("관점 붙이기 검사 실패: " + checked.problems.prefix(5).joined(separator: " · ")) }
    await ctx.setPhase("finalizing")
    var v = FacetVocab.load(ctx.data)
    let prov = AgentStep.provenance(ctx, .facets, instructions)
    for (i, c) in concepts.enumerated() {
      guard let f = checked.values[String(format: "k%02d", i + 1)] else { continue }
      let folder = ConceptFolder(c.cid, in: ctx.data)
      let facets = ConceptFacets(
        concept: c.id, from: ConceptStore.fileHash(ctx.data, id: c.cid) ?? "", item: c.item, level: c.level ?? syllabus?.item(c.item)?.level,
        commandTerms: f.commandTerms, keyConcepts: f.keyConcepts, relatedConcepts: v.merge(f.related, subject: subject, nos: false),
        globalContexts: f.globalContexts, nos: v.merge(f.nos, subject: subject, nos: true), tok: f.tok, provenance: prov)
      try facets.write(folder)
    }
    try v.write(ctx.data)
    await ctx.log(.info, "관점: 개념 \(checked.values.count)개")
    return checked.values.count
  }

  struct Values: Sendable {
    var commandTerms: [String] = []
    var keyConcepts: [String] = []
    var related: [String] = []
    var globalContexts: [String] = []
    var nos: [String] = []
    var tok: [String] = []
  }

  struct Checked: Sendable {
    var values: [String: Values] = [:]
    var problems: [String] = []
  }

  static func check(out: URL, keys: [String]) -> Checked {
    var c = Checked()
    let v: JSONValue
    switch AgentJSON.read(out.appending(path: "facets.json"), label: "out/facets.json") {
    case .failure(let p):
      c.problems.append(p.message)
      return c
    case .success(let value): v = value
    }
    func fixed(_ raw: JSONValue?, _ list: [String], _ field: String, _ key: String, max: Int) -> [String] {
      let values = AgentJSON.strings(raw)
      if values.count > max { c.problems.append("\(key).\(field): \(max)개까지다") }
      return values.compactMap { value in
        guard let hit = FacetVocabulary.canonical(value, in: list) else {
          c.problems.append("\(key).\(field): 정해진 목록에 없는 값입니다 (\(value))")
          return nil
        }
        return hit
      }
    }
    for key in keys {
      guard let f = v["concepts"]?[key] else {
        c.problems.append("\(key): 관점이 없습니다")
        continue
      }
      var x = Values()
      x.commandTerms = fixed(f["command_terms"], FacetVocabulary.commandTerms, "command_terms", key, max: 5)
      x.keyConcepts = fixed(f["key_concepts"], FacetVocabulary.keyConcepts, "key_concepts", key, max: 2)
      x.globalContexts = fixed(f["global_contexts"], FacetVocabulary.globalContexts, "global_contexts", key, max: 1)
      x.tok = fixed(f["tok"], FacetVocabulary.tok, "tok", key, max: 2)
      x.related = AgentJSON.strings(f["related_concepts"])
      x.nos = AgentJSON.strings(f["nos"])
      if x.related.count > 4 { c.problems.append("\(key).related_concepts: 4개까지다") }
      if x.nos.count > 2 { c.problems.append("\(key).nos: 2개까지다") }
      for t in x.related + x.nos { c.problems += TextChecks.englishProblems(t, field: "\(key)") }
      c.values[key] = x
    }
    return c
  }

  // MARK: - 레퍼런스 찾기

  static func search(_ concepts: [Concept], n: Int, ctx: JobContext, instructionsFile: URL) async throws -> Int {
    let dirs = AgentDirs(ctx.folders, ctx.id, sub: "references-\(n + 1)")
    try dirs.make()
    var r = ["# 레퍼런스 찾기", "", "## 개념", ""]
    for (i, c) in concepts.enumerated() {
      r.append("- \(String(format: "k%02d", i + 1)): \(c.title) — \(c.units.first.map { FileOps.prefix($0.text, 200) } ?? "")")
    }
    try FileOps.write(r.joined(separator: "\n") + "\n", to: dirs.input.appending(path: "request.md"))
    var options = AgentStep.options(ctx, dirs, instructions: instructionsFile, prompt: referencePrompt, events: "references")
    options.externalGuard = try ExternalGuard.prepare(directory: dirs.run.path)
    _ = try await AgentStep.run(options, ctx, label: "레퍼런스 찾기")
    let fetched = EventCoverage.fetchedURLs([dirs.events("references")])
    let v = (try? JSONValue.parse(Data(contentsOf: dirs.out.appending(path: "references.json")))) ?? .object([:])
    var refs = References.load(ctx.data)
    var found = 0
    for (i, c) in concepts.enumerated() {
      let key = String(format: "k%02d", i + 1)
      var items: [Reference] = []
      for item in v[key]?.arrayValue ?? [] {
        guard let url = AgentJSON.string(item["url"]), url.hasPrefix("https://"), EventCoverage.matches(url, in: fetched),
          ExternalCallCheck.blockReason(tool: "WebFetch", input: .object(["url": .string(url)])) == nil
        else { continue }
        let title = AgentJSON.string(item["title"]) ?? url
        items.append(Reference(url: url, title: title, kind: AgentJSON.string(item["kind"]) ?? "", why: AgentJSON.string(item["why"]) ?? ""))
        if items.count == 3 { break }
      }
      refs.concepts[c.id] = (ctx.id, items)
      found += items.count
    }
    try refs.write(ctx.data)
    await ctx.log(.info, "레퍼런스: \(found)개 (열어 본 주소 \(fetched.count)개)")
    return found
  }
}

extension EventCoverage {
  // 이벤트 기록에서 WebFetch 가 성공한 주소
  public static func fetchedURLs(_ events: [URL]) -> Set<String> {
    var calls: [String: String] = [:]
    var ok: Set<String> = []
    for file in events {
      guard let text = FileOps.readIfExists(file) else { continue }
      for line in text.split(separator: "\n") {
        guard let event = try? JSONValue.parse(Data(line.utf8)) else { continue }
        for item in event["message"]?["content"]?.arrayValue ?? [] {
          if item["type"]?.stringValue == "tool_use", item["name"]?.stringValue == "WebFetch", let id = item["id"]?.stringValue,
            let url = item["input"]?["url"]?.stringValue
          {
            calls[id] = url
          }
          if item["type"]?.stringValue == "tool_result", let id = item["tool_use_id"]?.stringValue, item["is_error"]?.boolValue != true, let url = calls[id] {
            ok.insert(url)
          }
        }
      }
    }
    return ok
  }

  // 끝의 / 와 # 뒤를 가리지 않고 견준다
  public static func matches(_ url: String, in fetched: Set<String>) -> Bool {
    func norm(_ s: String) -> String {
      var t = s.split(separator: "#").first.map(String.init) ?? s
      while t.hasSuffix("/") { t.removeLast() }
      return t.lowercased()
    }
    let k = norm(url)
    return fetched.contains { norm($0) == k }
  }
}
