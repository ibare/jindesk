// 자료 나누기 (source-split, JOBS.md, DECISIONS.md 41). 파일 하나에 수업 여러 개가 들어 있으면 수업마다 자료로 쪼개 묶음으로 나눈다.
// 그래서 자료 읽기와 개념 정리가 한 번에 수업 하나만 다룬다. 묶음 하나가 대상이고, 그 묶음에서 아직 나누기를 보지 않은 자료를 본다.
// 에이전트는 쪽마다의 글자층으로 자료가 표시한 수업 경계를 찾는다. 나누면 러너가 수업마다 새 자료(쪼갠 PDF, 글자층, 쪽 이미지)와
// 새 묶음을 만들고 원래 자료를 지운다. 끝나면 남은 묶음과 새 묶음마다 자료 읽기를 넣는다.
import Foundation
import PDFKit

public enum SourceSplit {
  static let prompt =
    "input/request.md 의 자료마다 지침대로 수업 경계를 찾아라. 자료마다 input/sources/<자료 id>/ 에 index.md, 쪽마다의 글자가 든 text.md, 쪽 이미지(pages/)가 있다. "
    + "out/split.json 과 out/report.md 를 쓴다."

  public static func prepare(bundle bundleID: String, _ ctx: PrepareContext) throws -> PreparedJob {
    let library = SourceLibrary.load(ctx.data)
    guard let bundle = BundleStore.bundle(ctx.data, id: bundleID, library: library) else { throw RequestError("묶음을 찾지 못했습니다: \(bundleID)") }
    let first = bundle.sources.first.flatMap(library.source)
    let name = first?.meta.original.name ?? bundleID
    let id = try JobID.make(date: ctx.now, slugSource: "split \((name as NSString).deletingPathExtension)", exists: ctx.taken)
    let title = bundle.title ?? (bundle.sources.count == 1 ? name : "\(name) 외 \(bundle.sources.count - 1)개")
    return PreparedJob(
      id: id, kind: .sourceSplit, title: title, target: bundleID, coalesceKey: "source-split:\(bundleID)", recipe: .sourceSplit(bundle: bundleID)
    ) { c in
      try await run(bundle: bundleID, c)
    }
  }

  // 나누기를 본 자료 (기록의 result.json 에서 읽는다)
  public static func checkedSources(_ data: DataFolder) -> Set<String> {
    let root = data.records.appending(path: JobKind.sourceSplit.rawValue)
    var out: Set<String> = []
    for job in FileOps.list(root) where JobID.isValid(job) {
      guard let content = try? Data(contentsOf: root.appending(path: job).appending(path: "result.json")), let v = try? JSONValue.parse(content) else { continue }
      for s in v["sources"]?.arrayValue ?? [] { if let id = s["source"]?.stringValue { out.insert(id) } }
    }
    return out
  }

  // 그 묶음에서 나누기를 볼 자료: 쪽이 둘 이상이고, 쪼갠 조각도 목차의 근거도 아니며, 나누기를 본 적도 읽은 적도 없는 자료
  public static func pending(_ bundle: SourceBundle, library: SourceLibrary, checked: Set<String>, read: [String: [String]]) -> [SourceSummary] {
    bundle.sources.compactMap(library.source).filter { s in
      s.meta.pages > 1 && s.meta.splitFrom == nil && !s.labels.syllabusBasis && !checked.contains(s.id) && read[s.id] == nil
    }
  }

  static func run(bundle bundleID: String, _ ctx: JobContext) async throws {
    await ctx.setPhase("preparing")
    let library = SourceLibrary.load(ctx.data)
    guard let bundle = BundleStore.bundle(ctx.data, id: bundleID, library: library) else { throw ToolError("묶음을 찾지 못했습니다: \(bundleID)") }
    let targets = pending(bundle, library: library, checked: checkedSources(ctx.data), read: SourceReading.readSources(ctx.data))
    var reading = [bundleID]
    if targets.isEmpty {
      await ctx.log(.info, "나누기를 볼 자료가 없습니다")
    } else {
      reading = try await split(targets, bundle: bundle, ctx)
    }
    // 뒤따름: 묶음마다 자료 읽기
    for b in reading where await ctx.queueFollowUp("자료 읽기", { try SourceReading.prepare(bundle: b, $0) }) != nil {
      await ctx.log(.info, "자료 읽기를 대기열에 넣었습니다: 묶음 \(b)")
    }
  }

