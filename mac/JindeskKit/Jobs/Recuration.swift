// 고른 개념 다시 정리 (DECISIONS.md 47, JOBS.md). 사람이 고른 개념들을 그 엔트리로 지금 지침에 맞게 다시 정리한다.
// 개념이 줄거나 늘고, 나뉘거나 합쳐진다. 결과는 바로 반영하지 않고 후보(records/concept-curation/<작업 id>/proposal.json)로 둔다.
// 사람이 대응표를 보고 반영하면 개념을 쓰고, 없앤 개념을 지우고, 옛 단위가 간 자리를 moves.jsonl 에 남겨 코멘트와 요구가 따라가게 한다.
import Foundation

public enum Recuration {
  static let prompt =
    "input/request.md 의 \"다시 정리할 개념\"을 지침의 \"고른 개념 다시 정리\"대로 다시 정리하라. 고른 개념이 쓴 엔트리는 input/entries/, 보류된 엔트리는 input/held/, "
    + "이미 있는 개념(고른 개념 포함)은 input/concepts/ 에 있다. 결정은 out/plan.json 에, 고른 개념마다 무엇이 되었는지는 out/report.md 에 쓴다."

  public static func prepare(subject: String, concepts: [String], _ ctx: PrepareContext) throws -> PreparedJob {
    let ids = Array(Set(concepts)).sorted()
    guard !ids.isEmpty else { throw RequestError("다시 정리할 개념이 없습니다") }
    let id = try JobID.make(date: ctx.now, slugSource: "recurate \(subject)", exists: ctx.taken)
    return PreparedJob(
      id: id, kind: .conceptCuration, title: "\(subject) · 다시 정리 \(ids.count)개", target: subject,
      coalesceKey: "concept-recuration:\(subject):\(ids.joined(separator: ","))", recipe: .recuration(subject: subject, concepts: ids)
    ) { c in
      try await run(subject: subject, concepts: ids, c)
    }
  }

