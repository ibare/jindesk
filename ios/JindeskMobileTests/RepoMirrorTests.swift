import CryptoKit
import Foundation
import JindeskKit
import Testing

// 데이터 리포 받기 (MOBILE.md 의 받기). GitHub 은 URLProtocol 로 흉내 낸다. 시험마다 다른 호스트를 써서 서로 섞이지 않는다.
@Suite struct RepoMirrorTests {
  let host = "\(UUID().uuidString.lowercased()).github.test"
  let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "jindesk-mirror-\(UUID().uuidString)")
  let config = RepoConfig(owner: "example", name: "jindesk-data", branch: "main")

  var mirror: RepoMirror {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FakeGitHub.self]
    return RepoMirror(root: root, api: URL(string: "https://\(host)/")!, session: URLSession(configuration: configuration))
  }

  static let schema = "kind: \"schema\"\nv: 1\nschema: \(CurrentSchema.version)\ncreated: \"2026-10-18T09:00:00+09:00\"\n"
  static let concept = "library/concepts/physics/a.2/newtons-second-law/concept.yaml"

  // 지어낸 데이터 폴더 한 벌
  static var files: [String: String] {
    [
      "meta/schema.yaml": schema,
      "meta/.lock": "1\n",
      "syllabus/physics.yaml": "kind: \"syllabus\"\n",
      concept: "kind: \"concept\"\n",
      "library/concepts/physics/a.2/newtons-second-law/page.yaml": "kind: \"page\"\n",
      "library/glossary.yaml": "kind: \"glossary\"\n",
      "library/vendor/cdn.example/lib.js": "export const x = 1\n",
      "library/entries/physics/a.2/second-law.md": "원시 엔트리\n",
      "learner/comments.jsonl": "{\"id\":\"c1\"}\n",
      "sources/20261018-3fa2c1d0/meta.yaml": "kind: \"source\"\n",
      "sources/20261018-3fa2c1d0/labels.yaml": "kind: \"labels\"\n",
      "sources/20261018-3fa2c1d0/original.pdf": "%PDF-1.7\n",
      "sources/20261018-3fa2c1d0/pages/0001.txt": "글자층\n",
      "records/runs/2026-10.jsonl": "{}\n",
    ]
  }

  func read(_ rel: String) -> String? { FileOps.readIfExists(root.appending(path: "current").appending(path: rel)) }

  @Test func 처음_받기는_읽는_데_필요한_파일만_받아_바꿔_끼운다() async throws {
    let commit = FakeGitHub.commit(host, files: Self.files)
    let outcome = try await mirror.sync(config, token: "t")
    #expect(outcome == .updated(commit: commit, fetched: 9, removed: 0))
    #expect(read("meta/schema.yaml") == Self.schema)
    #expect(read(Self.concept) == "kind: \"concept\"\n")
    #expect(read("library/vendor/cdn.example/lib.js") != nil)
    #expect(read("learner/comments.jsonl") != nil)
    #expect(read("sources/20261018-3fa2c1d0/labels.yaml") != nil)
    for skipped in ["meta/.lock", "library/entries/physics/a.2/second-law.md", "sources/20261018-3fa2c1d0/original.pdf", "sources/20261018-3fa2c1d0/pages/0001.txt", "records/runs/2026-10.jsonl"] {
      #expect(read(skipped) == nil, "\(skipped)")
    }
    #expect(mirror.manifest?.commit == commit)
    #expect(mirror.data != nil)
    // 받는 데 쓴 것은 남기지 않는다
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "objects").path))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "next").path))
    #expect(FakeGitHub.requests(host).allSatisfy { $0.contains("Bearer t") })
  }

  @Test func 같은_커밋이면_다시_받지_않는다() async throws {
    let commit = FakeGitHub.commit(host, files: Self.files)
    _ = try await mirror.sync(config, token: "t")
    FakeGitHub.reset(host)
    #expect(try await mirror.sync(config, token: "t") == .upToDate(commit: commit))
    #expect(FakeGitHub.requests(host).count == 1)
  }

  @Test func 새_커밋에서는_바뀐_파일만_받고_없어진_파일은_지운다() async throws {
    _ = FakeGitHub.commit(host, files: Self.files)
    _ = try await mirror.sync(config, token: "t")
    var files = Self.files
    files[Self.concept] = "kind: \"concept\"\nv: 2\n"
    files["library/concepts/physics/a.2/circular-motion/concept.yaml"] = "kind: \"concept\"\n"
    files["learner/comments.jsonl"] = nil
    // 받지 않는 파일만 바뀐 것은 받지 않는다
    files["records/runs/2026-10.jsonl"] = "{}\n{}\n"
    let commit = FakeGitHub.commit(host, files: files)
    FakeGitHub.reset(host)

    #expect(try await mirror.sync(config, token: "t") == .updated(commit: commit, fetched: 2, removed: 1))
    #expect(read(Self.concept) == "kind: \"concept\"\nv: 2\n")
    #expect(read("library/concepts/physics/a.2/circular-motion/concept.yaml") != nil)
    #expect(read("learner/comments.jsonl") == nil)
    #expect(FakeGitHub.requests(host).filter { $0.contains("/git/blobs/") }.count == 2)
  }

  @Test func 스키마가_다르면_바꿔_끼우지_않고_받아_둔_판을_그대로_둔다() async throws {
    let first = FakeGitHub.commit(host, files: Self.files)
    _ = try await mirror.sync(config, token: "t")
    var files = Self.files
    files["meta/schema.yaml"] = Self.schema.replacingOccurrences(of: "schema: \(CurrentSchema.version)", with: "schema: \(CurrentSchema.version + 1)")
    files[Self.concept] = "kind: \"concept\"\nv: 2\n"
    _ = FakeGitHub.commit(host, files: files)

    let error = await #expect(throws: MirrorError.self) { try await mirror.sync(config, token: "t") }
    #expect(error?.message.contains("폰 앱을 업데이트") == true)
    #expect(error?.schema == CurrentSchema.version + 1)
    #expect(mirror.manifest?.commit == first)
    #expect(read(Self.concept) == "kind: \"concept\"\n")
  }

  @Test func 받다가_끊기면_받아_둔_판이_그대로고_다음에는_못_받은_것만_받는다() async throws {
    let first = FakeGitHub.commit(host, files: Self.files)
    _ = try await mirror.sync(config, token: "t")
    var files = Self.files
    files[Self.concept] = "kind: \"concept\"\nv: 2\n"
    files["library/glossary.yaml"] = "kind: \"glossary\"\nv: 2\n"
    let next = FakeGitHub.commit(host, files: files)
    FakeGitHub.fail(host, blobOf: "kind: \"glossary\"\nv: 2\n")

    await #expect(throws: MirrorError.self) { try await mirror.sync(config, token: "t") }
    #expect(mirror.manifest?.commit == first)
    #expect(read(Self.concept) == "kind: \"concept\"\n")

    FakeGitHub.fail(host, blobOf: nil)
    FakeGitHub.reset(host)
    #expect(try await mirror.sync(config, token: "t") == .updated(commit: next, fetched: 2, removed: 0))
    #expect(FakeGitHub.requests(host).filter { $0.contains("/git/blobs/") }.count == 1)
    #expect(read("library/glossary.yaml") == "kind: \"glossary\"\nv: 2\n")
  }

  @Test func 토큰이_맞지_않으면_알린다() async throws {
    _ = FakeGitHub.commit(host, files: Self.files)
    FakeGitHub.status(host, 401)
    let error = await #expect(throws: MirrorError.self) { try await mirror.sync(config, token: "t") }
    #expect(error?.message.contains("토큰") == true)
    #expect(mirror.data == nil)
  }

  @Test func 받는_경로와_안전한_경로() throws {
    #expect(RepoMirror.wanted("meta/schema.yaml"))
    #expect(!RepoMirror.wanted("meta/.lock"))
    #expect(RepoMirror.wanted("library/concepts/physics/a.2/x/figures/f1-r1.html"))
    #expect(!RepoMirror.wanted("library/entries/physics/a.2/x.md"))
    #expect(RepoMirror.wanted("sources/20261018-3fa2c1d0/meta.yaml"))
    #expect(!RepoMirror.wanted("sources/20261018-3fa2c1d0/original.pptx"))
    #expect(!RepoMirror.wanted("records/runs/2026-10.jsonl"))
    #expect(RepoMirror.safe("library/glossary.yaml"))
    #expect(!RepoMirror.safe("../x"))
    #expect(!RepoMirror.safe("library/../../x"))
    #expect(!RepoMirror.safe("/etc/hosts"))
    let json = Data(#"{"encoding":"base64","content":"a2luZDog\nInBhZ2Ui\n"}"#.utf8)
    #expect(try RepoMirror.blobContent(json) == Data("kind: \"page\"".utf8))
    #expect(try RepoMirror.blobContent(Data("raw".utf8)) == Data("raw".utf8))
  }
}