  // 에이전트가 수업 경계를 찾고, 러너가 나눈다. 자료 읽기를 넣을 묶음(남은 원래 묶음과 수업마다의 새 묶음)을 돌려준다.
  static func split(_ targets: [SourceSummary], bundle: SourceBundle, _ ctx: JobContext) async throws -> [String] {
    let dirs = AgentDirs(ctx.folders, ctx.id)
    try dirs.make()
    let (instructions, instructionsFile) = try await AgentStep.fixInstructions(.sourceSplit, ctx, into: dirs.run)
    var request = ["# 자료 나누기 요청", "", "- 묶음: \(bundle.id)"]
    if let memo = bundle.memo { request.append("- 메모: \(memo)") }
    request += ["", "## 볼 자료", "", "| 자료 id | 원본 파일 이름 | 쪽 | 꼬리표 |", "|---|---|---|---|"]
    for s in targets {
      request.append("| \(s.id) | \(s.meta.original.name) | \(s.meta.pages) | \(s.labels.labels.summary) |")
      let dir = dirs.input.appending(path: "sources/\(s.id)")
      try FileOps.copy(s.folder.index, to: dir.appending(path: "index.md"))
      var text: [String] = []
      for n in 1...s.meta.pages {
        text += ["## \(n)쪽", "", SourcePages.text(s.folder, page: n), ""]
        try FileOps.copy(try SourcePages.image(s.folder, page: n, folders: ctx.folders), to: dir.appending(path: "pages/\(SourceFolder.pageName(n)).png"))
      }
      try FileOps.write(text.joined(separator: "\n"), to: dir.appending(path: "text.md"))
    }
    try FileOps.write(request.joined(separator: "\n") + "\n", to: dirs.input.appending(path: "request.md"))
    await ctx.log(.info, "볼 자료 \(targets.count)개 (\(targets.map { "\($0.meta.pages)쪽" }.joined(separator: ", ")))")
    try ctx.checkCancellation()

    await ctx.setPhase("running")
    let options = AgentStep.options(ctx, dirs, instructions: instructionsFile, prompt: prompt, events: "split")
    let result = try await AgentStep.run(options, ctx, label: "자료 나누기")
    await ctx.setPhase("checking")
    var plan = check(out: dirs.out, targets: targets)
    if !plan.problems.isEmpty {
      await ctx.log(.warn, "검사에서 \(plan.problems.count)건이 나와 고쳐 쓰게 합니다")
      await ctx.setPhase("fixing")
      try await AgentStep.fix(options, session: result.sessionID, problems: plan.problems, ctx: ctx, label: "자료 나누기", events: "split-fix")
      await ctx.setPhase("checking")
      plan = check(out: dirs.out, targets: targets)
    }
    // 그래도 틀린 자료는 나누지 않는다. 나누지 않아도 뒤의 작업은 돈다.
    for p in plan.problems { await ctx.log(.warn, "\(p) — 나누지 않습니다") }

    await ctx.setPhase("finalizing")
    var reading: [String] = []
    var results: [JSONValue] = []
    var pieces = 0
    for s in targets {
      var item: [String: JSONValue] = ["source": .string(s.id), "name": .string(s.meta.original.name), "pages": .number(Double(s.meta.pages))]
      if let lessons = plan.lessons[s.id] {
        let ids = try apply(s, lessons: lessons, bundle: bundle, data: ctx.data, folders: ctx.folders)
        reading += ids
        pieces += ids.count
        item["lessons"] = .array(
          zip(lessons, ids).map { l, id in .object(["source": .string(id), "pages": .array([.number(Double(l.first)), .number(Double(l.last))]), "title": .string(l.title)]) })
        await ctx.log(.info, "\(s.meta.original.name) 를 수업 \(ids.count)개로 나눴습니다")
      } else {
        item["lessons"] = .array([])
        await ctx.log(.info, "\(s.meta.original.name) 는 나누지 않습니다")
      }
      results.append(.object(item))
    }
    // 원래 묶음에 자료가 남았으면 그 묶음도 읽는다
    if BundleStore.bundle(ctx.data, id: bundle.id) != nil { reading.insert(bundle.id, at: 0) }
    let record = ctx.data.record(JobKind.sourceSplit.rawValue, ctx.id)
    try FileOps.writeNew(
      JSONText.record(.object(["v": .number(1), "bundle": .string(bundle.id), "sources": .array(results)])), to: record.appending(path: "result.json"))
    let report = FileOps.readIfExists(dirs.out.appending(path: "report.md")) ?? ""
    let head: YAMLMap = ["kind": "split-report", "v": 1, "job": .string(ctx.id), "provenance": .map(AgentStep.provenance(ctx, .sourceSplit, instructions))]
    try FileOps.writeNew(FrontMatter.render(head) + "\n" + report.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", to: record.appending(path: "report.md"))
    await ctx.report(
      counts: [
        JobCount(key: "sources", label: "본 자료", count: targets.count), JobCount(key: "split", label: "나눈 자료", count: plan.lessons.count),
        JobCount(key: "lessons", label: "수업", count: pieces),
      ], warnings: plan.problems.isEmpty ? nil : plan.problems)
    return reading
  }

  // MARK: - 검사

  struct Lesson: Sendable, Equatable {
    let first: Int
    let last: Int
    let title: String
  }

  struct Plan {
    // 나눌 자료 → 수업 (둘 이상)
    var lessons: [String: [Lesson]] = [:]
    var problems: [String] = []
  }

  static func check(out: URL, targets: [SourceSummary]) -> Plan {
    var plan = Plan()
    let json: JSONValue
    switch AgentJSON.read(out.appending(path: "split.json"), label: "out/split.json") {
    case .failure(let p):
      plan.problems.append(p.message)
      return plan
    case .success(let v): json = v
    }
    let items = json["sources"]?.arrayValue ?? []
    for s in targets {
      guard let item = items.first(where: { $0["source"]?.stringValue == s.id }) else {
        plan.problems.append("out/split.json: 자료 \(s.id) 의 항목이 없습니다")
        continue
      }
      var lessons: [Lesson] = []
      var problems: [String] = []
      for (i, l) in (item["lessons"]?.arrayValue ?? []).enumerated() {
        let pages = AgentJSON.ints(l["pages"])
        guard pages.count == 2, let title = AgentJSON.string(l["title"]) else {
          problems.append("수업 \(i + 1): pages([첫 쪽, 마지막 쪽])와 title 이 있어야 합니다")
          continue
        }
        problems += TextChecks.englishProblems(title, field: "수업 \(i + 1)의 title")
        lessons.append(Lesson(first: pages[0], last: pages[1], title: title))
      }
      // 수업이 하나뿐이면 나누지 않는다
      if lessons.count > 1 {
        var next = 1
        for l in lessons {
          if l.first != next || l.last < l.first { problems.append("수업 \"\(l.title)\"(\(l.first)–\(l.last)쪽): \(next)쪽부터 차례로 이어져야 합니다") }
          next = l.last + 1
        }
        if next != s.meta.pages + 1 { problems.append("마지막 수업이 \(s.meta.pages)쪽에서 끝나야 합니다") }
        for run in s.meta.buildUps {
          guard let a = run.first, let b = run.last else { continue }
          if lessons.contains(where: { $0.first > a && $0.first <= b }) { problems.append("이어 채운 쪽 \(a)–\(b)쪽을 가릅니다") }
        }
      }
      if !problems.isEmpty {
        plan.problems += problems.map { "자료 \(s.id): \($0)" }
      } else if lessons.count > 1 {
        plan.lessons[s.id] = lessons
      }
    }
    return plan
  }

  // MARK: - 나누기

  // 수업마다 새 자료와 새 묶음을 만들고, 원래 자료를 묶음에서 빼고 지운다. 새 자료 id(= 새 묶음 id)를 수업 차례로 돌려준다.
  // 다시 돌아도(앱이 끝나 다시 넣은 작업) 같은 수업이면 같은 자료 id 라, 이미 만든 조각과 묶음은 그대로 둔다. 원래 자료는 마지막에 지운다.
  static func apply(_ source: SourceSummary, lessons: [Lesson], bundle: SourceBundle, data: DataFolder, folders: AppFolders, now: Date = Date()) throws
    -> [String]
  {
    guard let document = source.folder.renderable, document.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: document) else {
      throw ToolError("\(source.meta.original.name) 를 PDF 로 열지 못해 나누지 못했습니다")
    }
    let received = Clock.parse(source.meta.received) ?? now
    var ids: [String] = []
    for (i, lesson) in lessons.enumerated() {
      let id = SourceID.make(received: received, sha256: Hash.sha256(Data("\(source.meta.original.sha256)#\(lesson.first)-\(lesson.last)".utf8)))
      if !FileOps.exists(SourceFolder(id: id, in: data).url) { try makePiece(id, from: source, pdf: pdf, lesson: lesson, data: data, folders: folders) }
      // 수업마다 묶음 하나 (묶음 id 는 자료 id). 목록이 늦게 만든 것부터라, 첫 수업이 위에 오도록 수업마다 1초씩 앞당긴다.
      try BundleStore.lock.withLock {
        guard !FileOps.exists(BundleStore.file(data, id: id)) else { return }
        try BundleStore.write(
          SourceBundle(id: id, created: Clock.isoLocal(now.addingTimeInterval(-Double(i))), sources: [id], memo: bundle.memo), data: data)
      }
      ids.append(id)
    }
    if !bundle.implicit { _ = try BundleStore.update(data, id: bundle.id) { $0.sources.removeAll { $0 == source.id } } }
    FileOps.remove(source.folder.url)
    FileOps.remove(folders.pageImages(source.id))
    return ids
  }

