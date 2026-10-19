import Foundation
import Testing
@testable import JindeskKit

// 자료 묶음 (DECISIONS.md 35): 묶음 저장, 묶음으로 넣기, 묶음 단위의 남은 일, 보류된 엔트리 다시 받기
@MainActor
@Suite struct BundleTests {
  func place() throws -> TempPlace {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    return t
  }

  // 토큰 없이 넣는다 (뒤따르는 자료 읽기를 넣지 않는다)
  func intake(_ t: TempPlace, _ request: IntakeRequest) async throws -> JobSnapshot {
    var config = testConfig
    config.claudeToken = ""
    let m = JobManager(data: t.data, folders: t.folders)
    let id = try await m.submit(config: config) { try SourceIntake.prepare(request, $0) }
    return await m.waitForEnd(id)
  }

  func pdf(_ t: TempPlace, _ name: String, _ text: String) -> URL {
    let url = t.root.appending(path: "inbox/\(name).pdf")
    SampleFiles.pdf(url, [.text(text + " with enough words to keep the text layer long enough for the test")])
    return url
  }

  let labels = SourceLabels(grade: "MYP 5", subject: "Extended Math", level: "Extended")

  @Test func 넣다가_앱이_끝나면_다음에_켤_때_같은_묶음과_메모로_이어_넣는다() async throws {
    let t = try place()
    let a = pdf(t, "a", "Vectors lesson slides")
    let b = pdf(t, "b", "Vectors worksheet")
    let c = pdf(t, "c", "Forces lesson slides")
    // 넣기를 준비하면 새 묶음의 id 가 정해진다
    let ctx = PrepareContext(now: Date(), data: t.data, folders: t.folders, config: testConfig) { _ in false }
    let job = try SourceIntake.prepare(IntakeRequest(labels: labels, groups: [IntakeGroup(files: [a, b], memo: "벡터"), IntakeGroup(files: [c], memo: "힘")]), ctx)
    guard case .sourceIntake(let fixed) = try #require(job.recipe) else { throw ToolError("자료 넣기가 아닙니다") }
    let (x, y) = (try #require(fixed.groups[0].newBundle), try #require(fixed.groups[1].newBundle))
    #expect(fixed.requested != nil && x != y)

    // 꺼지기 전: a 와 c 를 넣었다. c 는 묶음에 적기 전에 꺼졌다.
    var partial = fixed
    partial.groups[0].files = [a]
    _ = try await intake(t, partial)
    FileOps.remove(BundleStore.file(t.data, id: y))
    #expect(BundleStore.all(t.data).filter(\.implicit).count == 1)
    var crashed = JobSnapshot(
      id: "20261019-1200-intake-a", type: "source-intake", typeLabel: "자료 넣기", title: "a.pdf 외 2개", phase: "running", phaseLabel: "넣기",
      queuedAt: Clock.isoLocal(), dataFolder: t.data.url.path, recipe: job.recipe)
    crashed.startedAt = Clock.isoLocal()
    JobManager.write(RunRecord(snapshot: crashed, logs: []), folders: t.folders)

    // 다음에 켤 때: 같은 요청으로 다시 넣는다
    var runner = testConfig
    runner.claudeToken = ""
    let m = JobManager(data: t.data, folders: t.folders)
    let restored = await m.restore(JobManager.leftovers(data: t.data, folders: t.folders), agent: nil, runner: runner)
    #expect(restored.count == 1 && restored.problems.isEmpty)
    await m.waitUntilIdle()
    let end = try #require(m.recent.first)
    #expect(end.phase == "done" && end.counts?.map(\.count) == [3, 0] && end.warnings == nil, "\(end.warnings ?? [])")
    let library = SourceLibrary.load(t.data)
    let bundles = BundleStore.all(t.data, library: library)
    let names = { (id: String) in bundles.first { $0.id == id }?.sources.compactMap { library.source($0)?.meta.original.name } }
    #expect(bundles.count == 2 && bundles.allSatisfy { !$0.implicit })
    #expect(names(x) == ["a.pdf", "b.pdf"] && names(y) == ["c.pdf"])
    // 메모는 한 번만 적힌다
    #expect(bundles.first { $0.id == x }?.memo == "벡터" && bundles.first { $0.id == y }?.memo == "힘")
    #expect(RunHistory.load(t.folders, id: crashed.id)?.snapshot.phase == "interrupted")
  }

  @Test func 묶음으로_넣고_있는_묶음에_더한다() async throws {
    let t = try place()
    let slides = pdf(t, "1._Measures_slides", "Measures of central tendency slides")
    let sheet = pdf(t, "1._Measures_worksheet", "Measures worksheet questions and solutions")
    let other = pdf(t, "2._SD", "Standard deviation slides")
    let end = try await intake(
      t, IntakeRequest(labels: labels, groups: [IntakeGroup(files: [slides, sheet], memo: "Part 4 는 복습"), IntakeGroup(files: [other])]))
    #expect(end.phase == "done", "\(end.error ?? "")")
    let library = SourceLibrary.load(t.data)
    var bundles = BundleStore.all(t.data, library: library)
    #expect(bundles.count == 2 && bundles.allSatisfy { !$0.implicit })
    let names = { (b: SourceBundle) in b.sources.compactMap { library.source($0)?.meta.original.name } }
    let pair = try #require(bundles.first { $0.sources.count == 2 })
    #expect(names(pair) == ["1._Measures_slides.pdf", "1._Measures_worksheet.pdf"])
    #expect(pair.memo == "Part 4 는 복습")

    // 한 주 뒤에 받은 워크시트를 있는 묶음에 더한다
    let late = pdf(t, "2._SD_worksheet", "Standard deviation worksheet")
    let lone = try #require(bundles.first { $0.sources.count == 1 })
    _ = try await intake(t, IntakeRequest(labels: labels, groups: [IntakeGroup(files: [late], memo: "늦게 받음", bundle: lone.id)]))
    bundles = BundleStore.all(t.data)
    let grown = try #require(bundles.first { $0.id == lone.id })
    #expect(grown.sources.count == 2 && grown.memo == "늦게 받음")
    #expect(bundles.count == 2)

    // 남은 일: 묶음마다 자료 읽기 하나
    let pending = Pipeline.pending(t.data, instructions: repoInstructions)
    #expect(pending.filter { $0.kind == .sourceReading }.map(\.target).sorted() == bundles.map(\.id).sorted())
  }

  @Test func 묶음_파일이_없는_자료는_혼자인_묶음이고_옮기면_묶음_파일이_생긴다() async throws {
    let t = try place()
    let a = pdf(t, "a", "Alpha source")
    let b = pdf(t, "b", "Beta source")
    _ = try await intake(t, IntakeRequest(labels: labels, groups: [IntakeGroup(files: [a, b])]))
    let library = SourceLibrary.load(t.data)
    let ids = library.sources.map(\.id).sorted()
    // 묶음 파일을 지우면 자료마다 혼자인 묶음으로 본다
    for f in FileOps.list(t.data.bundles) { FileOps.remove(t.data.bundles.appending(path: f)) }
    var bundles = BundleStore.all(t.data)
    #expect(bundles.map(\.id).sorted() == ids && bundles.allSatisfy(\.implicit))
    // 한 자료를 다른 자료의 묶음으로 옮기면 그 묶음 파일이 생기고, 옮긴 자료의 혼자인 묶음은 없어진다
    try BundleStore.move(t.data, source: ids[0], to: ids[1])
    bundles = BundleStore.all(t.data)
    #expect(bundles.count == 1 && bundles[0].id == ids[1] && Set(bundles[0].sources) == Set(ids) && !bundles[0].implicit)
    // 새 묶음으로 빼고, 다시 합친다
    let fresh = try BundleStore.move(t.data, source: ids[0], to: nil)
    #expect(BundleStore.all(t.data).count == 2)
    try BundleStore.setMemo(t.data, id: fresh, memo: "빼 둔 것")
    try BundleStore.merge(t.data, from: fresh, into: ids[1])
    bundles = BundleStore.all(t.data)
    #expect(bundles.count == 1 && bundles[0].memo == "빼 둔 것")
    #expect(!FileOps.exists(BundleStore.file(t.data, id: fresh)))
  }

  @Test func 읽기가_끝난_묶음만_정리가_남은_일이_된다() async throws {
    let t = try place()
    let a = pdf(t, "a", "Alpha source")
    let b = pdf(t, "b", "Beta source")
    _ = try await intake(t, IntakeRequest(labels: labels, groups: [IntakeGroup(files: [a]), IntakeGroup(files: [b])]))
    let library = SourceLibrary.load(t.data)
    let bundles = BundleStore.all(t.data, library: library)
    let done = try #require(bundles.first)
    let source = done.sources[0]
    // 묶음 하나를 읽은 기록과 엔트리
    try t.write(
      "records/source-reading/20261019-1000-read-a/request.md",
      "---\nkind: \"reading-request\"\nv: 1\nbundle: \"\(done.id)\"\nsources: [\"\(source)\"]\nsubject: \"extended-math\"\njob: \"20261019-1000-read-a\"\n---\n")
    let entry = Entry(
      id: "extended-math/unplaced/alpha", subject: "extended-math", item: nil, itemProposed: "Stats", title: "Alpha", sources: [EntrySource(source: source, pages: [1])],
      claims: [EntryClaim(text: "x", src: ["\(source)#p1"])], symbols: [], examples: [], misconceptions: [], body: "b", recorded: "", provenance: YAMLMap([]))
    try FileOps.writeNew(entry.markdown, to: t.data.entryFile(entry.id))
    let pending = Pipeline.pending(t.data, instructions: repoInstructions)
    #expect(pending.contains { $0.kind == .conceptCuration && $0.target == done.id })
    #expect(pending.contains { $0.kind == .sourceReading && $0.target != done.id })
    #expect(ConceptCuration.pending(t.data, bundle: done).map(\.id) == [entry.id])
    // 페이지는 과목의 읽기가 모두 끝날 때까지 넣지 않는다
    #expect(!pending.contains { $0.kind == .pageBuild })
  }

  @Test func 보류된_엔트리는_다음_정리에_다시_넘어가고_붙이면_출현_목록에_든다() throws {
    func entry(_ id: String, _ ref: String) -> Entry {
      Entry(
        id: id, subject: "math", item: nil, itemProposed: "Probability", title: "T", sources: [EntrySource(source: String(ref.prefix(17)), pages: [1])],
        claims: [EntryClaim(text: "c", src: [ref])], symbols: [], examples: [], misconceptions: [], body: "b", recorded: "", provenance: YAMLMap([]))
    }
    let input = ConceptCuration.Input(
      subject: "math", bundle: "20261019-aaaabbbb", entries: [("e01", entry("math/unplaced/tree", "20261019-aaaabbbb#p2"))], concepts: [], conceptHashes: [:],
      held: [("h01", entry("math/unplaced/old-tree", "20261012-ccccdddd#p5"), "근거가 문제 하나뿐이다"), ("h02", entry("math/unplaced/venn", "20261012-ccccdddd#p6"), "x")])
    let out = TempPlace().root.appending(path: "out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    func plan(_ value: Any) throws -> ConceptCuration.Checked {
      try JSONSerialization.data(withJSONObject: value).write(to: out.appending(path: "plan.json"))
      return ConceptCuration.check(out: out, input: input, math: nil)
    }
    let unit: [String: Any] = ["id": NSNull(), "text": "Tree diagrams multiply along branches.", "claims": [["text": "c", "src": ["20261019-aaaabbbb#p2", "20261012-ccccdddd#p5"]]]]
    // 보류된 엔트리를 붙이면 그 출처를 쓸 수 있고, 붙이지 않은 h02 는 그대로 보류로 남는다
    let good = try plan(["concepts": [["concept": NSNull(), "slug": "tree-diagrams", "title": "Tree diagrams", "entries": ["e01", "h01"], "units": [unit]]], "held": []])
    #expect(good.problems.isEmpty, "\(good.problems)")
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let written = try ConceptCuration.apply(try #require(good.plan), input: input, data: t.data, provenance: ["job": "j"])
    #expect(Set(written[0].occurrences.map(\.entry)) == ["math/unplaced/tree", "math/unplaced/old-tree"])
    // 보류 엔트리도 여러 개념이 나눠 쓸 수 있지만, 붙이지 않은 보류 엔트리(h02)의 출처는 쓸 수 없다
    let twice = try plan([
      "concepts": [
        ["concept": NSNull(), "slug": "a", "title": "A", "entries": ["e01", "h01"], "units": [unit]],
        ["concept": NSNull(), "slug": "b", "title": "B", "entries": ["h01"], "units": [["id": NSNull(), "text": "x", "claims": [["text": "c", "src": ["20261012-ccccdddd#p6"]]]]]],
      ], "held": [],
    ])
    #expect(!twice.problems.contains { $0.contains("h01") })
    #expect(twice.problems.contains { $0.contains("#p6") })
  }
}
