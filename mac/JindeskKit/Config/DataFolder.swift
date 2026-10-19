import Darwin
import Foundation

// 데이터 폴더(기본 ~/Jindesk). 학생의 원본 자료, 기록, 정리층, 코멘트와 요구가 모두 여기 있고, 백업은 이 폴더를 통째로 한다.
// 배치는 DATA.md 의 "데이터 폴더 배치"를 따른다.
public struct DataFolder: Sendable, Equatable {
  public let url: URL

  // 실제 경로로 둔다 (아직 없는 폴더면 있는 조상까지)
  public init(_ url: URL) {
    self.url = URL(fileURLWithPath: FileOps.resolvedPath(url.path), isDirectory: true)
  }

  public init(path: String) {
    self.init(URL(fileURLWithPath: path))
  }

  public static var defaultURL: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Jindesk")
  }

  public var path: String { url.path }

  public var meta: URL { url.appending(path: "meta") }
  public var schemaFile: URL { meta.appending(path: "schema.yaml") }
  public var lockFile: URL { meta.appending(path: ".lock") }
  public var syllabus: URL { url.appending(path: "syllabus") }
  public var sources: URL { url.appending(path: "sources") }
  // 자료 묶음 (DECISIONS.md 35)
  public var bundles: URL { url.appending(path: "bundles") }
  public var records: URL { url.appending(path: "records") }
  public var library: URL { url.appending(path: "library") }
  public var learner: URL { url.appending(path: "learner") }

  // 모든 작업의 실행 요약: records/runs/<YYYY-MM>.jsonl
  public func runsLog(_ date: Date = Date()) -> URL {
    records.appending(path: "runs/\(Clock.month(date)).jsonl")
  }

  // 작업 종류별 기록: records/<종류>/<작업 id>/
  public func record(_ kind: String, _ id: String) -> URL {
    records.appending(path: kind).appending(path: id)
  }

  // 처음 쓸 때 만드는 폴더들
  static let topFolders = ["meta", "syllabus", "sources", "bundles", "records", "library", "learner"]

  // Jindesk 데이터 폴더인가 (meta/schema.yaml 이 있다)
  public var isInitialized: Bool { FileOps.exists(schemaFile) }

  // MARK: - 고를 수 있는 폴더인가

  public enum Issue: Sendable, Equatable {
    // 쓸 수 없다
    case error(String)
    // 쓸 수 있지만 알린다
    case warning(String)

    public var message: String {
      switch self {
      case .error(let m), .warning(let m): m
      }
    }

    public var isError: Bool {
      if case .error = self { true } else { false }
    }
  }

  // 데이터 폴더로 쓸 수 있는지 본다. 비어 있거나 없는 폴더, 또는 이미 Jindesk 데이터 폴더인 곳만 쓸 수 있다.
  public func issues(appBundle: URL? = nil) -> [Issue] {
    var out: [Issue] = []
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    let exists = fm.fileExists(atPath: path, isDirectory: &isDirectory)

    if url.pathComponents.contains(where: { $0.hasSuffix(".app") }) || appBundle.map({ path.hasPrefix($0.path + "/") }) == true {
      out.append(.error("앱 번들 안에는 둘 수 없습니다. 업데이트 때 바뀌고 서명이 깨집니다."))
    }
    if exists && !isDirectory.boolValue {
      out.append(.error("같은 이름의 파일이 있습니다."))
    } else if exists {
      if !fm.isWritableFile(atPath: path) { out.append(.error("이 폴더에 쓸 수 없습니다.")) }
      let visible = FileOps.list(url).filter { !$0.hasPrefix(".") }
      if !isInitialized && !visible.isEmpty {
        out.append(.error("다른 파일이 들어 있는 폴더입니다. 비어 있는 폴더나 Jindesk 데이터 폴더를 고르세요."))
      }
    } else if let ancestor = Self.nearestExisting(url), !fm.isWritableFile(atPath: ancestor.path) {
      out.append(.error("\(ancestor.path) 에 폴더를 만들 수 없습니다."))
    }

    if let reason = Self.syncReason(url) { out.append(.warning(reason)) }
    if let ancestor = Self.nearestExisting(url), let type = Self.fileSystemType(ancestor), type != "apfs" {
      out.append(.warning("APFS 볼륨이 아닙니다(\(type)). 마이그레이션 때 사본을 만드는 데 공간과 시간이 듭니다."))
    }
    return out
  }

  // 있는 가장 가까운 조상 (자신 포함)
  static func nearestExisting(_ url: URL) -> URL? {
    var current = url
    while !FileManager.default.fileExists(atPath: current.path) {
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { return nil }
      current = parent
    }
    return current
  }

  // 동기화되는 폴더면 그 까닭. iCloud Drive("데스크탑 및 문서 폴더" 동기화를 켠 ~/Documents 포함)와 다른 클라우드 저장소.
  // 동기화가 파일을 자리표시자로 내리거나 충돌 사본을 만들 수 있다.
  static func syncReason(_ url: URL) -> String? {
    let home = NSHomeDirectory()
    let p = url.path
    if p.hasPrefix(home + "/Library/Mobile Documents") {
      return "iCloud Drive 로 동기화되는 폴더입니다. 동기화가 파일을 내려 두거나 충돌 사본을 만들 수 있습니다."
    }
    if p.hasPrefix(home + "/Library/CloudStorage") {
      return "클라우드 저장소로 동기화되는 폴더입니다. 동기화가 파일을 내려 두거나 충돌 사본을 만들 수 있습니다."
    }
    if let ancestor = nearestExisting(url), (try? ancestor.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
      return "iCloud 로 동기화되는 폴더입니다(데스크탑 및 문서 폴더 동기화). 동기화가 파일을 내려 두거나 충돌 사본을 만들 수 있습니다."
    }
    return nil
  }

  static func fileSystemType(_ url: URL) -> String? {
    var info = statfs()
    guard statfs(url.path, &info) == 0 else { return nil }
    return withUnsafeBytes(of: info.f_fstypename) { raw in
      String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  // MARK: - 처음 쓰기

  // 폴더와 meta/schema.yaml 을 만든다. 이미 Jindesk 데이터 폴더면 아무것도 바꾸지 않는다.
  public func initialize(app: AppVersion, now: Date = Date()) throws {
    if isInitialized { return }
    for name in Self.topFolders { try FileOps.makeDirectory(url.appending(path: name)) }
    try SchemaFile(schema: CurrentSchema.version, created: Clock.isoLocal(now), lastOpenedBy: app, history: []).write(to: self)
  }
}

// 앱 판 (Info.plist 의 CFBundleShortVersionString, CFBundleVersion)
public struct AppVersion: Sendable, Equatable, Codable {
  public let app: String
  public let build: String

  public init(app: String, build: String) {
    self.app = app
    self.build = build
  }

  public static func from(_ bundle: Bundle) -> AppVersion {
    AppVersion(
      app: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
      build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
  }

  public var label: String { "\(app) (\(build))" }
}

// 데이터 폴더 하나를 한 프로세스만 쓰게 하는 잠금 (meta/.lock).
// 작업이 하나라도 도는 동안과 백업 만들기, 마이그레이션이 이것을 쥔다. 파일 잠금(flock)이라 프로세스가 끝나면 저절로 풀린다.
// 잡으면 파일에 프로세스 id 를 적는다. 백업에 들어가도 해가 없다.
public final class DataLock: @unchecked Sendable {
  let url: URL
  private let mutex = NSLock()
  private var fd: Int32 = -1

  public init(_ url: URL) {
    self.url = url
  }

  public convenience init(_ folder: DataFolder) {
    self.init(folder.lockFile)
  }

  public var isHeld: Bool { mutex.withLock { fd >= 0 } }

  public func tryAcquire() -> Bool {
    mutex.withLock {
      if fd >= 0 { return true }
      try? FileOps.makeDirectory(url.deletingLastPathComponent())
      let f = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
      guard f >= 0 else { return false }
      if flock(f, LOCK_EX | LOCK_NB) != 0 {
        close(f)
        return false
      }
      ftruncate(f, 0)
      let text = "\(getpid())\n"
      _ = text.withCString { Darwin.write(f, $0, strlen($0)) }
      fd = f
      return true
    }
  }

  // 잡을 때까지 기다린다. 처음 기다릴 때 onWait 를 부른다. 취소되면 CancellationError.
  public func acquire(onWait: @Sendable () async -> Void = {}) async throws {
    var waited = false
    while !tryAcquire() {
      if !waited {
        await onWait()
        waited = true
      }
      try await Task.sleep(for: .milliseconds(500))
    }
  }

  public func release() {
    mutex.withLock {
      guard fd >= 0 else { return }
      ftruncate(fd, 0)
      flock(fd, LOCK_UN)
      close(fd)
      fd = -1
    }
  }

  deinit { release() }
}
