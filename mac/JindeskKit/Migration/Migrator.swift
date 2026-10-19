// 마이그레이션 실행기 (MIGRATION.md). 늘 사본에서 하고, 검증한 뒤 바꿔 끼운다.
// 차례: 잠금 → 자동 백업 → 사본(APFS 복제) → 단계마다 사본에서 실행 → 검증 → 바꿔 끼우기 → 이력과 기록.
// 원래 데이터 폴더는 바꿔 끼우기 전까지 건드리지 않으므로, 중간에 꺼져도 언제나 그대로다.
import Foundation

public enum MigrationKind: String, Sendable {
  case code
  case codeAgent = "code+agent"
}

// 스키마 N → N+1 한 단계. 한 단계 안의 차례는 코드 → 에이전트 → 코드(뒷정리)이고, 그 차례는 run 이 지킨다.
// 학생이 쓴 글(코멘트, 메모, 요구의 메모, 확인 문제의 답)은 코드로만 다루고 바이트 그대로 옮긴다.
public protocol MigrationStep: Sendable {
  var from: Int { get }
  var kind: MigrationKind { get }
  var summary: String { get }
  // 수가 달라져도 된다고 선언한 영역 (MigrationSnapshot.areas 의 이름)
  var changesCounts: Set<String> { get }
  // 제자리에서 고치는 대신 archive/<from>/ 으로 옮기는 기록 경로 (데이터 폴더 기준 상대 경로의 앞부분)
  var archives: [String] { get }
  func run(_ copy: DataFolder, _ context: MigrationContext) async throws
  // 단계마다의 검증 (주장 장부, 뜻 해시, id). 문제를 돌려준다.
  func verify(before: MigrationSnapshot, after copy: DataFolder) -> [String]
}

extension MigrationStep {
  public var to: Int { from + 1 }
  public var changesCounts: Set<String> { [] }
  public var archives: [String] { [] }
  public func verify(before: MigrationSnapshot, after copy: DataFolder) -> [String] { [] }
}

public struct MigrationContext: Sendable {
  public let app: AppVersion
  public let folders: AppFolders
  // 에이전트 단계에서 표본 몇 개만 돌린다 (migrate --check --sample <n>)
  public let sample: Int?
  public let log: @Sendable (String) async -> Void

  public init(app: AppVersion, folders: AppFolders, sample: Int? = nil, log: @escaping @Sendable (String) async -> Void) {
    self.app = app
    self.folders = folders
    self.sample = sample
    self.log = log
  }
}

// 앱이 담은 단계들. 스키마를 올릴 때 Step_<n>_<n+1> 을 여기 더한다. 출시 전에는 판을 올리지 않으므로 없다 (DECISIONS.md 36)
public enum MigrationPlan {
  public static let steps: [any MigrationStep] = []

  // from 에서 to 까지 이어지는 단계들. 빠진 단계가 있으면 오류다.
  public static func chain(from: Int, to: Int, steps: [any MigrationStep]) throws -> [any MigrationStep] {
    var out: [any MigrationStep] = []
    for n in from..<to {
      guard let step = steps.first(where: { $0.from == n }) else { throw ToolError("스키마 \(n) → \(n + 1) 마이그레이션 단계가 앱에 없습니다") }
      out.append(step)
    }
    return out
  }
}

// 데이터 폴더의 상태 (앱이 켤 때 본다)
public enum DataState: Sendable, Equatable {
  // meta/schema.yaml 이 없다 (새 폴더)
  case uninitialized
  case current
  // 앱보다 낮은 버전: 마이그레이션한다
  case older(Int)
  // 앱보다 높은 버전: 열지 않고 업데이트를 안내한다
  case newer(Int)
  case unreadable(String)
}

public struct MigrationFailure: LocalizedError, Sendable {
  public let issues: [String]

  public init(issues: [String]) {
    self.issues = issues
  }

  public var errorDescription: String? {
    "데이터를 새 모양으로 바꾸지 못했습니다. 원래 데이터 폴더는 그대로입니다.\n" + issues.prefix(20).map { "· \($0)" }.joined(separator: "\n")
  }
}