  // 수업 하나를 자료로 만든다: 쪼갠 PDF(original.pdf), 쪽 번호를 1부터 다시 매긴 글자층과 쪽 이미지, meta.yaml(split_from), 꼬리표, index.md.
  // 자료 넣기처럼 sources/.incoming-<자료 id>/ 에서 다 만든 뒤 한 번에 옮긴다.
  static func makePiece(_ id: String, from source: SourceSummary, pdf: PDFDocument, lesson: Lesson, data: DataFolder, folders: AppFolders) throws {
    let staging = SourceFolder(id: id, url: data.sources.appending(path: ".incoming-\(id)"))
    let piece = SourceFolder(id: id, in: data)
    FileOps.remove(staging.url)
    try FileOps.makeDirectory(staging.url)
    do {
      let range = Array(lesson.first...lesson.last)
      let cut = PDFDocument()
      for (i, n) in range.enumerated() {
        guard let page = pdf.page(at: n - 1)?.copy() as? PDFPage else { throw ToolError("\(source.meta.original.name) 의 \(n)쪽을 옮기지 못했습니다") }
        cut.insert(page, at: i)
      }
      let original = staging.url.appending(path: "original.pdf")
      guard cut.write(to: original) else { throw ToolError("\(lesson.title) 의 PDF 를 쓰지 못했습니다") }

      let ocr = Set(source.meta.textLayer.ocrPages)
      var texts: [PageText] = []
      for (i, n) in range.enumerated() {
        let text = SourcePages.text(source.folder, page: n)
        try FileOps.write(text.isEmpty ? "" : text + "\n", to: staging.pageText(i + 1))
        texts.append(PageText(page: i + 1, text: text, by: ocr.contains(n) ? "vision" : text.isEmpty ? "none" : "pdfkit"))
        // 쪽 이미지는 원래 자료의 것을 옮겨 쓴다. 없으면 볼 때 그린다.
        let images = [
          (folders.pageImages(source.id).appending(path: SourceFolder.pageName(n) + ".png"), folders.pageImages(id).appending(path: SourceFolder.pageName(i + 1) + ".png")),
          (SourcePages.viewImage(source.folder, page: n, folders: folders), SourcePages.viewImage(piece, page: i + 1, folders: folders)),
        ]
        for (from, to) in images where FileOps.exists(from) && !FileOps.exists(to) { try FileOps.copy(from, to: to) }
      }

      let bytes = ((try? FileManager.default.attributesOfItem(atPath: original.path))?[.size] as? Int) ?? 0
      let buildUps = source.meta.buildUps.filter { $0.allSatisfy(range.contains) }.map { $0.map { $0 - lesson.first + 1 } }
      let stem = (source.meta.original.name as NSString).deletingPathExtension
      let meta = SourceMeta(
        id: id, original: .init(name: "\(stem) · \(lesson.title).pdf", bytes: bytes, sha256: String(try Hash.file(original).prefix(16))),
        received: source.meta.received, converted: nil, pages: range.count,
        textLayer: .init(
          by: source.meta.textLayer.by, pagesWithText: texts.filter { !$0.text.isEmpty }.count,
          ocrPages: range.enumerated().filter { ocr.contains($0.element) }.map { $0.offset + 1 }),
        buildUps: buildUps,
        splitFrom: .init(name: source.meta.original.name, sha256: source.meta.original.sha256, pages: [lesson.first, lesson.last], title: lesson.title))
      try meta.write(to: staging)
      try SourceLabelsFile(source: id, labels: source.labels.labels, memo: source.labels.memo, syllabusBasis: false).write(to: staging)
      try FileOps.writeAtomic(SourceIndex.markdown(meta, ExtractedPages(texts: texts, buildUps: buildUps)), to: staging.index)
      try FileManager.default.moveItem(at: staging.url, to: piece.url)
    } catch {
      FileOps.remove(staging.url)
      throw error
    }
  }
}
