import Foundation
import Testing
@testable import JindeskKit

// 데이터 리포 (DATA.md 의 데이터 리포). 원격은 임시 폴더의 bare 리포로 둔다. 파일 경로 원격이라 토큰은 쓰지 않는다.
@Suite struct DataRepoTests {
  let git = "/usr/bin/git"

  @discardableResult
  func run(_ arguments: [String], in dir: URL) async throws -> String {
    let r = try await ChildProcess.run(ChildSpec(executable: git, arguments: arguments, environment: ["PATH": "/usr/bin:/bin"], directory: dir.path))
    #expect(r.succeeded, "git \(arguments.joined(separator: " ")): \(r.summary)")
    return r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // 아무것도 없는 빈 리포 (GitHub 에서 막 만든 리포)
  func emptyRemote(_ place: TempPlace, _ name: String = "remote.git") async throws -> URL {
    let bare = place.root.appending(path: name)
    try await run(["init", "-q", "--bare", "-b", "main", bare.path], in: place.root)
    return bare
  }

  // 빈 리포에 연결해 데이터 폴더를 만든 Jindesk 리포
  func connected(_ place: TempPlace) async throws -> (RepoLink, URL) {
    let bare = try await emptyRemote(place)
    let link = RepoLink(url: bare.path, path: place.data.path)
    let result = try await DataRepo.connect(link, token: nil, app: testApp, git: git)
    #expect(result == .created(error: nil))
    try await run(["config", "user.name", "시험"], in: place.data.url)
    try await run(["config", "user.email", "test@invalid"], in: place.data.url)
    return (link, bare)
  }

  func tracked(_ place: TempPlace, in bare: URL) async throws -> [String] {
    try await run(["--git-dir", bare.path, "ls-tree", "-r", "--name-only", "main"], in: place.root).split(separator: "\n").map(String.init)
  }

  // MARK: - 연결

  @Test func 빈_리포에_연결하면_데이터_폴더를_새로_만들어_첫_커밋을_올린다() async throws {
    let place = TempPlace()
    let (_, bare) = try await connected(place)
    #expect(place.data.isInitialized)
    #expect(try await tracked(place, in: bare).contains("meta/schema.yaml"))
    #expect(try await run(["--git-dir", bare.path, "log", "-1", "--format=%s", "main"], in: place.root) == "처음 연결")
  }

  @Test func Jindesk_리포에_연결하면_클론해서_연다() async throws {
    let place = TempPlace()
    let (link, bare) = try await connected(place)
    try place.write("learner/comments.jsonl", "{\"id\":\"c1\"}\n")
    _ = await DataRepo.sync(place.data, link: link, token: nil, message: "코멘트", git: git)

    let other = DataFolder(place.root.appending(path: "새 맥/Jindesk"))
    let result = try await DataRepo.connect(RepoLink(url: bare.path, path: other.path), token: nil, app: testApp, git: git)
    #expect(result == .cloned)
    #expect(other.isInitialized)
    #expect(FileOps.readIfExists(other.url.appending(path: "learner/comments.jsonl")) == "{\"id\":\"c1\"}\n")
  }

  @Test func 이미_그_리포의_클론이면_그대로_연다() async throws {
    let place = TempPlace()
    let (link, _) = try await connected(place)
    #expect(try await DataRepo.connect(link, token: nil, app: testApp, git: git) == .opened)
  }

  @Test func Jindesk_리포가_아니면_연결하지_않고_로컬_위치를_남기지_않는다() async throws {
    let place = TempPlace()
    let bare = try await emptyRemote(place)
    let work = place.root.appending(path: "work")
    try await run(["clone", "-q", bare.path, work.path], in: place.root)
    try "다른 리포\n".write(to: work.appending(path: "README.md"), atomically: true, encoding: .utf8)
    try await run(["-c", "user.name=시험", "-c", "user.email=test@invalid", "add", "-A"], in: work)
    try await run(["-c", "user.name=시험", "-c", "user.email=test@invalid", "commit", "-q", "-m", "다른 것"], in: work)
    try await run(["push", "-q", "origin", "HEAD"], in: work)

    let error = await #expect(throws: DataRepoError.self) {
      try await DataRepo.connect(RepoLink(url: bare.path, path: place.data.path), token: nil, app: testApp, git: git)
    }
    #expect(error?.message.contains("Jindesk 데이터 리포가 아닙니다") == true)
    #expect(!FileOps.exists(place.data.url))
  }