public struct MigrationReport: Sendable {
  public let from: Int
  public let to: Int
  public let backup: URL
  public let checks: [String]
}

public struct Migrator: Sendable {
  public let data: DataFolder
  public let folders: AppFolders
  public let app: AppVersion
  public let steps: [any MigrationStep]
  public let target: Int
  // 앱 번들의 schemas/ (있으면 사본의 모든 데이터 파일을 목표 판의 스키마로 본다)
  public var schemas: URL?

  public init(
    data: DataFolder, folders: AppFolders, app: AppVersion, steps: [any MigrationStep] = MigrationPlan.steps, target: Int = CurrentSchema.version,
    schemas: URL? = nil
  ) {
    self.data = data
    self.folders = folders
    self.app = app
    self.steps = steps
    self.target = target
    self.schemas = schemas
  }

  static func schemaSet(_ schemas: URL?, target: Int) -> SchemaSet? {
    guard let schemas else { return nil }
    let dir = schemas.appending(path: String(target))
    return FileOps.exists(dir) ? SchemaSet(dir) : nil
  }

  var parent: URL { data.url.deletingLastPathComponent() }
  func copyURL(_ to: Int) -> URL { parent.appending(path: ".Jindesk-migrating-\(to)") }
  func beforeURL(_ to: Int) -> URL { parent.appending(path: ".Jindesk-before-\(to)") }
  static let backupPrefix = "Jindesk-마이그레이션-"

  public func state() -> DataState {
    Self.state(of: data, target: target)
  }

  public static func state(of data: DataFolder, target: Int = CurrentSchema.version) -> DataState {
    guard data.isInitialized else { return .uninitialized }
    do {
      let file = try SchemaFile.read(data)
      if file.schema == target { return .current }
      return file.schema < target ? .older(file.schema) : .newer(file.schema)
    } catch {
      return .unreadable(error.localizedDescription)
    }
  }

  // 켤 때 가장 먼저 부른다. 마치지 못한 마이그레이션을 정리하고, 한 일을 돌려준다.
  // - 바꿔 끼우는 도중에 꺼져 데이터 폴더가 없으면 .Jindesk-before-<N> 을 되돌린다
  // - 남은 사본(.Jindesk-migrating-<N>)은 버린다. 마이그레이션은 처음부터 다시 한다
  public func recoverInterrupted() throws -> [String] {
    var notes: [String] = []
    let names = FileOps.list(parent)
    if !FileOps.exists(data.url), let before = names.filter({ $0.hasPrefix(".Jindesk-before-") }).sorted().last {
      try FileManager.default.moveItem(at: parent.appending(path: before), to: data.url)
      notes.append("마이그레이션 도중 꺼져 원래 데이터 폴더를 되돌렸습니다")
    }
    for name in names where name.hasPrefix(".Jindesk-migrating-") {
      try FileManager.default.removeItem(at: parent.appending(path: name))
      notes.append("마치지 못한 마이그레이션 사본(\(name))을 지웠습니다. 처음부터 다시 합니다")
    }
    return notes
  }

  // 지난번 마이그레이션 뒤 무사히 켜졌으면 바꿔 끼우기 전 폴더(.Jindesk-before-<N>)를 지운다. 백업 zip 은 남는다.
  public func removePreviousCopies() -> [String] {
    guard state() == .current else { return [] }
    var notes: [String] = []
    for name in FileOps.list(parent) where name.hasPrefix(".Jindesk-before-") {
      FileOps.remove(parent.appending(path: name))
      notes.append("마이그레이션 전 폴더(\(name))를 지웠습니다")
    }
    return notes
  }

