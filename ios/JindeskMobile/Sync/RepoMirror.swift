// 데이터 리포 받기 (MOBILE.md 의 받기). 가지의 마지막 커밋 트리를 보고, 읽는 데 필요한 파일 가운데 바뀐 것만 받는다.
// 받은 것은 받아 둔 사본을 복제한 새 폴더에 모아 스키마 버전을 확인한 뒤 바꿔 끼운다. 끊기면 받아 둔 사본은 그대로다.
// 받은 파일은 blob 해시마다 objects/ 에 먼저 두어, 끊긴 뒤 다시 받을 때 받은 것을 다시 받지 않는다.
import Foundation
import JindeskKit

// 받을 리포 (설정 화면에서 넣는다. 토큰은 키체인에 따로 둔다)
struct RepoConfig: Codable, Equatable, Sendable {
  var owner = ""
  var name = ""
  var branch = "main"

  var isComplete: Bool { [owner, name, branch].allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
}

// 받아 둔 판: 커밋, 받은 때, 경로마다 blob 해시
struct MirrorManifest: Codable, Equatable, Sendable {
  var commit: String
  var at: String
  var files: [String: String]
}

enum MirrorOutcome: Equatable, Sendable {
  case upToDate(commit: String)
  case updated(commit: String, fetched: Int, removed: Int)
}

struct MirrorError: LocalizedError, Equatable, Sendable {
  let message: String
  // 받은 데이터의 스키마 버전이 앱과 다르면 그 버전 (앱을 업데이트하라는 안내를 띄운다)
  var schema: Int?
  init(_ message: String, schema: Int? = nil) {
    self.message = message
    self.schema = schema
  }
  var errorDescription: String? { message }
}

final class RepoMirror: Sendable {
  let root: URL
  let api: URL
  let session: URLSession
  // 함께 받는 파일 수
  static let parallel = 6

  init(root: URL, api: URL = URL(string: "https://api.github.com")!, session: URLSession = .shared) {
    self.root = root
    self.api = api
    self.session = session
  }

  // 받아 둔 사본 (데이터 폴더와 같은 배치의 일부)
  var current: URL { root.appending(path: "current") }
  var manifestFile: URL { root.appending(path: "manifest.json") }
  var objects: URL { root.appending(path: "objects") }

  var manifest: MirrorManifest? {
    guard let data = try? Data(contentsOf: manifestFile) else { return nil }
    return try? JSONDecoder().decode(MirrorManifest.self, from: data)
  }

  // 읽을 데이터 폴더. 아직 받은 것이 없으면 nil.
  var data: DataFolder? {
    let folder = DataFolder(current)
    return folder.isInitialized ? folder : nil
  }

  // 읽는 데 필요한 경로인가 (MOBILE.md 의 받는 것과 받지 않는 것)
  static func wanted(_ path: String) -> Bool {
    if path == "meta/schema.yaml" { return true }
    if path.hasPrefix("syllabus/") || path.hasPrefix("learner/") { return true }
    if path.hasPrefix("library/") { return !path.hasPrefix("library/entries/") }
    let parts = path.split(separator: "/")
    return parts.count == 3 && parts[0] == "sources" && (parts[2] == "meta.yaml" || parts[2] == "labels.yaml")
  }

  // 데이터 폴더 밖을 가리키지 않는 경로인가
  static func safe(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
  }

  // MARK: - 받기