  static func run(subject: String, concepts ids: [String], _ ctx: JobContext) async throws {
    await ctx.setPhase("preparing")
    let input = try input(ctx.data, subject: subject, concepts: ids)
    let dirs = AgentDirs(ctx.folders, ctx.id)
    try dirs.make()
    let (instructions, instructionsFile) = try await AgentStep.fixInstructions(.conceptCuration, ctx, into: dirs.run)
    try ConceptCuration.writeInput(input, dirs: dirs, data: ctx.data)
    await ctx.log(.info, "고른 개념 \(ids.count)개, 그 엔트리 \(input.entries.count)개, 보류된 엔트리 \(input.held.count)개, 이 과목의 개념 \(input.concepts.count)개")
    try ctx.checkCancellation()

    await ctx.setPhase("running")
    let options = AgentStep.options(ctx, dirs, instructions: instructionsFile, prompt: prompt, events: "recurate")
    let result = try await AgentStep.run(options, ctx, label: "다시 정리")
    let (plan, warnings) = try await ConceptCuration.checkAndFix(input: input, dirs: dirs, options: options, session: result.sessionID, ctx: ctx, label: "다시 정리")

    // 후보로 둔다. 반영은 사람이 대응표를 본 뒤에 한다.
    await ctx.setPhase("finalizing")
    let planValue = AgentJSON.read(dirs.out.appending(path: "plan.json"), label: "out/plan.json")
    guard case .success(let raw) = planValue else { throw ToolError("out/plan.json 을 다시 읽지 못했습니다") }
    let provenance = AgentStep.provenance(ctx, .conceptCuration, instructions)
    let rows = rows(plan, input: input)
    let record = ctx.data.record(JobKind.conceptCuration.rawValue, ctx.id)
    try FileOps.writeNew(JSONText.record(proposalJSON(input: input, plan: raw, rows: rows, job: ctx.id, provenance: provenance)), to: record.appending(path: "proposal.json"))
    let report = FileOps.readIfExists(dirs.out.appending(path: "report.md")) ?? ""
    let head: YAMLMap = [
      "kind": "recuration-report", "v": 1, "job": .string(ctx.id), "subject": .string(subject),
      "selected": .array(ids.map(YAMLValue.string)), "provenance": .map(provenance),
    ]
    try FileOps.writeNew(FrontMatter.render(head) + "\n" + report.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", to: record.appending(path: "report.md"))

    await ctx.report(
      counts: [
        JobCount(key: "selected", label: "고른 개념", count: ids.count), JobCount(key: "after", label: "다시 정리한 뒤", count: plan.concepts.count),
        JobCount(key: "retired", label: "없앰", count: plan.retired.count), JobCount(key: "held", label: "보류", count: plan.held.count),
      ], warnings: warnings.isEmpty ? nil : warnings)
    for r in rows { await ctx.log(.info, "\(r.title): \(r.action)\(r.targets.isEmpty ? "" : " → " + r.targets.joined(separator: ", "))") }
    await ctx.log(.info, "후보를 만들었습니다. 대응표를 보고 반영하거나 버립니다")
  }

  // MARK: - 입력

  // 고른 개념으로 정리 입력을 만든다. 정리할 엔트리는 고른 개념이 쓴 엔트리이고, 이 과목의 개념은 모두 이미 있는 개념으로 넘긴다.
  static func input(_ data: DataFolder, subject: String, concepts ids: [String]) throws -> ConceptCuration.Input {
    let concepts = ConceptStore.all(data, subject: subject)
    for id in ids where !concepts.contains(where: { $0.id == id }) { throw RequestError("개념을 찾지 못했습니다: \(id)") }
    let keyed = concepts.enumerated().map { (key: String(format: "k%02d", $0.offset + 1), concept: $0.element) }
    let chosen = keyed.filter { ids.contains($0.concept.id) }
    var entryIDs: [String] = []
    for k in chosen { for o in k.concept.occurrences where !entryIDs.contains(o.entry) { entryIDs.append(o.entry) } }
    let all = EntryStore.all(data, subject: subject)
    let entries = entryIDs.compactMap { id in all.first { $0.id == id } }
    return try assemble(
      data, subject: subject, concepts: keyed.map { ($0.key, $0.concept.id) }, selected: Set(chosen.map(\.key)), entries: entries.map(\.id),
      hashes: Dictionary(concepts.compactMap { c in ConceptStore.fileHash(data, id: c.cid).map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a }))
  }

  // 키와 id 로 정리 입력을 짓는다 (후보를 반영할 때도 같은 키로 다시 짓는다).
  // hashes 가 지금 개념 파일과 다르면 던진다: 다시 정리한 사이 개념이 바뀌었다.
  static func assemble(
    _ data: DataFolder, subject: String, concepts: [(key: String, id: String)], selected: Set<String>, entries entryIDs: [String], hashes: [String: String],
    held keyedHeld: [(key: String, entry: String, reason: String)]? = nil
  ) throws -> ConceptCuration.Input {
    let all = ConceptStore.all(data, subject: subject)
    var keyed: [(key: String, concept: Concept)] = []
    for (key, id) in concepts {
      guard let c = all.first(where: { $0.id == id }) else { throw RequestError("개념이 없어졌습니다: \(id). 다시 정리를 다시 합니다") }
      guard ConceptStore.fileHash(data, id: c.cid) == hashes[id] else { throw RequestError("다시 정리한 사이 개념이 바뀌었습니다: \(id). 다시 정리를 다시 합니다") }
      keyed.append((key, c))
    }
    let pool = EntryStore.all(data, subject: subject)
    var entries: [(key: String, entry: Entry)] = []
    for (i, id) in entryIDs.enumerated() {
      guard let e = pool.first(where: { $0.id == id }) else { throw RequestError("엔트리를 찾지 못했습니다: \(id)") }
      entries.append((String(format: "e%02d", i + 1), e))
    }
    var held: [(key: String, entry: Entry, reason: String)] = []
    if let keyedHeld {
      for h in keyedHeld { if let e = pool.first(where: { $0.id == h.entry }) { held.append((h.key, e, h.reason)) } }
    } else {
      let ids = Set(entryIDs)
      held = ConceptCuration.heldEntries(data, subject: subject).filter { !ids.contains($0.entry.id) }.enumerated().map {
        (String(format: "h%02d", $0.offset + 1), $0.element.entry, $0.element.reason)
      }
    }
    // 고르지 않은 개념도 쓰는 엔트리는 그 개념에 그대로 남는다
    let elsewhere = Set(keyed.filter { !selected.contains($0.key) }.flatMap { $0.concept.occurrences.map(\.entry) })
    return ConceptCuration.Input(
      subject: subject, entries: entries, concepts: keyed, conceptHashes: hashes, others: ConceptStore.everything(data).filter { $0.subject != subject },
      held: held, recurate: selected, placedElsewhere: Set(entries.filter { elsewhere.contains($0.entry.id) }.map(\.key)))
  }

  // MARK: - 후보

  // 대응표의 한 줄: 고른 개념 하나가 무엇이 되었는지, 또는 엔트리에서 새로 생긴 개념
  public struct Row: Sendable, Equatable {
    // 고른 개념의 id. 새로 생긴 개념이면 빈 글
    public let concept: String
    public let title: String
    // 그대로, 보강, 다시 씀, 나눔, 합침, 없앰, 새 개념
    public let action: String
    // 내용이 간 개념의 제목 (새 개념은 "(새)"를 붙인다)
    public let targets: [String]
  }

  public struct Proposal: Sendable, Equatable, Identifiable {
    public let job: String
    public let subject: String
    public let rows: [Row]
    // 고른 개념 수와 다시 정리한 뒤의 개념 수, 보류한 엔트리 수
    public let before: Int
    public let after: Int
    public let held: Int
    public var id: String { job }
  }

  static func rows(_ plan: ConceptCuration.Plan, input: ConceptCuration.Input) -> [Row] {
    let selected = input.recurate ?? []
    func name(_ p: ConceptCuration.PlannedConcept) -> String { p.existing == nil ? "\(p.title) (새)" : p.title }
    func receivers(_ key: String, except: String?) -> [ConceptCuration.PlannedConcept] {
      plan.concepts.filter { p in p.existing != except && p.units.contains { u in u.from.contains { $0.hasPrefix("\(key).") } } }
    }
    var rows: [Row] = []
    var named: Set<String> = []
    for (key, old) in input.concepts where selected.contains(key) {
      if let r = plan.retired.first(where: { $0.key == key }) {
        let to = receivers(key, except: nil)
        to.forEach { named.insert($0.slug) }
        rows.append(Row(concept: old.id, title: old.title, action: r.dropped.isEmpty && !to.isEmpty ? "합침" : "없앰", targets: to.map(name)))
      } else if let p = plan.concepts.first(where: { $0.existing == key }) {
        let out = receivers(key, except: key)
        out.forEach { named.insert($0.slug) }
        named.insert(p.slug)
        let action: String
        if !out.isEmpty {
          action = "나눔"
        } else if p.title != old.title || !p.removed.isEmpty || zip(p.units, old.units).contains(where: { $0.id != $1.id || $0.text != $1.text }) || p.units.count < old.units.count {
          action = "다시 씀"
        } else if p.units.count > old.units.count {
          action = "보강"
        } else {
          action = "그대로"
        }
        rows.append(Row(concept: old.id, title: old.title, action: action, targets: ([p] + out).map(name)))
      }
    }
    for p in plan.concepts where p.existing == nil && !named.contains(p.slug) {
      rows.append(Row(concept: "", title: p.title, action: "새 개념", targets: []))
    }
    return rows
  }

  static func proposalJSON(input: ConceptCuration.Input, plan: JSONValue, rows: [Row], job: String, provenance: YAMLMap) -> JSONValue {
    let selected = input.recurate ?? []
    return .object([
      "v": .number(1), "kind": .string("recuration-proposal"), "job": .string(job), "subject": .string(input.subject), "at": .string(Clock.isoLocal()),
      "concepts": .array(input.concepts.map { .object(["key": .string($0.key), "id": .string($0.concept.id), "selected": .bool(selected.contains($0.key))]) }),
      "hashes": .object(input.conceptHashes.mapValues(JSONValue.string)),
      "entries": .array(input.entries.map { .string($0.entry.id) }),
      "held": .array(input.held.map { .object(["key": .string($0.key), "entry": .string($0.entry.id), "reason": .string($0.reason)]) }),
      "plan": plan,
      "provenance": json(provenance),
      "rows": .array(rows.map { .object(["concept": .string($0.concept), "title": .string($0.title), "action": .string($0.action), "targets": .array($0.targets.map(JSONValue.string))]) }),
      "before": .number(Double(selected.count)),
      "after": .number(Double(plan["concepts"]?.arrayValue?.count ?? 0)),
      "held_count": .number(Double(plan["held"]?.arrayValue?.count ?? 0)),
    ])
  }

  static func json(_ map: YAMLMap) -> JSONValue {
    func value(_ v: YAMLValue) -> JSONValue {
      switch v {
      case .null: .null
      case .bool(let b): .bool(b)
      case .int(let n): .number(Double(n))
      case .double(let d): .number(d)
      case .string(let s): .string(s)
      case .array(let a): .array(a.map(value))
      case .map(let m): json(m)
      }
    }
    return .object(Dictionary(map.entries.map { ($0.key, value($0.value)) }, uniquingKeysWith: { a, _ in a }))
  }

  static func folder(_ data: DataFolder, job: String) -> URL { data.record(JobKind.conceptCuration.rawValue, job) }

  static func readProposal(_ data: DataFolder, job: String) -> JSONValue? {
    guard let bytes = try? Data(contentsOf: folder(data, job: job).appending(path: "proposal.json")) else { return nil }
    return try? JSONValue.parse(bytes)
  }

  // 반영하지도 버리지도 않은 후보 (오래된 것부터)
  public static func pending(_ data: DataFolder) -> [Proposal] {
    let root = data.records.appending(path: JobKind.conceptCuration.rawValue)
    return FileOps.list(root).sorted().compactMap { job in
      guard JobID.isValid(job), !FileOps.exists(root.appending(path: job).appending(path: "decision.json")) else { return nil }
      return proposal(data, job: job)
    }
  }

  public static func proposal(_ data: DataFolder, job: String) -> Proposal? {
    guard let v = readProposal(data, job: job), let subject = v["subject"]?.stringValue else { return nil }
    let rows = (v["rows"]?.arrayValue ?? []).map { r in
      Row(
        concept: r["concept"]?.stringValue ?? "", title: r["title"]?.stringValue ?? "", action: r["action"]?.stringValue ?? "",
        targets: (r["targets"]?.arrayValue ?? []).compactMap(\.stringValue))
    }
    return Proposal(
      job: job, subject: subject, rows: rows, before: Int(v["before"]?.numberValue ?? 0), after: Int(v["after"]?.numberValue ?? 0),
      held: Int(v["held_count"]?.numberValue ?? 0))
  }

  // MARK: - 반영과 버리기

  public struct Applied: Sendable, Equatable {
    public let subject: String
    // 쓴 개념 (남기거나 새로 만든 것)
    public let written: [String]
    // 없앤 개념
    public let retired: [String]
    // 단위를 옮긴 줄의 수
    public let unitMoves: Int
  }

  // 후보를 반영한다. 다시 정리한 사이 개념이 바뀌었거나 후보가 지금 데이터와 맞지 않으면 아무것도 쓰지 않고 던진다.
  public static func apply(_ data: DataFolder, job: String) throws -> Applied {
    let dir = folder(data, job: job)
    guard let v = readProposal(data, job: job), let subject = v["subject"]?.stringValue, let rawPlan = v["plan"] else {
      throw RequestError("다시 정리 후보를 찾지 못했습니다: \(job)")
    }
    guard !FileOps.exists(dir.appending(path: "decision.json")) else { throw RequestError("이미 반영했거나 버린 후보입니다: \(job)") }
    let keyed = (v["concepts"]?.arrayValue ?? []).compactMap { c -> (key: String, id: String, selected: Bool)? in
      guard let k = c["key"]?.stringValue, let id = c["id"]?.stringValue else { return nil }
      return (k, id, c["selected"]?.boolValue ?? false)
    }
    let input = try assemble(
      data, subject: subject, concepts: keyed.map { ($0.key, $0.id) }, selected: Set(keyed.filter(\.selected).map(\.key)),
      entries: (v["entries"]?.arrayValue ?? []).compactMap(\.stringValue), hashes: (v["hashes"]?.objectValue ?? [:]).compactMapValues(\.stringValue),
      held: (v["held"]?.arrayValue ?? []).compactMap { h in
        guard let k = h["key"]?.stringValue, let e = h["entry"]?.stringValue else { return nil }
        return (k, e, h["reason"]?.stringValue ?? "보류")
      })
    let checked = ConceptCuration.check(plan: rawPlan, input: input, math: nil)
    guard checked.problems.isEmpty, let plan = checked.plan else {
      throw RequestError("후보가 지금 데이터와 맞지 않습니다: " + checked.problems.prefix(3).joined(separator: " · "))
    }
    let selected = input.recurate ?? []
    let byKey = Dictionary(input.concepts.map { ($0.key, $0.concept) }, uniquingKeysWith: { a, _ in a })
    // 옛 페이지의 단위: 페이지 단위가 어느 원문 단위에서 왔는지 (지우거나 다시 만들기 전에 읽어 둔다)
    var oldPages: [String: [PageUnit]] = [:]
    for key in selected { if let c = byKey[key] { oldPages[key] = Page.load(ConceptFolder(c.cid, in: data))?.units ?? [] } }
    let living = DirectiveStore.load(data).filter(\.status.isLiving)

    let provenance = YAMLValue(json: v["provenance"] ?? .object([:])).map ?? YAMLMap([])
    let written = try ConceptCuration.apply(plan, input: input, data: data, provenance: provenance)

    // 옛 단위 → 그 내용을 담은 새 단위 (처음 담은 것)
    var target: [String: (concept: String, unit: String)] = [:]
    for (p, c) in zip(plan.concepts, written) {
      for (u, cu) in zip(p.units, c.units) { for ref in u.from where target[ref] == nil { target[ref] = (c.id, cu.id) } }
    }
    let slugToID = Dictionary(zip(plan.concepts, written).map { ($0.slug, $1.id) }, uniquingKeysWith: { a, _ in a })
    func conceptID(_ ref: String) -> String? { byKey[ref]?.id ?? (ref.hasPrefix("new:") ? slugToID[String(ref.dropFirst(4))] : nil) }

    // 옛 단위와 그 페이지 단위가 간 자리. 남은 개념에서 뺀 단위는 적지 않는다(페이지를 다시 만들면 그 문단이 빠지고 id 는 다시 쓰지 않는다).
    var moves: [(from: (concept: String, unit: String), to: (concept: String, unit: String?))] = []
    var movedPageUnits: Set<String> = []
    for key in selected.sorted() {
      guard let old = byKey[key] else { continue }
      let retired = plan.retired.first { $0.key == key }
      let into = retired.flatMap { conceptID($0.into) }
      let stays = Set(plan.concepts.first { $0.existing == key }?.units.compactMap(\.id) ?? [])
      var covered: Set<String> = []
      for u in old.units where !stays.contains(u.id) {
        let to: (concept: String, unit: String?)
        if let t = target["\(key).\(u.id)"] {
          to = (t.concept, t.unit)
        } else if let into {
          to = (into, nil)
        } else {
          continue
        }
        moves.append(((old.id, u.id), to))
        for pu in oldPages[key] ?? [] where pu.fromUnit == u.id {
          moves.append(((old.id, pu.id), to))
          covered.insert(pu.id)
          if to.unit != nil { movedPageUnits.insert("\(old.id)#\(pu.id)") }
        }
      }
      // 없앤 개념의 페이지 단위는 하나도 빠짐없이 자리를 남긴다 (개념 줄만 따라가 받는 개념의 엉뚱한 단위에 붙지 않게)
      if let into { for pu in oldPages[key] ?? [] where !covered.contains(pu.id) { moves.append(((old.id, pu.id), (into, nil))) } }
    }

    // 없앤 개념: 폴더를 지우고, 가리키던 선수 개념을 바꾸고, 코멘트가 따라갈 개념을 적는다
    var retiredIDs: [String] = []
    var references = References.load(data)
    for r in plan.retired {
      guard let old = byKey[r.key], let into = conceptID(r.into) else { continue }
      FileOps.remove(ConceptFolder(old.cid, in: data).url)
      try ConceptMove.repoint(data, from: old.id, to: into)
      references.concepts.removeValue(forKey: old.id)
      try Moves.append(data, kind: "concept", from: old.id, to: into, why: "다시 정리로 없앰 (\(job))")
      retiredIDs.append(old.id)
    }
    if !retiredIDs.isEmpty { try references.write(data) }
    for m in moves { try Moves.appendUnit(data, from: m.from, to: m.to, why: "다시 정리 (\(job))") }
    // 옮겨 간 단위에 달린 살아 있는 요구는 원문이 바뀌었으므로 다시 확인한다 (REGENERATION.md)
    for d in living where movedPageUnits.contains("\(d.target.concept)#\(d.target.unit)") {
      try DirectiveStore.update(data, id: d.id, status: .recheck)
    }

    // 기록: 반영한 계획과 결정
    var record = plan.recordJSON(input: input, written: written).objectValue ?? [:]
    record["recuration"] = .bool(true)
    record["retired"] = .array(
      plan.retired.compactMap { r in
        guard let old = byKey[r.key] else { return nil }
        return .object([
          "concept": .string(old.id), "into": .string(conceptID(r.into) ?? r.into), "reason": .string(r.reason),
          "units": .array(r.dropped.map { .object(["id": .string($0.id), "reason": .string($0.reason)]) }),
        ])
      })
    try FileOps.writeNew(JSONText.record(.object(record)), to: dir.appending(path: "plan.json"))
    try FileOps.writeNew(
      JSONText.record(
        .object([
          "v": .number(1), "decision": .string("applied"), "at": .string(Clock.isoLocal()), "concepts": .array(written.map { .string($0.id) }),
          "retired": .array(retiredIDs.map(JSONValue.string)), "unit_moves": .number(Double(moves.count)),
        ])), to: dir.appending(path: "decision.json"))
    return Applied(subject: subject, written: written.map(\.id), retired: retiredIDs, unitMoves: moves.count)
  }

  // 후보를 버린다. 데이터는 그대로다.
  public static func discard(_ data: DataFolder, job: String) throws {
    let dir = folder(data, job: job)
    guard FileOps.exists(dir.appending(path: "proposal.json")) else { throw RequestError("다시 정리 후보를 찾지 못했습니다: \(job)") }
    guard !FileOps.exists(dir.appending(path: "decision.json")) else { throw RequestError("이미 반영했거나 버린 후보입니다: \(job)") }
    try FileOps.writeNew(
      JSONText.record(.object(["v": .number(1), "decision": .string("discarded"), "at": .string(Clock.isoLocal())])), to: dir.appending(path: "decision.json"))
  }
}
