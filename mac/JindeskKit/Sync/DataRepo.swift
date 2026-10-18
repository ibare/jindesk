// 데이터 리포 (DATA.md 의 데이터 리포). 데이터 폴더는 앱 설정에서 연결한 GitHub 비공개 리포의 클론이고, 앱이 커밋하고 올린다.
// 연결(리포 주소와 로컬 위치)은 그 맥의 앱 설정에 두고 데이터 폴더 안에는 두지 않는다. 폴더의 원격이 연결한 리포와 다르면 올리지 않는다.
// 인증은 키체인의 토큰을 git 을 띄울 때만 자격 증명 도우미로 넘긴다. .git/config 에는 적지 않는다.
// 쓰는 쪽은 연결한 맥 하나다. 켤 때 원격이 앞서 있으면 받는다(fast-forward). 폰 앱은 올라간 커밋을 GitHub API 로 받아 읽는다 (MOBILE.md).
import Foundation

// 앱 설정에서 연결한 리포: 리포 주소와 로컬 위치(데이터 폴더)
public struct RepoLink: Sendable, Equatable, Codable {
  public var url: String
  public var path: String

  public init(url: String, path: String) {
    self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    self.path = path
  }

  public var folder: DataFolder { DataFolder(path: path) }

  // 이 연결의 데이터 폴더인가
  public func owns(_ data: DataFolder) -> Bool { folder.path == data.path }

  // 리포 주소를 견줄 때는 끝의 / 와 .git, 대소문자를 가리지 않는다
  public static func same(_ a: String, _ b: String) -> Bool { key(a) == key(b) }

  static func key(_ url: String) -> String {
    var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while s.hasSuffix("/") { s.removeLast() }
    if s.hasSuffix(".git") { s.removeLast(4) }
    return s
  }
}

// 데이터 리포에 쓰는 토큰 (SETUP.md 의 데이터 리포). 그 리포만 읽고 쓸 수 있는 fine-grained 토큰이다.
public enum RepoToken {
  public static let service = ClaudeToken.service
  public static let account = "data-repo-token"
  public static let label = "Jindesk 데이터 리포 토큰"

  public static var exists: Bool { Keychain.exists(service: service, account: account) }

  public static func read() -> String? {
    (try? Keychain.read(service: service, account: account))?.nilIfBlank
  }

  public static func save(_ token: String) throws {
    guard let value = token.nilIfBlank else { throw RequestError("토큰이 비어 있습니다") }
    try Keychain.write(service: service, account: account, value: value, label: label)
  }

  public static func delete() throws {
    try Keychain.delete(service: service, account: account)
  }
}

public enum DataRepo {
  // 한 번 커밋하고 올린 결과
  public struct Outcome: Sendable, Equatable {
    public var at: String
    // 연결한 리포 주소
    public var remote: String
    // 이번에 만든 커밋 (바뀐 것이 없었으면 nil)
    public var commit: String?
    // 지금 HEAD (아직 커밋이 하나도 없으면 nil)
    public var head: String?
    // 원격이 HEAD 까지 받았는가
    public var pushed = false
    // 크기 때문에 뺀 파일 (데이터 폴더 안의 경로). 지난번까지 뺀 것도 든다.
    public var excluded: [String] = []
    public var error: String?

    public init(at: String, remote: String, commit: String? = nil, head: String? = nil, pushed: Bool = false, excluded: [String] = [], error: String? = nil) {
      self.at = at
      self.remote = remote
      self.commit = commit
      self.head = head
      self.pushed = pushed
      self.excluded = excluded
      self.error = error
    }
  }

  // 연결한 결과
  public enum Connected: Sendable, Equatable {
    // 빈 리포라 데이터 폴더를 새로 만들어 첫 커밋을 올렸다 (올리지 못했으면 그 오류)
    case created(error: String?)
    // Jindesk 리포를 클론했다
    case cloned
    // 로컬 위치가 이미 그 리포의 클론이었다
    case opened
  }

  // 켤 때 원격과 견준 결과
  public enum Pull: Sendable, Equatable {
    case same
    // 원격이 앞서 있어 받았다
    case pulled
    // 로컬이 앞서 있다 (다음 올리기에 올라간다)
    case ahead
    // 기록이 갈라졌다. 올리지 않는다
    case diverged
    // 원격이 앞서 있는데 올리지 않은 변경이 있어 받지 못했다
    case blocked
    // 원격에 닿지 못했다
    case unreachable(String)
  }

