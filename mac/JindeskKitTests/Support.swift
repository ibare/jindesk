import Foundation
import Testing
@testable import JindeskKit

// 이 리포 (mac/JindeskKitTests/ 의 두 단계 위)
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
// 이 리포의 지침. 빌드 기록(build.json)이 없으므로 커밋은 'uncommitted' 로 읽힌다.
let repoInstructions = InstructionSource(repoRoot.appending(path: "jobs"))
let testApp = AppVersion(app: "0.1.0", build: "1")

// 임시 데이터 폴더와 앱 지원 폴더. 시험이 끝나도 지우지 않는다 (임시 폴더라 시스템이 치운다).
struct TempPlace {
  let root: URL
  let data: DataFolder
  let folders: AppFolders

  init() {
    root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "jindesk-test-\(UUID().uuidString)")
    data = DataFolder(root.appending(path: "Jindesk"))
    folders = AppFolders(support: root.appending(path: "support"), cache: root.appending(path: "cache"))
    try? folders.prepare()
  }

  // 데이터 폴더 안에 파일을 쓴다
  func write(_ rel: String, _ text: String) throws {
    let url = data.url.appending(path: rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  func read(_ rel: String) throws -> String {
    try String(contentsOf: data.url.appending(path: rel), encoding: .utf8)
  }
}

let testConfig = RunnerConfig(claudeToken: "x", tools: ToolPaths(), guardHelper: "/x", instructions: repoInstructions, baseEnvironment: [:])
