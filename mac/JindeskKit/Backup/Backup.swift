// 백업 만들기 (DATA.md 의 "백업과 되살리기").
// 잠금을 잡고(작업이 돌고 있으면 끝날 때까지 기다린다) 데이터 폴더를 ditto 로 zip 으로 만든다.
import Foundation

public enum Backup {
  public static func fileName(_ date: Date = Date()) -> String {
    "Jindesk-백업-\(JobID.stamp(date)).zip"
  }

  // 데이터 폴더의 zip 을 directory 에 만든다. 잠금을 기다리기 시작하면 onWait 를 부른다.
  public static func make(_ data: DataFolder, into directory: URL, now: Date = Date(), onWait: @Sendable () async -> Void = {}) async throws -> URL {
    let lock = DataLock(data)
    try await lock.acquire(onWait: onWait)
    defer { lock.release() }
    var target = directory.appending(path: fileName(now))
    // 같은 분에 두 번 만들면 이름 끝에 번호를 붙인다
    var n = 2
    while FileOps.exists(target) {
      target = directory.appending(path: fileName(now).replacingOccurrences(of: ".zip", with: "-\(n).zip"))
      n += 1
    }
    try await zip(data.url, to: target)
    return target
  }

  // 폴더를 zip 으로 만든다 (맨 위에 폴더 이름이 들어간다). 같은 폴더의 임시 이름으로 만든 뒤 이름을 바꾼다.
  public static func zip(_ folder: URL, to zipURL: URL) async throws {
    try FileOps.makeDirectory(zipURL.deletingLastPathComponent())
    let temp = zipURL.deletingLastPathComponent().appending(path: ".\(zipURL.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))")
    let result = try await ChildProcess.run(
      ChildSpec(
        executable: "/usr/bin/ditto", arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, temp.path],
        environment: ChildEnvironment.base(toolDirectories: [])))
    guard result.succeeded else {
      FileOps.remove(temp)
      throw ToolError("백업 zip 을 만들지 못했습니다: \(result.summary)")
    }
    FileOps.remove(zipURL)
    try FileManager.default.moveItem(at: temp, to: zipURL)
  }

  // zip 을 directory 에 풀고, 풀린 맨 위 폴더를 돌려준다
  public static func unzip(_ zipURL: URL, into directory: URL) async throws -> URL {
    try FileOps.makeDirectory(directory)
    let result = try await ChildProcess.run(
      ChildSpec(executable: "/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, directory.path], environment: ChildEnvironment.base(toolDirectories: [])))
    guard result.succeeded else { throw ToolError("zip 을 풀지 못했습니다: \(result.summary)") }
    let top = FileOps.list(directory).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
    guard top.count == 1, FileOps.isDirectory(directory.appending(path: top[0])) else {
      throw ToolError("zip 맨 위에 폴더 하나가 있어야 합니다: \(zipURL.lastPathComponent)")
    }
    return directory.appending(path: top[0])
  }

  // 이름이 prefix 로 시작하는 zip 가운데 최근 keep 개만 남긴다
  public static func prune(_ directory: URL, prefix: String, keep: Int) {
    let files = FileOps.list(directory).filter { $0.hasPrefix(prefix) && $0.hasSuffix(".zip") }.map { directory.appending(path: $0) }
    let dated = files.map { url in (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
    for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { FileOps.remove(url) }
  }
}