  // 마이그레이션한다. 작업이 돌지 않을 때만 부른다 (잠금을 잡지 못하면 오류).
  public func migrate(log: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> MigrationReport {
    guard case .older(let from) = state() else { throw ToolError("마이그레이션할 데이터가 아닙니다") }
    let plan = try MigrationPlan.chain(from: from, to: target, steps: steps)
    let lock = DataLock(data)
    guard lock.tryAcquire() else { throw ToolError("다른 Jindesk 프로세스가 이 데이터 폴더에서 작업 중입니다") }
    defer { lock.release() }

    // 1. 자동 백업 (최근 세 개를 둔다)
    let backupName = "\(Self.backupPrefix)\(from)-\(target).zip"
    let backup = folders.backups.appending(path: backupName)
    await log("자동 백업: \(backup.path)")
    try await Backup.zip(data.url, to: backup)
    Backup.prune(folders.backups, prefix: Self.backupPrefix, keep: 3)

    // 2. 사본 (APFS 복제라 공간을 거의 쓰지 않는다)
    let copyURL = copyURL(target)
    FileOps.remove(copyURL)
    try FileManager.default.copyItem(at: data.url, to: copyURL)
    let marker = copyURL.appending(path: "MIGRATING")
    try FileOps.writeAtomic(JSONText.record(.object(["from": .number(Double(from)), "to": .number(Double(target)), "at": .string(Clock.isoLocal())])), to: marker)
    let copy = DataFolder(copyURL)

    do {
      // 3. 단계마다 사본에서 실행
      let before = try MigrationSnapshot.take(copy)
      let context = MigrationContext(app: app, folders: folders, log: log)
      var schema = try SchemaFile.read(copy)
      for step in plan {
        await log("스키마 \(step.from) → \(step.to): \(step.summary)")
        try await step.run(copy, context)
        schema = try SchemaFile.read(copy)
        schema.schema = step.to
        schema.history.append(.init(from: step.from, to: step.to, app: app.app, at: Clock.isoLocal(), kind: step.kind.rawValue, backup: backupName))
        try schema.write(to: copy)
      }

      // 4. 검증
      FileOps.remove(marker)
      let issues = MigrationVerifier.verify(before: before, copy: copy, steps: plan, target: target, schemas: Self.schemaSet(schemas, target: target))
      let checks = issues.isEmpty ? ["검증 통과"] : issues
      try writeRecord(copy, from: from, plan: plan, checks: checks)
      guard issues.isEmpty else { throw MigrationFailure(issues: issues) }

      // 5. 바꿔 끼우기 (같은 볼륨 안의 이름 바꾸기)
      let beforeURL = beforeURL(target)
      FileOps.remove(beforeURL)
      try FileManager.default.moveItem(at: data.url, to: beforeURL)
      try FileManager.default.moveItem(at: copyURL, to: data.url)
      await log("데이터 폴더를 새 모양으로 바꿨습니다 (스키마 \(from) → \(target))")
      return MigrationReport(from: from, to: target, backup: backup, checks: checks)
    } catch {
      FileOps.remove(copyURL)
      throw error
    }
  }

  // records/migration/<시작 버전>-<끝 버전>/ 에 계획과 검사 결과를 남긴다
  func writeRecord(_ copy: DataFolder, from: Int, plan: [any MigrationStep], checks: [String]) throws {
    let dir = copy.records.appending(path: "migration/\(from)-\(target)")
    let planValue: JSONValue = .object([
      "from": .number(Double(from)), "to": .number(Double(target)), "app": .string(app.label),
      "steps": .array(plan.map { .object(["from": .number(Double($0.from)), "to": .number(Double($0.to)), "kind": .string($0.kind.rawValue), "summary": .string($0.summary)]) }),
    ])
    try FileOps.writeAtomic(JSONText.record(planValue), to: dir.appending(path: "plan.json"))
    try FileOps.writeAtomic(JSONText.record(.object(["checks": .array(checks.map(JSONValue.string))])), to: dir.appending(path: "checks.json"))
  }
}

// 마이그레이션 전후를 견주기 위한 기록. 기록과 학생 글은 파일마다 해시를, 영역마다 파일 수와 JSONL 줄 수를 남긴다.
public struct MigrationSnapshot: Sendable {
  // 바이트 그대로여야 하는 파일 (데이터 폴더 기준 상대 경로 → sha256)
  public let hashes: [String: String]
  // 영역마다 파일 수
  public let counts: [String: Int]
  // learner/*.jsonl 의 줄 수
  public let lines: [String: Int]

