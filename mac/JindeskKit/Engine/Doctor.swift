// 환경 점검 (화면의 "환경 점검", 명령줄의 jindesk doctor). Dock 에서 띄운 앱은 셸과 환경이 달라서,
// 작업을 돌리기 전에 필요한 것이 갖춰졌는지 본다. 토큰 같은 값은 읽지 않는다. 있고 없음만 적는다.
import CoreServices
import Foundation

public struct CheckItem: Codable, Sendable, Equatable, Identifiable {
  public enum Status: String, Codable, Sendable { case ok, warn, fail }

  public let name: String
  public let status: Status
  public let detail: String
  public var id: String { name }
  public var ok: Bool { status != .fail }

  public init(_ name: String, _ status: Status, _ detail: String) {
    self.name = name
    self.status = status
    self.detail = detail
  }
}

// claude --version 의 "2.1.296 (Claude Code)" 에서 버전을 읽는다
public enum ClaudeVersion {
  public static func parse(_ text: String) -> [Int]? {
    guard let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first else { return nil }
    let parts = token.split(separator: ".").map { Int($0) }
    guard parts.count >= 2, parts.allSatisfy({ $0 != nil }) else { return nil }
    return parts.map { $0! }
  }

  public static func atLeast(_ v: [Int], _ minimum: [Int]) -> Bool {
    for i in 0..<max(v.count, minimum.count) {
      let a = i < v.count ? v[i] : 0
      let b = i < minimum.count ? minimum[i] : 0
      if a != b { return a > b }
    }
    return true
  }

  public static func text(_ v: [Int]) -> String { v.map(String.init).joined(separator: ".") }
}

public enum Doctor {
  public struct Input: Sendable {
    public var guardHelper: String?
    public var instructions: InstructionSource?
    public var schemas: URL?
    public var data: DataFolder?
    public var folders: AppFolders?
    public var claudePath: String?
    public var app: AppVersion?

    public init(
      guardHelper: String? = nil, instructions: InstructionSource? = nil, schemas: URL? = nil, data: DataFolder? = nil, folders: AppFolders? = nil,
      claudePath: String? = nil, app: AppVersion? = nil
    ) {
      self.guardHelper = guardHelper
      self.instructions = instructions
      self.schemas = schemas
      self.data = data
      self.folders = folders
      self.claudePath = claudePath
      self.app = app
    }
  }

  public static func run(_ input: Input) async -> [CheckItem] {
    var items: [CheckItem] = []
    let env = ProcessInfo.processInfo.environment

    if let app = input.app { items.append(CheckItem("앱", .ok, app.label)) }

    let blocked = env.keys.filter { key in ChildEnvironment.blockedPrefixes.contains { key.hasPrefix($0) } }.sorted()
    items.append(
      CheckItem(
        "앱 환경", .ok,
        "PATH=\(env["PATH"] ?? "(없음)") · LANG=\(env["LANG"] ?? "(없음)") · LC_ALL=\(env["LC_ALL"] ?? "(없음)")"
          + (blocked.isEmpty ? "" : " · 자식에게 넘기지 않는 변수: \(blocked.joined(separator: ", "))")))

    if let helper = input.guardHelper {
      let ok = FileManager.default.isExecutableFile(atPath: helper)
      items.append(CheckItem("외부 호출 검사 훅", ok ? .ok : .fail, ok ? helper : "실행 파일이 없습니다: \(helper)"))
    }
    if let source = input.instructions { items.append(instructionsCheck(source)) }
    if let schemas = input.schemas {
      let dir = schemas.appending(path: String(CurrentSchema.version))
      let count = FileOps.list(dir).filter { $0.hasSuffix(".schema.json") }.count
      items.append(
        count > 0
          ? CheckItem("스키마", .ok, "\(dir.path) · \(count)개")
          : CheckItem("스키마", .fail, "\(dir.path) 에 스키마가 없습니다"))
    }

    items += await claudeCheck(override: input.claudePath)
    items.append(
      ClaudeToken.exists
        ? CheckItem("토큰", .ok, "키체인 (\(ClaudeToken.service) · \(ClaudeToken.account))")
        : CheckItem("토큰", .fail, "키체인에 없습니다 (\(ClaudeToken.service) · \(ClaudeToken.account))"))
    items.append(keynoteCheck())
    let base = ChildEnvironment.base(toolDirectories: ToolLocator.commonDirectories())
    items.append(await processGroupCheck(environment: base))

    if let data = input.data { items += dataCheck(data, app: input.app) }
    if let folders = input.folders { items.append(foldersCheck(folders)) }
    return items
  }

  // claude 위치와 최소 버전
  static func claudeCheck(override: String?) async -> [CheckItem] {
    let found = await ToolLocator.locateAll()
    var items: [CheckItem] = []
    let base = ChildEnvironment.base(toolDirectories: ToolLocator.commonDirectories())
    let claude = override ?? found["claude"]
    if let claude {
      let version = (try? await ChildProcess.run(ChildSpec(executable: claude, arguments: ["--version"], environment: base), timeout: .seconds(15)))
        .map { $0.stdoutText.split(separator: "\n").first.map(String.init) ?? "" } ?? ""
      let minimum = ExternalGuard.minimumClaudeVersion
      if let v = ClaudeVersion.parse(version), !ClaudeVersion.atLeast(v, minimum) {
        items.append(CheckItem("claude", .fail, "\(claude) · \(version) — \(ClaudeVersion.text(minimum)) 이상이 필요합니다. 터미널에서 claude update 를 실행하세요"))
      } else if version.isEmpty {
        items.append(CheckItem("claude", .fail, "\(claude) · 버전을 읽지 못했습니다"))
      } else {
        items.append(CheckItem("claude", .ok, "\(claude) · \(version)"))
      }
    } else {
      items.append(CheckItem("claude", .fail, "찾지 못했습니다. curl -fsSL https://claude.ai/install.sh | bash 로 설치하세요"))
    }
    if let soffice = found["soffice"] {
      items.append(CheckItem("LibreOffice", .ok, soffice))
    } else {
      items.append(CheckItem("LibreOffice", .warn, "없습니다. Keynote 가 없을 때만 필요합니다"))
    }
    return items
  }