  // GitHub 이 받지 않는 크기
  public static let sizeLimit = 100 * 1024 * 1024
  // 늘 빼는 것: 잠금, Finder 의 파일, 쓰는 중인 임시 파일 (FileOps.writeAtomic, 자료 넣기)
  // 원본 자료(original.*, 바꾼 source.*)는 자료 버킷에 둔다 (DECISIONS.md 31)
  static let alwaysExcluded = ["/meta/.lock", ".DS_Store", ".*.tmp-*", "/sources/.incoming-*/", "/sources/*/original.*", "/sources/*/source.*"]
  static let excludeHeader = "# Jindesk 가 적는다 (DATA.md 의 데이터 리포)"
  static let largeHeader = "# 100MB 이상이라 뺀 파일"
  static let diverged = "기록이 갈라졌습니다. 다른 곳에서 이 리포에 올렸습니다. 올리지 않습니다"

  // 데이터 폴더가 git 리포인가. git 을 띄우지 않고 본다 (git 이 없는 맥에서 /usr/bin/git 이 설치 창을 띄우지 않게).
  public static func isRepo(_ data: DataFolder) -> Bool { FileOps.exists(data.url.appending(path: ".git")) }

  // 커밋 글: 첫 줄은 첫 까닭이고, 모았으면 나머지를 아래 줄에 적는다
  public static func message(_ reasons: [String]) -> String {
    guard let first = reasons.first else { return "데이터 폴더" }
    let rest = reasons.dropFirst()
    return rest.isEmpty ? first : "\(first) 외 \(rest.count)\n\n" + rest.map { "- \($0)" }.joined(separator: "\n")
  }

  // 폴더의 원격 origin 주소. 리포가 아니거나 원격이 없으면 nil.
  public static func remote(_ data: DataFolder, git: String? = nil) async -> String? {
    guard isRepo(data), let g = Git(data.path, executable: git, token: nil, timeout: .seconds(10)) else { return nil }
    guard let r = try? await g.run(["config", "--get", "remote.origin.url"]), r.succeeded else { return nil }
    return r.trimmed.nilIfBlank
  }

  // 이 연결의 폴더이고 원격도 연결한 리포인가. 아니면 그 까닭.
  static func bindingProblem(_ data: DataFolder, link: RepoLink, git: String?) async -> String? {
    guard link.owns(data) else { return "연결한 데이터 폴더(\(link.path))가 아닙니다. 올리지 않습니다" }
    guard let origin = await remote(data, git: git) else { return "데이터 폴더가 git 리포가 아니거나 원격이 없습니다. 올리지 않습니다" }
    guard RepoLink.same(origin, link.url) else { return "데이터 폴더의 원격(\(origin))이 연결한 리포와 다릅니다. 올리지 않습니다" }
    return nil
  }

  // MARK: - 연결