  @Test func 로컬_위치가_비어_있지_않거나_다른_리포의_클론이면_연결하지_않는다() async throws {
    let place = TempPlace()
    let (_, _) = try await connected(place)
    let second = try await emptyRemote(place, "second.git")
    // 다른 리포의 클론
    await #expect(throws: DataRepoError.self) {
      try await DataRepo.connect(RepoLink(url: second.path, path: place.data.path), token: nil, app: testApp, git: git)
    }
    // 무언가 들어 있는 폴더
    let busy = place.root.appending(path: "busy")
    try FileOps.makeDirectory(busy)
    try "x".write(to: busy.appending(path: "note.txt"), atomically: true, encoding: .utf8)
    let error = await #expect(throws: DataRepoError.self) {
      try await DataRepo.connect(RepoLink(url: second.path, path: busy.path), token: nil, app: testApp, git: git)
    }
    #expect(error?.message.contains("비어 있지 않습니다") == true)
    #expect(FileOps.exists(busy.appending(path: "note.txt")))
  }

  // MARK: - 커밋하고 올리기

  @Test func 연결한_폴더가_아니거나_원격이_다르면_커밋하지_않고_올리지_않는다() async throws {
    let place = TempPlace()
    let (link, bare) = try await connected(place)
    try place.write("learner/comments.jsonl", "{\"id\":\"c1\"}\n")
    // 다른 폴더를 가리키는 연결 (개발 맥에서 학생 백업을 연 경우)
    let elsewhere = RepoLink(url: link.url, path: place.root.appending(path: "다른 곳").path)
    let a = await DataRepo.sync(place.data, link: elsewhere, token: nil, message: "코멘트", git: git)
    #expect(a.error?.contains("연결한 데이터 폴더") == true)
    // 같은 폴더지만 원격이 다른 리포
    let b = await DataRepo.sync(place.data, link: RepoLink(url: place.root.appending(path: "학생.git").path, path: place.data.path), token: nil, message: "코멘트", git: git)
    #expect(b.error?.contains("원격") == true)
    #expect(try await run(["rev-list", "--count", "HEAD"], in: place.data.url) == "1")
    #expect(try await run(["--git-dir", bare.path, "rev-list", "--count", "main"], in: place.root) == "1")
  }

  @Test func 바뀐_것만_커밋하고_잠금과_임시_파일은_뺀다() async throws {
    let place = TempPlace()
    let (link, bare) = try await connected(place)
    let again = await DataRepo.sync(place.data, link: link, token: nil, message: "켤 때", git: git)
    #expect(again.commit == nil)
    #expect(again.pushed)

    try place.write("library/concepts/physics/a.2/newtons-second-law/concept.yaml", "kind: \"concept\"\n")
    try place.write("meta/.lock", "123\n")
    try place.write("library/concepts/physics/a.2/newtons-second-law/.page.yaml.tmp-ab12cd34", "쓰는 중")
    try place.write("sources/.incoming-20261018-00000000/original.pdf", "넣는 중")
    let out = await DataRepo.sync(place.data, link: link, token: nil, message: DataRepo.message(["학습 페이지 만들기", "코멘트"]), git: git)
    #expect(out.error == nil)
    #expect(out.commit != nil && out.commit == out.head)
    #expect(try await run(["--git-dir", bare.path, "rev-parse", "main"], in: place.root) == out.head)
    let files = try await tracked(place, in: bare)
    #expect(files.contains("library/concepts/physics/a.2/newtons-second-law/concept.yaml"))
    #expect(!files.contains("meta/.lock"))
    #expect(!files.contains { $0.contains(".tmp-") || $0.contains(".incoming-") })
    #expect(try await run(["log", "-1", "--format=%B"], in: place.data.url) == "학습 페이지 만들기 외 1\n\n- 코멘트")
  }

  @Test func 원본_자료는_리포에_넣지_않고_이미_들어간_것은_리포에서만_뺀다() async throws {
    let place = TempPlace()
    let (link, bare) = try await connected(place)
    // 예전 판처럼 원본이 리포에 들어가 있다
    try place.write("sources/20261018-3fa2c1d0/original.pdf", "%PDF")
    try place.write("sources/20261018-3fa2c1d0/source.pdf", "%PDF")
    try place.write("sources/20261018-3fa2c1d0/meta.yaml", "kind: \"source\"\n")
    try await run(["add", "-f", "sources"], in: place.data.url)
    try await run(["commit", "-q", "-m", "옛 판"], in: place.data.url)

    let out = await DataRepo.sync(place.data, link: link, token: nil, message: "원본 빼기", git: git)
    #expect(out.error == nil)
    let files = try await tracked(place, in: bare)
    #expect(files.contains("sources/20261018-3fa2c1d0/meta.yaml"))
    #expect(!files.contains { $0.hasSuffix("original.pdf") || $0.hasSuffix("source.pdf") })
    // 로컬 파일은 남는다 (자료 버킷에 올린다)
    #expect(FileOps.exists(place.data.url.appending(path: "sources/20261018-3fa2c1d0/original.pdf")))
  }

  @Test func 올리지_못해도_커밋은_남고_다음에_함께_올라간다() async throws {
    let place = TempPlace()
    let (link, bare) = try await connected(place)
    let moved = place.root.appending(path: "moved.git")
    try FileManager.default.moveItem(at: bare, to: moved)
    try place.write("learner/comments.jsonl", "{\"id\":\"c1\"}\n")
    let failed = await DataRepo.sync(place.data, link: link, token: nil, message: "코멘트", git: git)
    #expect(failed.commit != nil)
    #expect(!failed.pushed)
    #expect(failed.error != nil)

    try FileManager.default.moveItem(at: moved, to: bare)
    let ok = await DataRepo.sync(place.data, link: link, token: nil, message: "켤 때", git: git)
    #expect(ok.commit == nil)
    #expect(ok.pushed)
    #expect(try await run(["--git-dir", bare.path, "rev-list", "--count", "main"], in: place.root) == "2")
  }

  @Test func 백MB_이상인_파일은_빼고_빼낸_목록을_알린다() async throws {
    let place = TempPlace()
    let (link, bare) = try await connected(place)
    let big = "sources/20261018-3fa2c1d0/original [lab*].pptx"
    try place.write(big, "")
    // 성긴 파일이라 디스크를 쓰지 않는다
    let handle = try FileHandle(forWritingTo: place.data.url.appending(path: big))
    try handle.truncate(atOffset: UInt64(DataRepo.sizeLimit))
    try handle.close()
    try place.write("sources/20261018-3fa2c1d0/meta.yaml", "kind: \"source\"\n")

    let out = await DataRepo.sync(place.data, link: link, token: nil, message: "자료 넣기", git: git)
    #expect(out.error == nil)
    #expect(out.excluded == [big])
    let files = try await tracked(place, in: bare)
    #expect(files.contains("sources/20261018-3fa2c1d0/meta.yaml"))
    #expect(!files.contains(big))
  }

  // MARK: - 켤 때 받기

  @Test func 켤_때_원격이_앞서_있으면_받고_갈라졌으면_올리지_않는다() async throws {
    let place = TempPlace()
    let (link, bare) = try await connected(place)
    #expect(await DataRepo.pull(place.data, link: link, token: nil, git: git) == .same)

    // 다른 곳(관리자)이 고쳐 올렸다
    let admin = place.root.appending(path: "admin")
    try await run(["clone", "-q", bare.path, admin.path], in: place.root)
    try FileOps.makeDirectory(admin.appending(path: "library"))
    try "kind: \"glossary\"\n".write(to: admin.appending(path: "library/glossary.yaml"), atomically: true, encoding: .utf8)
    try await run(["-c", "user.name=관리자", "-c", "user.email=a@invalid", "add", "-A"], in: admin)
    try await run(["-c", "user.name=관리자", "-c", "user.email=a@invalid", "commit", "-q", "-m", "용어 고침"], in: admin)
    try await run(["push", "-q", "origin", "HEAD"], in: admin)

    #expect(await DataRepo.pull(place.data, link: link, token: nil, git: git) == .pulled)
    #expect(FileOps.exists(place.data.url.appending(path: "library/glossary.yaml")))

    // 이번에는 양쪽이 따로 커밋해 갈라졌다
    try "kind: \"glossary\"\nv: 2\n".write(to: admin.appending(path: "library/glossary.yaml"), atomically: true, encoding: .utf8)
    try await run(["-c", "user.name=관리자", "-c", "user.email=a@invalid", "commit", "-q", "-am", "또 고침"], in: admin)
    try await run(["push", "-q", "origin", "HEAD"], in: admin)
    try place.write("learner/comments.jsonl", "{\"id\":\"c1\"}\n")
    let local = await DataRepo.sync(place.data, link: link, token: nil, message: "코멘트", git: git)
    #expect(local.commit != nil)
    #expect(!local.pushed)
    #expect(local.error == DataRepo.diverged)
    #expect(await DataRepo.pull(place.data, link: link, token: nil, git: git) == .diverged)
  }

  @Test func 뺄_파일의_줄은_그_경로_하나만_가리키고_주소는_끝의_꼴을_가리지_않는다() {
    for path in ["sources/a/original [1].pdf", "x*y?z", "끝에 빈칸 ", "a\\b"] {
      #expect(DataRepo.unpattern(DataRepo.pattern(path)) == path)
    }
    #expect(DataRepo.pattern("a/b [1].pdf") == "/a/b \\[1].pdf")
    #expect(DataRepo.message([]) == "데이터 폴더")
    #expect(DataRepo.message(["코멘트"]) == "코멘트")
    #expect(RepoLink.same("https://github.com/Example/jindesk-data.git", "https://github.com/example/jindesk-data/"))
    #expect(!RepoLink.same("https://github.com/example/jindesk-data", "https://github.com/example/jindesk-data-dev"))
  }
}
