import Darwin
import Foundation

// 파일 다루기. 데이터 폴더의 파일은 원자적으로 쓰고(임시 파일 → fsync → 이름 바꾸기),
// JSONL 은 줄 단위로 덧붙인 뒤 fsync 한다 (DATA.md 의 쓰기 규칙).
public enum FileOps {
  public struct AlreadyExists: LocalizedError, Sendable {
    public let path: String
    public var errorDescription: String? { "이미 있는 파일이라 쓰지 않았습니다: \(path)" }
  }

  public static func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  // 작업 공간처럼 원자적일 필요가 없는 곳에 쓴다
  public static func write(_ text: String, to url: URL) throws {
    try write(Data(text.utf8), to: url)
  }

  public static func write(_ data: Data, to url: URL) throws {
    try makeDirectory(url.deletingLastPathComponent())
    try data.write(to: url)
  }

  // 같은 폴더의 임시 파일에 쓰고 fsync 한 뒤 이름을 바꾼다. 쓰다가 꺼져도 원래 파일이나 새 파일 가운데 하나만 남는다.
  public static func writeAtomic(_ text: String, to url: URL) throws {
    try writeAtomic(Data(text.utf8), to: url)
  }

  public static func writeAtomic(_ data: Data, to url: URL) throws {
    let dir = url.deletingLastPathComponent()
    try makeDirectory(dir)
    let temp = dir.appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))")
    let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw posixError() }
    do {
      try writeAll(fd, data)
      guard fsync(fd) == 0 else { throw posixError() }
      close(fd)
    } catch {
      close(fd)
      unlink(temp.path)
      throw error
    }
    guard rename(temp.path, url.path) == 0 else {
      let error = posixError()
      unlink(temp.path)
      throw error
    }
  }

  // 있으면 실패한다. 기록 파일을 덮어쓰지 않기 위해 쓴다.
  public static func writeNew(_ text: String, to url: URL) throws {
    try writeNew(Data(text.utf8), to: url)
  }

  public static func writeNew(_ data: Data, to url: URL) throws {
    try makeDirectory(url.deletingLastPathComponent())
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
    if fd < 0 {
      if errno == EEXIST { throw AlreadyExists(path: url.path) }
      throw posixError()
    }
    defer { close(fd) }
    try writeAll(fd, data)
    guard fsync(fd) == 0 else { throw posixError() }
  }

  // 한 줄을 덧붙이고 fsync 한다. 줄 끝의 줄바꿈은 여기서 붙인다.
  public static func appendLine(_ line: String, to url: URL) throws {
    try makeDirectory(url.deletingLastPathComponent())
    let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw posixError() }
    defer { close(fd) }
    try writeAll(fd, Data((line + "\n").utf8))
    guard fsync(fd) == 0 else { throw posixError() }
  }

  static func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let n = Darwin.write(fd, base + offset, buffer.count - offset)
        if n > 0 {
          offset += n
        } else if n < 0 && errno == EINTR {
          continue
        } else {
          throw posixError()
        }
      }
    }
  }

  static func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }

  public static func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  public static func readIfExists(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  // 파일들의 수정 시각 (없는 파일은 -). 읽어 둔 것을 다시 읽어야 하는지 볼 때 쓴다
  public static func stamp(_ urls: [URL]) -> String {
    urls.map { url in
      var s = stat()
      guard stat(url.path, &s) == 0 else { return "-" }
      return "\(s.st_mtimespec.tv_sec).\(s.st_mtimespec.tv_nsec)"
    }.joined(separator: "|")
  }

  public static func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  public static func isDirectory(_ url: URL) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
  }

  public static func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  public static func move(_ from: URL, to: URL) throws {
    try makeDirectory(to.deletingLastPathComponent())
    try FileManager.default.moveItem(at: from, to: to)
  }

  // APFS 에서는 복제(clone)로 복사된다
  public static func copy(_ from: URL, to: URL) throws {
    try makeDirectory(to.deletingLastPathComponent())
    try FileManager.default.copyItem(at: from, to: to)
  }

  // 실제 경로 (심볼릭 링크를 따라간다). URL.resolvingSymlinksInPath 와 달리 /private 를 떼지 않는다.
  public static func realpath(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  // 아직 없는 경로도 있는 조상까지는 실제 경로로 바꾼다
  public static func resolvedPath(_ path: String) -> String {
    let standard = (path as NSString).standardizingPath
    if let real = realpath(standard) { return real }
    let parent = (standard as NSString).deletingLastPathComponent
    guard parent != standard else { return standard }
    return (resolvedPath(parent) as NSString).appendingPathComponent((standard as NSString).lastPathComponent)
  }

  // 폴더 안의 이름 (없으면 빈 목록)
  public static func list(_ url: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
  }

  // 폴더 아래의 모든 파일 (폴더 기준 상대 경로, 정렬). 숨김 파일도 넣는다.
  public static func files(under url: URL) -> [String] {
    guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    let base = url.standardizedFileURL.path
    var out: [String] = []
    for case let file as URL in walker {
      guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
      let path = file.standardizedFileURL.path
      out.append(path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path)
    }
    return out.sorted()
  }

  // "\n" 으로 나눈다. 끝이 줄바꿈이면 마지막에 빈 조각이 남는다.
  public static func lines(_ text: String) -> [Substring] {
    text.split(separator: "\n", omittingEmptySubsequences: false)
  }

  // UTF-16 단위로 자른다. 서로게이트 쌍은 쪼개지 않는다.
  public static func prefix(_ s: String, _ n: Int) -> String {
    if s.utf16.count <= n { return s }
    var index = s.utf16.index(s.utf16.startIndex, offsetBy: n)
    while index > s.startIndex, index.samePosition(in: s.unicodeScalars) == nil { index = s.utf16.index(before: index) }
    return String(s.unicodeScalars[..<index])
  }
}

// 덧붙이기만 하는 JSONL 파일 읽기. 마지막 줄이 깨져 있으면(쓰다 꺼짐) 그 줄만 버리고 경고한다.
public enum JSONLines {
  public struct Contents: Sendable {
    public let values: [JSONValue]
    // 버린 마지막 줄이 있었으면 그 설명
    public let warning: String?
  }

  public struct BrokenLine: LocalizedError, Sendable {
    public let file: String
    public let line: Int
    public var errorDescription: String? { "\(file) 의 \(line)번째 줄을 읽지 못했습니다" }
  }

  public static func read(_ url: URL) throws -> Contents {
    guard let text = FileOps.readIfExists(url) else { return Contents(values: [], warning: nil) }
    return try parse(text, name: url.path)
  }

  public static func parse(_ text: String, name: String) throws -> Contents {
    var lines = FileOps.lines(text)
    // 끝이 줄바꿈이면 마지막 조각은 비어 있다
    let complete = lines.last?.isEmpty == true
    if complete { lines.removeLast() }
    var values: [JSONValue] = []
    var warning: String?
    for (i, line) in lines.enumerated() {
      if line.isEmpty { continue }
      do {
        values.append(try JSONValue.parse(Data(line.utf8)))
      } catch {
        // 줄바꿈 없이 끝난 마지막 줄만 쓰다 꺼진 것으로 본다. 가운데 줄이 깨졌으면 오류다.
        if i == lines.count - 1 && !complete {
          warning = "\(name) 의 마지막 줄이 쓰다 만 상태라 버렸습니다"
        } else {
          throw BrokenLine(file: name, line: i + 1)
        }
      }
    }
    return Contents(values: values, warning: warning)
  }
}