  // 리포를 연결한다. 빈 리포면 데이터 폴더를 새로 만들어 첫 커밋을 올리고, Jindesk 리포면 클론한다.
  // 로컬 위치는 없거나 빈 폴더, 또는 이미 그 리포의 클론이어야 한다.
  public static func connect(_ link: RepoLink, token: String?, app: AppVersion, git: String? = nil) async throws -> Connected {
    guard !link.url.isEmpty else { throw DataRepoError("리포 주소가 비어 있습니다") }
    let data = link.folder
    if isRepo(data) {
      guard let origin = await remote(data, git: git), RepoLink.same(origin, link.url) else {
        throw DataRepoError("로컬 위치가 다른 리포의 클론입니다. 없거나 빈 폴더를 넣습니다")
      }
      guard data.isInitialized else { throw DataRepoError("로컬 위치의 클론이 Jindesk 데이터 폴더가 아닙니다") }
      return .opened
    }
    if FileOps.exists(data.url) && FileOps.list(data.url).contains(where: { $0 != ".DS_Store" }) {
      throw DataRepoError("로컬 위치가 비어 있지 않습니다. 없거나 빈 폴더를 넣습니다")
    }
    let parent = data.url.deletingLastPathComponent()
    try FileOps.makeDirectory(parent)
    guard let outside = Git(parent.path, executable: git, token: token, timeout: .seconds(60)) else {
      throw DataRepoError("git 을 찾지 못했습니다. 터미널에서 xcode-select --install 로 설치합니다")
    }
    let heads = try await outside.run(["ls-remote", "--heads", link.url])
    guard heads.succeeded else { throw DataRepoError("리포에 닿지 못했습니다. 주소와 토큰을 봅니다 — \(heads.summary)") }

    if heads.trimmed.isEmpty {
      try data.initialize(app: app)
      guard let g = Git(data.path, executable: git, token: token, timeout: .seconds(60)) else { throw DataRepoError("git 을 찾지 못했습니다") }
      _ = try await g.check(["init", "-q", "-b", "main"])
      _ = try await g.check(["remote", "add", "origin", link.url])
      let first = await sync(data, link: link, token: token, message: "처음 연결", git: git)
      return .created(error: first.error)
    }

    let made = !FileOps.exists(data.url)
    // 큰 리포도 받도록 상한을 넉넉히 둔다
    guard let cloner = Git(parent.path, executable: git, token: token, timeout: .seconds(600)) else { throw DataRepoError("git 을 찾지 못했습니다") }
    let clone = try await cloner.run(["clone", "-q", link.url, data.path])
    guard clone.succeeded else {
      if made { FileOps.remove(data.url) } else { clearContents(data.url) }
      throw DataRepoError("클론하지 못했습니다 — \(clone.summary)")
    }
    guard data.isInitialized else {
      if made { FileOps.remove(data.url) } else { clearContents(data.url) }
      throw DataRepoError("Jindesk 데이터 리포가 아닙니다(meta/schema.yaml 이 없습니다). 빈 리포나 Jindesk 데이터 리포를 연결합니다")
    }
    return .cloned
  }

  // 클론하다 실패한 빈 폴더를 처음처럼 비운다
  static func clearContents(_ url: URL) {
    for name in FileOps.list(url) { FileOps.remove(url.appending(path: name)) }
  }

  // MARK: - 켤 때 받기

  // 원격이 앞서 있으면 받는다. 연결한 폴더가 아니면 nil.
  public static func pull(_ data: DataFolder, link: RepoLink, token: String?, git: String? = nil) async -> Pull? {
    guard await bindingProblem(data, link: link, git: git) == nil, let g = Git(data.path, executable: git, token: token, timeout: .seconds(120)) else { return nil }
    do {
      let fetch = try await g.run(["fetch", "-q", "origin"])
      guard fetch.succeeded else { return .unreachable(fetch.summary) }
      let branch = try await g.check(["symbolic-ref", "--short", "HEAD"])
      let theirs = try await g.run(["rev-parse", "-q", "--verify", "refs/remotes/origin/\(branch)"])
      let ours = try await g.run(["rev-parse", "-q", "--verify", "HEAD"])
      guard theirs.succeeded else { return .same }
      guard ours.succeeded else { return .diverged }
      if ours.trimmed == theirs.trimmed { return .same }
      if try await g.run(["merge-base", "--is-ancestor", "HEAD", theirs.trimmed]).succeeded {
        guard try await g.check(["status", "--porcelain"]).isEmpty else { return .blocked }
        _ = try await g.check(["merge", "-q", "--ff-only", theirs.trimmed])
        return .pulled
      }
      if try await g.run(["merge-base", "--is-ancestor", theirs.trimmed, "HEAD"]).succeeded { return .ahead }
      return .diverged
    } catch {
      return .unreachable(error.localizedDescription)
    }
  }

  // MARK: - 커밋하고 올리기

