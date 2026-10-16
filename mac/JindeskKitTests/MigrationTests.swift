import Foundation
import Testing
@testable import JindeskKit

// 시험용 단계 1 → 2: library/glossary.yaml 의 terms 이름을 entries 로 바꾼다 (모양 변경)
struct RenameTermsStep: MigrationStep {
  let from = 1
  let kind = MigrationKind.code
  let summary = "용어 어휘의 terms 를 entries 로"

  func run(_ copy: DataFolder, _ context: MigrationContext) async throws {
    let file = copy.library.appending(path: "glossary.yaml")
    guard FileOps.exists(file), var map = try YAML.read(file).map else { return }
    let terms = map["terms"]
    map["terms"] = nil
    map["entries"] = terms
    try FileOps.writeAtomic(YAML.stringify(map), to: file)
  }
}

// 학생이 쓴 글을 건드리는 잘못된 단계
struct BrokenStep: MigrationStep {
  let from = 1
  let kind = MigrationKind.code
  let summary = "코멘트를 고쳐 쓴다 (하면 안 된다)"

  func run(_ copy: DataFolder, _ context: MigrationContext) async throws {
    try FileOps.writeAtomic("{\"v\":1,\"id\":\"cm-1\",\"text\":\"바뀜\"}\n", to: copy.learner.appending(path: "comments.jsonl"))
  }
}

@Suite struct MigrationTests {
  // 스키마 1 인 데이터 폴더: 용어 어휘, 학생 코멘트, 실행 요약, 원본 자료
  func sample() throws -> TempPlace {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    try t.write("library/glossary.yaml", "kind: \"glossary\"\nv: 1\nterms:\n  - { en: \"secant\", ko: \"할선\" }\n")
    try t.write("learner/comments.jsonl", "{\"v\":1,\"id\":\"cm-1\",\"text\":\"중력이 계속 당기는데 왜?\"}\n")
    try t.write("records/runs/2026-10.jsonl", "{\"v\":1,\"id\":\"20261016-1000-a\"}\n")
    try t.write("sources/physics-hl/20260903-3fa2c1d0/original.pdf", "PDF 바이트")
    return t
  }

  func migrator(_ t: TempPlace, _ steps: [any MigrationStep]) -> Migrator {
    Migrator(data: t.data, folders: t.folders, app: AppVersion(app: "0.2.0", build: "2"), steps: steps, target: 2)
  }

  @Test func 데이터_폴더의_상태를_본다() throws {
    let t = try sample()
    #expect(migrator(t, []).state() == .older(1))
    #expect(Migrator(data: t.data, folders: t.folders, app: testApp).state() == .current)
    #expect(Migrator(data: t.data, folders: t.folders, app: testApp, target: 0).state() == .newer(1))
    #expect(Migrator(data: DataFolder(t.root.appending(path: "없음")), folders: t.folders, app: testApp).state() == .uninitialized)
  }

  @Test func 사본에서_마이그레이션하고_검증한_뒤_바꿔_끼운다() async throws {
    let t = try sample()
    let m = migrator(t, [RenameTermsStep()])
    let report = try await m.migrate()
    #expect(report.from == 1 && report.to == 2 && report.checks == ["검증 통과"])
    // 새 모양
    #expect(try t.read("library/glossary.yaml") == "kind: \"glossary\"\nv: 1\nentries:\n  - { en: \"secant\", ko: \"할선\" }\n")
    let schema = try SchemaFile.read(t.data)
    #expect(schema.schema == 2)
    #expect(schema.history == [.init(from: 1, to: 2, app: "0.2.0", at: schema.history[0].at, kind: "code", backup: "Jindesk-마이그레이션-1-2.zip")])
    #expect(FileOps.exists(t.data.records.appending(path: "migration/1-2/plan.json")))
    #expect(FileOps.exists(t.data.records.appending(path: "migration/1-2/checks.json")))
    // 학생 글은 바이트 그대로다
    #expect(try t.read("learner/comments.jsonl") == "{\"v\":1,\"id\":\"cm-1\",\"text\":\"중력이 계속 당기는데 왜?\"}\n")
    // 자동 백업과 바꿔 끼우기 전 폴더가 남는다
    #expect(FileOps.exists(t.folders.backups.appending(path: "Jindesk-마이그레이션-1-2.zip")))
    let before = t.root.appending(path: ".Jindesk-before-2")
    #expect(try String(contentsOf: before.appending(path: "library/glossary.yaml"), encoding: .utf8).contains("terms:"))
    #expect(!FileOps.exists(t.root.appending(path: ".Jindesk-migrating-2")))
    // 다음에 켤 때 문제가 없으면 바꿔 끼우기 전 폴더를 지운다
    #expect(m.removePreviousCopies() == ["마이그레이션 전 폴더(.Jindesk-before-2)를 지웠습니다"])
    #expect(!FileOps.exists(before))
  }

  @Test func 검증에_실패하면_사본을_버리고_원래_폴더를_그대로_둔다() async throws {
    let t = try sample()
    let original = try t.read("learner/comments.jsonl")
    await #expect(throws: MigrationFailure.self) { _ = try await migrator(t, [BrokenStep()]).migrate() }
    #expect(try t.read("learner/comments.jsonl") == original)
    #expect(try SchemaFile.read(t.data).schema == 1)
    #expect(!FileOps.exists(t.root.appending(path: ".Jindesk-migrating-2")))
    #expect(!FileOps.exists(t.root.appending(path: ".Jindesk-before-2")))
  }