// 가짜 GitHub API. 호스트마다 리포 하나를 둔다.
final class FakeGitHub: URLProtocol, @unchecked Sendable {
  struct Repo {
    var head = ""
    var trees: [String: String] = [:]
    var entries: [String: [(path: String, sha: String)]] = [:]
    var blobs: [String: Data] = [:]
    var failing: String?
    var status: Int?
    var requests: [String] = []
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var repos: [String: Repo] = [:]

  static func edit<T>(_ host: String, _ change: (inout Repo) -> T) -> T {
    lock.withLock {
      var repo = repos[host] ?? Repo()
      defer { repos[host] = repo }
      return change(&repo)
    }
  }

  static func gitSHA(_ kind: String, _ data: Data) -> String {
    Insecure.SHA1.hash(data: Data("\(kind) \(data.count)\0".utf8) + data).map { String(format: "%02x", $0) }.joined()
  }

  // 이 파일들로 새 커밋을 만들어 main 이 가리키게 한다
  @discardableResult
  static func commit(_ host: String, files: [String: String]) -> String {
    edit(host) { repo in
      var entries: [(path: String, sha: String)] = []
      for (path, text) in files.sorted(by: { $0.key < $1.key }) {
        let data = Data(text.utf8)
        let sha = gitSHA("blob", data)
        repo.blobs[sha] = data
        entries.append((path, sha))
      }
      let tree = gitSHA("tree", Data(entries.map { "\($0.path) \($0.sha)" }.joined(separator: "\n").utf8))
      let commit = gitSHA("commit", Data("\(tree) \(repo.head)".utf8))
      repo.entries[tree] = entries
      repo.trees[commit] = tree
      repo.head = commit
      return commit
    }
  }