  // 기록 (고치지 않는다). records/migration/ 은 마이그레이션이 새로 쓰므로 뺀다.
  static let recordAreas = ["records", "library/entries", "sources", "learner"]
  // 수를 견주는 영역
  public static let areas = ["sources", "records", "library/entries", "library/concepts", "library/unplaced", "learner", "syllabus"]

  public static func take(_ folder: DataFolder) throws -> MigrationSnapshot {
    var hashes: [String: String] = [:]
    for area in recordAreas {
      for rel in FileOps.files(under: folder.url.appending(path: area)) where !rel.hasPrefix("migration/") || area != "records" {
        let path = "\(area)/\(rel)"
        hashes[path] = try Hash.file(folder.url.appending(path: path))
      }
    }
    var counts: [String: Int] = [:]
    for area in areas {
      counts[area] = FileOps.files(under: folder.url.appending(path: area)).filter { !(area == "records" && $0.hasPrefix("migration/")) }.count
    }
    var lines: [String: Int] = [:]
    for name in FileOps.list(folder.learner) where name.hasSuffix(".jsonl") {
      lines[name] = (try? JSONLines.read(folder.learner.appending(path: name)).values.count) ?? -1
    }
    return MigrationSnapshot(hashes: hashes, counts: counts, lines: lines)
  }
}

// 바꿔 끼우기 전에 사본 전체를 본다 (MIGRATION.md 의 검증 표). 하나라도 어긋나면 실패다.
public enum MigrationVerifier {
  public static func verify(before: MigrationSnapshot, copy: DataFolder, steps: [any MigrationStep], target: Int, schemas: SchemaSet? = nil) -> [String] {
    var issues: [String] = []
    // 스키마 파일이 있으면 모든 데이터 파일을 그 판의 스키마로 본다
    if let schemas { issues += DataValidation.validate(copy, schemas: schemas) }

    // 스키마: 모든 YAML 이 읽히고 kind 와 v 가 있다. 모든 JSONL 줄이 읽힌다. 스키마 버전이 목표와 같다.
    for rel in FileOps.files(under: copy.url) {
      let url = copy.url.appending(path: rel)
      if rel.hasSuffix(".yaml") {
        do {
          let value = try YAML.read(url)
          if value["kind"]?.string == nil || value["v"]?.int == nil { issues.append("\(rel): kind 와 v 가 없습니다") }
        } catch {
          issues.append("\(rel): \(error.localizedDescription)")
        }
      } else if rel.hasSuffix(".jsonl") {
        do {
          _ = try JSONLines.read(url)
        } catch {
          issues.append(error.localizedDescription)
        }
      }
    }
    if let schema = try? SchemaFile.read(copy) {
      if schema.schema != target { issues.append("meta/schema.yaml 의 버전이 \(schema.schema) 입니다 (목표 \(target))") }
    } else {
      issues.append("meta/schema.yaml 을 읽지 못했습니다")
    }

    // 기록과 학생 글: 바이트 그대로다. 보관으로 옮긴 기록은 보관에 원본이 있다.
    guard let after = try? MigrationSnapshot.take(copy) else { return issues + ["사본의 파일을 읽지 못했습니다"] }
    for (path, hash) in before.hashes.sorted(by: { $0.key < $1.key }) {
      if let now = after.hashes[path] {
        if now != hash { issues.append("\(path): 기록이 바뀌었습니다") }
        continue
      }
      if let step = steps.first(where: { s in s.archives.contains { path.hasPrefix($0) } }) {
        let archived = copy.url.appending(path: "archive/\(step.from)/\(path)")
        if (try? Hash.file(archived)) != hash { issues.append("\(path): 보관(archive/\(step.from)/)에 원본이 없습니다") }
      } else {
        issues.append("\(path): 기록이 없어졌습니다")
      }
    }

    // 수 보존: 단계가 늘거나 줄인다고 선언한 영역만 다를 수 있다
    let declared = steps.reduce(into: Set<String>()) { $0.formUnion($1.changesCounts) }
    for area in MigrationSnapshot.areas where !declared.contains(area) && before.counts[area] != after.counts[area] {
      issues.append("\(area): 파일 수가 \(before.counts[area] ?? 0) → \(after.counts[area] ?? 0) 로 바뀌었습니다")
    }
    for (name, count) in before.lines where after.lines[name] != count {
      issues.append("learner/\(name): 줄 수가 \(count) → \(after.lines[name] ?? 0) 로 바뀌었습니다")
    }

    // 단계마다의 검증 (주장 장부, 뜻 해시, id)
    for step in steps { issues += step.verify(before: before, after: copy) }
    return issues
  }
}

// 사본에서만 돌려 보는 시험 (jindesk migrate --check <백업 폴더나 zip>). 원래 폴더는 건드리지 않는다.
public enum MigrationCheck {
  public struct Report: Sendable {
    public var from: Int?
    public var to: Int
    public var issues: [String]
    public var notes: [String]
    public var added: [String]
    public var removed: [String]
    public var changed: [String]
    public var workFolder: URL
  }