  func sync(_ config: RepoConfig, token: String, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> MirrorOutcome {
    let repo = "repos/\(config.owner.trimmingCharacters(in: .whitespaces))/\(config.name.trimmingCharacters(in: .whitespaces))"
    let branch = config.branch.trimmingCharacters(in: .whitespaces)
    let commit = String(decoding: try await get("\(repo)/commits/\(branch)", accept: "application/vnd.github.sha", token: token), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let before = manifest
    if before?.commit == commit, data != nil { return .upToDate(commit: commit) }

    let commitInfo = try JSONValue.parse(try await get("\(repo)/git/commits/\(commit)", token: token))
    guard let treeSHA = commitInfo["tree"]?["sha"]?.stringValue else { throw MirrorError("커밋 \(commit.prefix(7)) 의 트리를 읽지 못했습니다") }
    let tree = try JSONValue.parse(try await get("\(repo)/git/trees/\(treeSHA)?recursive=1", token: token))
    if tree["truncated"]?.boolValue == true { throw MirrorError("리포의 파일이 너무 많아 GitHub 이 목록을 잘라 보냈습니다") }
    var files: [String: String] = [:]
    for entry in tree["tree"]?.arrayValue ?? [] {
      // 일반 파일만 받는다 (폴더, 하위 모듈, 바로 가기는 받지 않는다)
      guard entry["type"]?.stringValue == "blob", entry["mode"]?.stringValue != "120000", let path = entry["path"]?.stringValue,
        let sha = entry["sha"]?.stringValue, Self.wanted(path), Self.safe(path)
      else { continue }
      files[path] = sha
    }

    let old = before?.files ?? [:]
    let hasCurrent = data != nil
    let need = files.filter { path, sha in !hasCurrent || old[path] != sha || !FileManager.default.fileExists(atPath: current.appending(path: path).path) }
    try await fetch(Set(need.values), repo: repo, token: token, progress: progress)

    let next = root.appending(path: "next")
    FileOps.remove(next)
    if hasCurrent { try FileManager.default.copyItem(at: current, to: next) } else { try FileOps.makeDirectory(next) }
    for (path, sha) in need {
      let target = next.appending(path: path)
      try FileOps.makeDirectory(target.deletingLastPathComponent())
      FileOps.remove(target)
      try FileManager.default.copyItem(at: objects.appending(path: sha), to: target)
    }
    let removed = hasCurrent ? old.keys.filter { files[$0] == nil } : []
    for path in removed { FileOps.remove(next.appending(path: path)) }

    // 스키마 버전이 같을 때만 바꿔 끼운다 (MIGRATION.md). 받은 파일은 objects/ 에 남아 다음 받기에 쓴다.
    let version: Int
    do {
      version = try SchemaFile.read(DataFolder(next)).schema
    } catch {
      FileOps.remove(next)
      throw MirrorError("받은 데이터의 스키마를 읽지 못했습니다: \(error.localizedDescription)")
    }
    guard version == CurrentSchema.version else {
      FileOps.remove(next)
      throw MirrorError(
        version > CurrentSchema.version
          ? "데이터가 이 앱보다 새 판입니다(데이터 스키마 \(version), 앱 \(CurrentSchema.version)). 폰 앱을 업데이트하세요"
          : "데이터가 이 앱보다 옛 판입니다(데이터 스키마 \(version), 앱 \(CurrentSchema.version)). 맥 앱을 업데이트하세요",
        schema: version)
    }

    let previous = root.appending(path: "previous")
    FileOps.remove(previous)
    if hasCurrent { try FileOps.move(current, to: previous) }
    try FileOps.move(next, to: current)
    FileOps.remove(previous)
    let written = MirrorManifest(commit: commit, at: Clock.isoLocal(), files: files)
    try FileOps.writeAtomic(try JSONEncoder().encode(written), to: manifestFile)
    FileOps.remove(objects)
    return .updated(commit: commit, fetched: need.count, removed: removed.count)
  }

  // 받아 둔 것을 모두 지운다 (설정의 "받아 둔 것 지우기")
  func clear() {
    for name in ["current", "next", "previous", "objects", "manifest.json"] { FileOps.remove(root.appending(path: name)) }
  }

  #if DEBUG
    // 화면 확인: GitHub 대신 이 데이터 폴더를 받아 둔 사본으로 쓴다 (-mirrorFrom <폴더>). 받는 경로만 옮긴다.
    func importLocal(_ source: URL) throws {
      clear()
      var files: [String: String] = [:]
      for path in FileOps.files(under: source) where Self.wanted(path) {
        let target = current.appending(path: path)
        try FileOps.makeDirectory(target.deletingLastPathComponent())
        try FileManager.default.copyItem(at: source.appending(path: path), to: target)
        files[path] = "local"
      }
      try FileOps.writeAtomic(try JSONEncoder().encode(MirrorManifest(commit: "local", at: Clock.isoLocal(), files: files)), to: manifestFile)
    }
  #endif

  // blob 들을 objects/<해시> 로 받는다. 이미 있는 것은 건너뛴다.
  // 하나가 실패해도 나머지는 끝까지 받아 둔다. 다음 받기가 못 받은 것만 받게 하려는 것이다.
  private func fetch(_ shas: Set<String>, repo: String, token: String, progress: @escaping @Sendable (Int, Int) -> Void) async throws {
    try FileOps.makeDirectory(objects)
    let todo = shas.filter { !FileManager.default.fileExists(atPath: objects.appending(path: $0).path) }.sorted()
    let total = shas.count
    var done = total - todo.count
    var failure: (any Error)?
    progress(done, total)
    await withTaskGroup(of: (any Error)?.self) { group in
      var queue = todo[...]
      func add() {
        guard let sha = queue.popFirst() else { return }
        group.addTask {
          do {
            let bytes = try await self.get("\(repo)/git/blobs/\(sha)", accept: "application/vnd.github.raw+json", token: token)
            try FileOps.writeAtomic(try Self.blobContent(bytes), to: self.objects.appending(path: sha))
            return nil
          } catch {
            return error
          }
        }
      }
      for _ in 0..<Self.parallel { add() }
      while let result = await group.next() {
        if let result {
          failure = failure ?? result
        } else {
          done += 1
          progress(done, total)
        }
        add()
      }
    }
    if let failure { throw failure }
  }

  // raw 로 오면 그대로, JSON(base64)으로 오면 풀어서
  static func blobContent(_ bytes: Data) throws -> Data {
    guard bytes.first == UInt8(ascii: "{"), let value = try? JSONValue.parse(bytes), value["encoding"]?.stringValue == "base64",
      let content = value["content"]?.stringValue
    else { return bytes }
    guard let decoded = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { throw MirrorError("받은 파일을 풀지 못했습니다") }
    return decoded
  }

  // MARK: - GitHub API

  private func get(_ path: String, accept: String = "application/vnd.github+json", token: String) async throws -> Data {
    guard let url = URL(string: path, relativeTo: api) else { throw MirrorError("주소를 만들지 못했습니다: \(path)") }
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (body, response): (Data, URLResponse)
    do {
      (body, response) = try await session.data(for: request)
    } catch {
      throw MirrorError("GitHub 에 닿지 못했습니다: \(error.localizedDescription)")
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    switch status {
    case 200: return body
    case 401: throw MirrorError("토큰이 맞지 않거나 만료됐습니다")
    case 403, 429:
      if (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
        throw MirrorError("GitHub 요청 한도를 넘었습니다. 한 시간 안에 다시 받습니다. 받은 파일은 남아 있습니다")
      }
      throw MirrorError("이 토큰으로는 리포를 읽을 수 없습니다 (Contents: Read-only 가 필요합니다)")
    case 404, 422: throw MirrorError("리포나 가지를 찾지 못했습니다. 주인, 이름, 가지와 토큰이 읽을 수 있는 리포인지 봅니다")
    default: throw MirrorError("GitHub 응답 \(status)")
    }
  }
}