  // 바뀐 것을 커밋하고 연결한 리포에 올린다. 연결한 폴더가 아니거나 원격이 다르면 아무것도 하지 않고 그 까닭을 돌려준다.
  // 올리지 못해도 커밋은 남고, 다음 번에 함께 올라간다.
  public static func sync(
    _ data: DataFolder, link: RepoLink, token: String?, message: String, git: String? = nil, timeout: Duration = .seconds(120)
  ) async -> Outcome {
    var outcome = Outcome(at: Clock.isoLocal(), remote: link.url)
    if let problem = await bindingProblem(data, link: link, git: git) {
      outcome.error = problem
      return outcome
    }
    guard let g = Git(data.path, executable: git, token: token, timeout: timeout) else {
      outcome.error = "git 을 찾지 못했습니다"
      return outcome
    }
    do {
      outcome.excluded = try await writeExcludes(data, g)
      // 이미 리포에 들어간 원본 자료는 리포에서만 뺀다 (로컬 파일은 남는다)
      _ = try await g.check(["rm", "-r", "-q", "--cached", "--ignore-unmatch", "--", "sources/*/original.*", "sources/*/source.*"])
      _ = try await g.check(["add", "-A"])
      let staged = try await g.run(["diff", "--cached", "--quiet"])
      if staged.termination == .exited(1) {
        var args = ["commit", "-q", "--no-verify", "-m", message]
        // 관리자가 작성자를 정해 두지 않았으면 앱 이름으로 쓴다
        if try await g.run(["config", "user.email"]).trimmed.isEmpty { args = ["-c", "user.name=Jindesk", "-c", "user.email=jindesk@invalid"] + args }
        _ = try await g.check(args)
        outcome.commit = try await g.check(["rev-parse", "HEAD"])
      } else if !staged.succeeded {
        throw DataRepoError("git diff --cached 실패 — \(staged.summary)")
      }
      let head = try await g.run(["rev-parse", "-q", "--verify", "HEAD"])
      // 아직 커밋이 없다 (아무것도 없는 데이터 폴더)
      guard head.succeeded else { return outcome }
      outcome.head = head.trimmed
      let branch = try await g.check(["symbolic-ref", "--short", "HEAD"])
      let tracked = try await g.run(["rev-parse", "-q", "--verify", "refs/remotes/origin/\(branch)"])
      if tracked.succeeded && tracked.trimmed == outcome.head {
        outcome.pushed = true
        return outcome
      }
      let push = try await g.run(["push", "-q", "origin", "HEAD"])
      guard push.succeeded else {
        let text = push.stderr.lowercased()
        throw DataRepoError(
          text.contains("rejected") || text.contains("non-fast-forward") || text.contains("fetch first") ? diverged : "올리지 못했습니다 — \(push.summary)")
      }
      outcome.pushed = true
    } catch {
      outcome.error = error.localizedDescription
    }
    return outcome
  }

  // 환경 점검의 한 줄. 연결한 리포에 닿는지까지 본다 (토큰으로 읽기).
  public static func check(_ link: RepoLink?, data: DataFolder?, git: String? = nil) async -> CheckItem {
    guard let link else { return CheckItem("데이터 리포", .warn, "연결하지 않았습니다. 폰 앱과 나누지 않습니다 (SETUP.md 의 데이터 리포)") }
    if let data, let problem = await bindingProblem(data, link: link, git: git) { return CheckItem("데이터 리포", .fail, problem) }
    let token = RepoToken.read()
    guard token != nil else { return CheckItem("데이터 리포", .fail, "\(link.url) · 토큰이 키체인에 없습니다") }
    guard let g = Git(link.folder.path, executable: git, token: token, timeout: .seconds(20)) else { return CheckItem("데이터 리포", .fail, "git 을 찾지 못했습니다") }
    guard let r = try? await g.run(["ls-remote", "--heads", link.url]) else { return CheckItem("데이터 리포", .fail, "\(link.url) · git 을 띄우지 못했습니다") }
    return r.succeeded ? CheckItem("데이터 리포", .ok, link.url) : CheckItem("데이터 리포", .fail, "\(link.url) · 닿지 못했습니다 — \(r.summary)")
  }

  // MARK: - 뺄 파일