  public static func run(
    source: URL, folders: AppFolders, app: AppVersion, steps: [any MigrationStep] = MigrationPlan.steps, target: Int = CurrentSchema.version,
    sample: Int? = nil, schemas: URL? = nil, log: @escaping @Sendable (String) async -> Void = { _ in }
  ) async throws -> Report {
    let schemaSet = Migrator.schemaSet(schemas, target: target)
    let work = folders.cache.appending(path: "migrate-check/\(JobID.stamp(Date()))-\(UUID().uuidString.prefix(6))")
    try FileOps.makeDirectory(work)
    var folder = source
    if source.pathExtension.lowercased() == "zip" {
      await log("zip 을 풉니다: \(source.path)")
      folder = try await Backup.unzip(source, into: work.appending(path: "unzipped"))
    }
    let copyURL = work.appending(path: "data")
    try FileManager.default.copyItem(at: folder, to: copyURL)
    let copy = DataFolder(copyURL)
    var report = Report(from: nil, to: target, issues: [], notes: [], added: [], removed: [], changed: [], workFolder: work)

    switch Migrator.state(of: copy, target: target) {
    case .uninitialized:
      throw ToolError("\(folder.path) 는 Jindesk 데이터 폴더가 아닙니다 (meta/schema.yaml 이 없습니다)")
    case .unreadable(let reason):
      throw ToolError(reason)
    case .newer(let v):
      throw ToolError("데이터의 스키마 \(v) 가 앱의 스키마 \(target) 보다 높습니다")
    case .current:
      report.notes.append("스키마가 이미 \(target) 이라 마이그레이션할 것이 없습니다")
      report.issues = MigrationVerifier.verify(before: try MigrationSnapshot.take(copy), copy: copy, steps: [], target: target, schemas: schemaSet)
      return report
    case .older(let from):
      report.from = from
      let plan = try MigrationPlan.chain(from: from, to: target, steps: steps)
      let allBefore = try fileHashes(copy)
      let before = try MigrationSnapshot.take(copy)
      let context = MigrationContext(app: app, folders: folders, sample: sample, log: log)
      for step in plan {
        await log("스키마 \(step.from) → \(step.to): \(step.summary)")
        try await step.run(copy, context)
        var schema = try SchemaFile.read(copy)
        schema.schema = step.to
        schema.history.append(.init(from: step.from, to: step.to, app: app.app, at: Clock.isoLocal(), kind: step.kind.rawValue, backup: "(check)"))
        try schema.write(to: copy)
      }
      report.issues = MigrationVerifier.verify(before: before, copy: copy, steps: plan, target: target, schemas: schemaSet)
      let allAfter = try fileHashes(copy)
      report.added = allAfter.keys.filter { allBefore[$0] == nil }.sorted()
      report.removed = allBefore.keys.filter { allAfter[$0] == nil }.sorted()
      report.changed = allAfter.keys.filter { allBefore[$0] != nil && allBefore[$0] != allAfter[$0] }.sorted()
      return report
    }
  }

  static func fileHashes(_ folder: DataFolder) throws -> [String: String] {
    var out: [String: String] = [:]
    for rel in FileOps.files(under: folder.url) where rel != "meta/.lock" { out[rel] = try Hash.file(folder.url.appending(path: rel)) }
    return out
  }
}