  static func fail(_ host: String, blobOf text: String?) {
    edit(host) { $0.failing = text.map { gitSHA("blob", Data($0.utf8)) } }
  }

  static func status(_ host: String, _ code: Int?) { edit(host) { $0.status = code } }
  static func reset(_ host: String) { edit(host) { $0.requests = [] } }
  static func requests(_ host: String) -> [String] { edit(host) { $0.requests } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let url = request.url!
    let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
    let parts = url.path.split(separator: "/").map(String.init)
    let (code, body): (Int, Data) = Self.edit(url.host ?? "") { repo in
      repo.requests.append("\(url.path) \(auth)")
      if let status = repo.status { return (status, Data()) }
      // repos/<주인>/<리포>/…
      guard parts.count >= 5, parts[0] == "repos" else { return (404, Data()) }
      let rest = Array(parts[3...])
      switch (rest.first, rest.count) {
      case ("commits", 2):
        return rest[1] == "main" && !repo.head.isEmpty ? (200, Data(repo.head.utf8)) : (404, Data())
      case ("git", 3) where rest[1] == "commits":
        guard let tree = repo.trees[rest[2]] else { return (404, Data()) }
        return (200, Data(#"{"sha":"\#(rest[2])","tree":{"sha":"\#(tree)"}}"#.utf8))
      case ("git", 3) where rest[1] == "trees":
        guard let entries = repo.entries[rest[2]] else { return (404, Data()) }
        let items = entries.map { #"{"path":"\#($0.path)","mode":"100644","type":"blob","sha":"\#($0.sha)"}"# }
        return (200, Data(#"{"sha":"\#(rest[2])","truncated":false,"tree":[\#(items.joined(separator: ","))]}"#.utf8))
      case ("git", 3) where rest[1] == "blobs":
        if rest[2] == repo.failing { return (500, Data()) }
        guard let blob = repo.blobs[rest[2]] else { return (404, Data()) }
        return (200, blob)
      default:
        return (404, Data())
      }
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
}