  // .git/info/exclude 에 늘 빼는 것과 큰 파일을 적는다. 크기 때문에 뺀 파일 전체를 돌려준다.
  static func writeExcludes(_ data: DataFolder, _ g: Git) async throws -> [String] {
    let file = data.url.appending(path: ".git/info/exclude")
    var lines = (FileOps.readIfExists(file) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    let before = lines
    if !lines.contains(excludeHeader) { lines.append(excludeHeader) }
    for p in alwaysExcluded where !lines.contains(p) {
      let at = lines.firstIndex(of: largeHeader) ?? lines.endIndex
      lines.insert(p, at: at)
    }
    var large = lines.firstIndex(of: largeHeader).map { Array(lines[($0 + 1)...]) } ?? []
    for path in try await changedPaths(g) where !large.contains(pattern(path)) {
      let attributes = try? FileManager.default.attributesOfItem(atPath: data.url.appending(path: path).path)
      guard let size = attributes?[.size] as? Int, size >= sizeLimit else { continue }
      if !lines.contains(largeHeader) { lines.append(largeHeader) }
      lines.append(pattern(path))
      large.append(pattern(path))
    }
    if lines != before {
      try FileOps.makeDirectory(file.deletingLastPathComponent())
      try FileOps.writeAtomic(lines.joined(separator: "\n") + "\n", to: file)
    }
    return large.map(unpattern)
  }

  // 아직 올리지 않은 파일들 (새 파일은 하나하나)
  static func changedPaths(_ g: Git) async throws -> [String] {
    let r = try await g.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
    guard r.succeeded else { throw DataRepoError("git status 실패 — \(r.summary)") }
    var out: [String] = []
    var skipNext = false
    for entry in r.stdout.split(separator: 0) {
      if skipNext {
        skipNext = false
        continue
      }
      let text = String(decoding: entry, as: UTF8.self)
      guard text.count > 3 else { continue }
      // 이름 바꾸기와 복사는 옛 이름이 뒤따른다
      if let x = text.first, x == "R" || x == "C" { skipNext = true }
      out.append(String(text.dropFirst(3)))
    }
    return out
  }

  // 데이터 폴더 안의 경로 하나만 가리키는 exclude 줄. 글롭 글자는 막는다.
  static func pattern(_ path: String) -> String {
    var out = "/"
    for ch in path {
      if "\\*?[".contains(ch) { out.append("\\") }
      out.append(ch)
    }
    if out.hasSuffix(" ") { out.insert("\\", at: out.index(before: out.endIndex)) }
    return out
  }

  static func unpattern(_ line: String) -> String {
    var out = ""
    var escaped = false
    for ch in line.dropFirst() {
      if ch == "\\" && !escaped {
        escaped = true
        continue
      }
      escaped = false
      out.append(ch)
    }
    return out
  }

  // MARK: - git

  struct Git {
    let executable: String
    let directory: String
    let environment: [String: String]
    let timeout: Duration
    let authenticated: Bool

    init?(_ directory: String, executable: String?, token: String?, timeout: Duration) {
      guard let git = executable ?? ToolLocator.find("git", in: ToolLocator.commonDirectories()) else { return nil }
      self.executable = git
      self.directory = directory
      var env = ChildEnvironment.base(toolDirectories: ToolLocator.commonDirectories())
      // 묻는 창을 띄울 수 없다. 인증이 안 되면 묻지 말고 실패한다.
      env["GIT_TERMINAL_PROMPT"] = "0"
      if let token { env["JINDESK_GIT_TOKEN"] = token }
      environment = env
      authenticated = token != nil
      self.timeout = timeout
    }

    // 토큰이 있으면 그 맥의 다른 자격 증명(키체인, gh)을 비우고 이 실행에만 토큰을 준다
    static let credentialHelper = #"!f() { test "$1" = get && echo username=x-access-token && echo "password=$JINDESK_GIT_TOKEN"; }; f"#

    func run(_ arguments: [String]) async throws -> ChildResult {
      let auth = authenticated ? ["-c", "credential.helper=", "-c", "credential.helper=\(Self.credentialHelper)"] : []
      return try await ChildProcess.run(
        ChildSpec(executable: executable, arguments: auth + arguments, environment: environment, directory: directory), timeout: timeout)
    }

    // 성공해야 하는 명령. 실패하면 stderr 끝부분을 담아 던진다.
    func check(_ arguments: [String]) async throws -> String {
      let r = try await run(arguments)
      guard r.succeeded else { throw DataRepoError("git \(arguments.first(where: { !$0.hasPrefix("-") && !$0.contains("=") }) ?? "") 실패 — \(r.summary)") }
      return r.trimmed
    }
  }
}

public struct DataRepoError: LocalizedError, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

extension ChildResult {
  fileprivate var trimmed: String { stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) }
}
