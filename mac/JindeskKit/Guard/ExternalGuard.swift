// 외부 호출 검사 훅의 설정과 실행 본체.
// 훅 실행 파일(jindesk-guard)과 기록 파일은 에이전트 작업 디렉터리 밖에 있어 에이전트가 고칠 수 없다.
import Foundation

public struct ExternalGuard: Sendable {
  // 허용·차단된 모든 외부 호출 기록 (work/<작업 id>/external.jsonl)
  public let logFile: String

  public init(logFile: String) {
    self.logFile = logFile
  }

  public static func prepare(directory: String) throws -> ExternalGuard {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    return ExternalGuard(logFile: (directory as NSString).appendingPathComponent("external.jsonl"))
  }

  // claude --settings 의 hooks 항목.
  // onFailure: "block" 이면 훅이 실패하거나 아예 뜨지 못해도(실행 파일이 없는 등) 그 호출을 막는다.
  // 없으면 Claude Code 는 실행하지 못한 훅을 막지 않는 오류로 보고 호출을 그대로 내보낸다. (Claude Code 2.1.295 이상)
  public func hooks(helperPath: String) -> JSONValue {
    let command = [helperPath, logFile].map(shellQuote).joined(separator: " ")
    return .object([
      "PreToolUse": .array([
        .object([
          "matcher": .string("WebSearch|WebFetch"),
          "hooks": .array([.object(["type": .string("command"), "command": .string(command), "onFailure": .string("block")])]),
        ])
      ])
    ])
  }

  // onFailure 를 아는 Claude Code 의 가장 낮은 버전
  public static let minimumClaudeVersion = [2, 1, 295]
}

// 훅은 셸 명령 문자열로 실행된다. 경로에 공백이나 따옴표가 있어도 깨지지 않게 작은따옴표로 감싼다.
public func shellQuote(_ s: String) -> String {
  "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// jindesk-guard 실행 파일의 본체. 종료 코드 2 는 호출을 막고 stderr 를 에이전트에게 돌려준다.
public enum GuardHook {
  public struct Outcome: Equatable, Sendable {
    public let exitCode: Int32
    public let message: String?
  }

  struct LogEntry: Encodable {
    let at: String
    let tool: String?
    let input: JSONValue?
    let blocked: String?

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(at, forKey: .at)
      try c.encode(tool, forKey: .tool)
      try c.encode(input, forKey: .input)
      // 통과한 호출도 blocked: null 로 남긴다
      try c.encode(blocked, forKey: .blocked)
    }

    enum CodingKeys: String, CodingKey { case at, tool, input, blocked }
  }

  public static func run(logFile: String?, input: Data, now: Date = Date()) -> Outcome {
    do {
      let hookInput = input.isEmpty ? JSONValue.object([:]) : try JSONValue.parse(input)
      let tool = hookInput["tool_name"]?.stringValue
      let toolInput = hookInput["tool_input"]
      let reason = ExternalCallCheck.blockReason(tool: tool ?? "", input: toolInput)

      if let logFile {
        let entry = LogEntry(at: Clock.isoLocal(now), tool: tool, input: toolInput, blocked: reason)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        try FileOps.appendLine(String(decoding: try encoder.encode(entry), as: UTF8.self), to: URL(fileURLWithPath: logFile))
      }
      if let reason { return Outcome(exitCode: 2, message: reason) }
      return Outcome(exitCode: 0, message: nil)
    } catch {
      // 검사하지 못하면 막는다
      return Outcome(exitCode: 2, message: "외부 호출 검사 실패: \(error.localizedDescription)")
    }
  }
}