  @Test func 단계가_빠졌거나_작업_중이면_마이그레이션하지_않는다() async throws {
    let t = try sample()
    await #expect(throws: ToolError.self) { _ = try await migrator(t, []).migrate() }
    let lock = DataLock(t.data)
    #expect(lock.tryAcquire())
    await #expect(throws: ToolError.self) { _ = try await migrator(t, [RenameTermsStep()]).migrate() }
    lock.release()
  }

  @Test func 중간에_꺼졌으면_원래_폴더를_되돌리고_사본을_버린다() throws {
    let t = try sample()
    let m = migrator(t, [RenameTermsStep()])
    // 바꿔 끼우는 도중에 꺼진 모양: 데이터 폴더가 .Jindesk-before-2 로 옮겨졌고, 사본이 남았다
    try FileManager.default.copyItem(at: t.data.url, to: t.root.appending(path: ".Jindesk-migrating-2"))
    try FileManager.default.moveItem(at: t.data.url, to: t.root.appending(path: ".Jindesk-before-2"))
    let notes = try m.recoverInterrupted()
    #expect(notes.count == 2)
    #expect(try SchemaFile.read(t.data).schema == 1)
    #expect(FileOps.list(t.root).filter { $0.hasPrefix(".Jindesk") }.isEmpty)
  }

  @Test func 사본에서만_시험하고_바뀐_파일을_알린다() async throws {
    let t = try sample()
    let report = try await MigrationCheck.run(
      source: t.data.url, folders: t.folders, app: testApp, steps: [RenameTermsStep()], target: 2)
    #expect(report.from == 1 && report.issues.isEmpty)
    #expect(report.changed == ["library/glossary.yaml", "meta/schema.yaml"])
    #expect(report.added.isEmpty && report.removed.isEmpty)
    // 원래 폴더는 그대로다
    #expect(try SchemaFile.read(t.data).schema == 1)
    #expect(try t.read("library/glossary.yaml").contains("terms:"))
  }

  @Test func 백업_zip_으로도_시험한다() async throws {
    let t = try sample()
    let zip = try await Backup.make(t.data, into: t.root.appending(path: "backups"))
    let report = try await MigrationCheck.run(source: zip, folders: t.folders, app: testApp, steps: [BrokenStep()], target: 2)
    #expect(report.issues.contains { $0.contains("learner/comments.jsonl") })
  }

  @Test func 지금_스키마면_할_것이_없다고_알린다() async throws {
    let t = try sample()
    let report = try await MigrationCheck.run(source: t.data.url, folders: t.folders, app: testApp)
    #expect(report.from == nil && report.issues.isEmpty && !report.notes.isEmpty)
  }
}

@Suite struct BackupTests {
  @Test func 데이터_폴더를_zip_으로_만들고_풀면_같은_폴더가_나온다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    try t.write("learner/comments.jsonl", "{\"v\":1}\n")
    let zip = try await Backup.make(t.data, into: t.root.appending(path: "out"), now: Date(timeIntervalSince1970: 1_790_000_000))
    #expect(zip.lastPathComponent.hasPrefix("Jindesk-백업-") && zip.pathExtension == "zip")
    // 같은 분에 또 만들면 번호를 붙인다
    let second = try await Backup.make(t.data, into: t.root.appending(path: "out"), now: Date(timeIntervalSince1970: 1_790_000_000))
    #expect(second.lastPathComponent.hasSuffix("-2.zip"))
    let restored = try await Backup.unzip(zip, into: t.root.appending(path: "restored"))
    #expect(restored.lastPathComponent == "Jindesk")
    #expect(try String(contentsOf: restored.appending(path: "learner/comments.jsonl"), encoding: .utf8) == "{\"v\":1}\n")
    #expect(Migrator.state(of: DataFolder(restored)) == .current)
  }

  @Test func 작업_중이면_잠금이_풀릴_때까지_기다린다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let lock = DataLock(t.data)
    #expect(lock.tryAcquire())
    let waited = Flag()
    let task = Task { try await Backup.make(t.data, into: t.root.appending(path: "out")) { await waited.set() } }
    try await Task.sleep(for: .milliseconds(700))
    #expect(await waited.value)
    #expect(FileOps.list(t.root.appending(path: "out")).isEmpty)
    lock.release()
    let zip = try await task.value
    #expect(FileOps.exists(zip))
  }

  @Test func 최근_몇_개만_남긴다() throws {
    let t = TempPlace()
    for i in 1...5 {
      let url = t.folders.backups.appending(path: "Jindesk-마이그레이션-\(i)-\(i + 1).zip")
      try FileOps.write("z", to: url)
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i) * 1000)], ofItemAtPath: url.path)
    }
    Backup.prune(t.folders.backups, prefix: "Jindesk-마이그레이션-", keep: 3)
    #expect(FileOps.list(t.folders.backups).sorted() == ["Jindesk-마이그레이션-3-4.zip", "Jindesk-마이그레이션-4-5.zip", "Jindesk-마이그레이션-5-6.zip"])
  }
}

actor Flag {
  var value = false
  func set() { value = true }
}
