import Foundation

// 작업별 지침이 있는 폴더(<종류>/INSTRUCTIONS.md). 지침은 앱의 일부라 리포의 jobs/ 에 두고,
// 빌드할 때 앱 번들(Contents/Resources/jobs)에 복사한다. 그때 지침마다 마지막으로 바꾼 커밋과
// 미커밋 변경 여부를 build.json 에 남긴다 (mac/project.yml 의 "작업 지침 넣기").
public struct InstructionSource: Sendable, Equatable {
  public let directory: URL

  public init(_ directory: URL) {
    self.directory = directory
  }

  public struct Build: Codable, Sendable, Equatable {
    public let commit: String
    public let dirty: Bool
  }

  public func file(_ kind: JobKind) -> URL {
    directory.appending(path: kind.rawValue).appending(path: "INSTRUCTIONS.md")
  }

  // 지침이 있어야 하는데 없는 종류
  public func missing(_ kinds: [JobKind] = JobKind.withInstructions) -> [JobKind] {
    kinds.filter { !FileManager.default.fileExists(atPath: file($0).path) }
  }

  // build.json 이 없으면(리포의 jobs/ 를 바로 가리킬 때) 커밋을 모르는 것으로 둔다
  public func build(_ kind: JobKind) -> Build {
    guard let data = try? Data(contentsOf: directory.appending(path: "build.json")),
      let all = try? JSONDecoder().decode([String: Build].self, from: data), let build = all[kind.rawValue]
    else { return Build(commit: "uncommitted", dirty: true) }
    return build
  }
}

// 작업별 지침 파일을 읽고, 기록에 남길 버전과 커밋을 구한다.
public struct Instructions: Sendable, Equatable {
  public let text: String
  public let version: String
  // 지침 파일을 마지막으로 바꾼 커밋. 한 번도 커밋하지 않았으면 'uncommitted'
  public let commit: String
  public let dirty: Bool

  public init(text: String, version: String, commit: String, dirty: Bool) {
    self.text = text
    self.version = version
    self.commit = commit
    self.dirty = dirty
  }

  // 지침 위쪽의 "지침 버전: `0.1`". 지침을 바꾸면 이 값을 올린다.
  public static let versionLabel = "지침 버전"

  public static func read(_ source: InstructionSource, kind: JobKind) throws -> Instructions {
    let rel = "jobs/\(kind.rawValue)/INSTRUCTIONS.md"
    let text = try FileOps.read(source.file(kind))
    let pattern = try NSRegularExpression(pattern: "\(NSRegularExpression.escapedPattern(for: versionLabel)):\\s*`([^`]+)`")
    guard let m = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 1), in: text) else {
      throw ToolError("\(rel) 에서 \(versionLabel)을 찾을 수 없습니다")
    }
    let build = source.build(kind)
    return Instructions(text: text, version: String(text[r]), commit: build.commit, dirty: build.dirty)
  }

  // 산출물의 provenance 에 넣는 모양: { kind, version, commit, dirty }
  public func provenance(_ kind: JobKind) -> YAMLMap {
    ["kind": .string(kind.rawValue), "version": .string(version), "commit": .string(commit), "dirty": .bool(dirty)]
  }
}