  // PPT 를 PDF 로 바꾸는 Keynote
  static func keynoteCheck() -> CheckItem {
    let urls = LSCopyApplicationURLsForBundleIdentifier("com.apple.iWork.Keynote" as CFString, nil)?.takeRetainedValue() as? [URL] ?? []
    if let url = urls.first { return CheckItem("Keynote", .ok, url.path) }
    return CheckItem("Keynote", .warn, "없습니다. PPT 를 PDF 로 바꿀 때 LibreOffice 를 씁니다")
  }

  // 그룹 리더와 하위 프로세스가 함께 끝나는지
  static func processGroupCheck(environment: [String: String]) async -> CheckItem {
    do {
      let child = try ChildProcess.spawn(
        ChildSpec(executable: "/bin/sh", arguments: ["-c", "sleep 30 & sleep 30 & wait"], environment: environment, stdout: .null))
      try await Task.sleep(for: .milliseconds(200))
      child.stop(grace: 2)
      _ = await child.wait()
      for _ in 0..<20 {
        if kill(-child.pid, 0) == -1 && errno == ESRCH { return CheckItem("프로세스 그룹 정리", .ok, "하위 프로세스까지 끝났습니다") }
        try await Task.sleep(for: .milliseconds(100))
      }
      return CheckItem("프로세스 그룹 정리", .fail, "그룹 \(child.pid) 에 프로세스가 남았습니다")
    } catch {
      return CheckItem("프로세스 그룹 정리", .fail, error.localizedDescription)
    }
  }

  // 앱 번들의 지침. 미커밋 변경을 담아 빌드했으면 기록에도 그렇게 남는다.
  static func instructionsCheck(_ source: InstructionSource) -> CheckItem {
    let kinds = JobKind.withInstructions
    guard !kinds.isEmpty else { return CheckItem("지침", .ok, "\(source.directory.path) · 아직 지침이 있는 작업이 없습니다") }
    let missing = source.missing(kinds)
    guard missing.isEmpty else {
      return CheckItem("지침", .fail, "\(source.directory.path) 에 지침이 없습니다: \(missing.map(\.rawValue).joined(separator: ", "))")
    }
    let dirty = kinds.filter { source.build($0).dirty }
    return CheckItem(
      "지침", dirty.isEmpty ? .ok : .warn,
      "\(source.directory.path) · \(kinds.count)개" + (dirty.isEmpty ? "" : " · 미커밋 변경을 담아 빌드함: \(dirty.map(\.rawValue).joined(separator: ", "))"))
  }

  static func dataCheck(_ data: DataFolder, app: AppVersion?) -> [CheckItem] {
    var items: [CheckItem] = []
    let issues = data.issues()
    let errors = issues.filter(\.isError).map(\.message)
    let warnings = issues.filter { !$0.isError }.map(\.message)
    if !errors.isEmpty {
      items.append(CheckItem("데이터 폴더", .fail, "\(data.path) · \(errors.joined(separator: " "))"))
    } else {
      items.append(CheckItem("데이터 폴더", warnings.isEmpty ? .ok : .warn, ([data.path] + warnings).joined(separator: " · ")))
    }
    if data.isInitialized {
      if let file = try? SchemaFile.read(data) {
        let status: CheckItem.Status = file.schema == CurrentSchema.version ? .ok : file.schema > CurrentSchema.version ? .fail : .warn
        let note =
          file.schema == CurrentSchema.version
          ? "" : file.schema > CurrentSchema.version ? " — 더 새 판의 Jindesk 가 만든 데이터입니다" : " — 켜면 마이그레이션합니다"
        items.append(CheckItem("스키마 버전", status, "데이터 \(file.schema) · 앱 \(CurrentSchema.version)\(note)"))
      } else {
        items.append(CheckItem("스키마 버전", .fail, "\(data.schemaFile.path) 를 읽지 못했습니다"))
      }
    }
    let lock = DataLock(data)
    if FileOps.exists(data.meta) {
      if lock.tryAcquire() {
        lock.release()
        items.append(CheckItem("데이터 폴더 잠금", .ok, "잡혀 있지 않습니다"))
      } else {
        let pid = FileOps.readIfExists(data.lockFile)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        items.append(CheckItem("데이터 폴더 잠금", .warn, "프로세스 \(pid) 가 작업 중입니다"))
      }
    }
    return items
  }

  // 없으면 앱을 켤 때 만든다. 있으면 쓸 수 있어야 하고, 없으면 만들 수 있어야 한다.
  static func foldersCheck(_ folders: AppFolders) -> CheckItem {
    let fm = FileManager.default
    let paths = [folders.support, folders.cache]
    let bad = paths.filter { url in
      let target = DataFolder.nearestExisting(url) ?? url
      return !fm.isWritableFile(atPath: target.path)
    }
    let missing = paths.filter { !fm.fileExists(atPath: $0.path) }
    if !bad.isEmpty { return CheckItem("앱 지원 폴더와 캐시", .fail, "쓸 수 없습니다: \(bad.map(\.path).joined(separator: ", "))") }
    return CheckItem(
      "앱 지원 폴더와 캐시", .ok, "\(folders.support.path) · \(folders.cache.path)" + (missing.isEmpty ? "" : " · 아직 없습니다 (켜면 만듭니다)"))
  }
}
