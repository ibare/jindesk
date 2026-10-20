// 에이전트 작업이 함께 쓰는 것: 작업 공간 배치, 지침 고정, 에이전트 한 번 돌리기, 고쳐 쓰기 요청, 읽은 파일 세기.
import Foundation

// 작업 공간 하나: work/<작업 id>/[<sub>/]workspace/{input,out,work}
public struct AgentDirs: Sendable {
  public let run: URL
  public let workspace: URL
  // 이 실행 전용 Claude 설정 폴더 (~/.claude 와 나눈다)
  public let configDir: URL
  public let input: URL
  public let out: URL
  public let work: URL

  public init(_ folders: AppFolders, _ id: String, sub: String? = nil) {
    var run = folders.workDir(id)
    if let sub { run = run.appending(path: sub) }
    self.run = run
    workspace = run.appending(path: "workspace")
    configDir = run.appending(path: "claude-config")
    input = workspace.appending(path: "input")
    out = workspace.appending(path: "out")
    work = workspace.appending(path: "work")
  }

  public func events(_ name: String) -> URL { run.appending(path: "events-\(name).jsonl") }

  // 다시 도는 작업이면 이전 작업 공간을 지우고 새로 만든다
  func make() throws {
    FileOps.remove(workspace)
    for d in [configDir, input, out, work] { try FileOps.makeDirectory(d) }
  }
}

enum AgentStep {
  // 지침을 작업 폴더에 고정한다. 도는 중에 지침 파일이 바뀌어도 영향이 없다.
  static func fixInstructions(_ kind: JobKind, _ ctx: JobContext, into dir: URL) async throws -> (Instructions, URL) {
    let instructions = try Instructions.read(ctx.config.instructions, kind: kind)
    let file = dir.appending(path: "instructions.md")
    try FileOps.write(instructions.text, to: file)
    let commit = instructions.commit == "uncommitted" ? "커밋 전" : String(instructions.commit.prefix(7))
    await ctx.log(.info, "\(kind.label) 지침 \(instructions.version) (\(commit)\(instructions.dirty ? ", 미커밋 변경 있음" : ""))")
    return (instructions, file)
  }

  static func options(_ ctx: JobContext, _ dirs: AgentDirs, instructions: URL, prompt: String, events: String) -> AgentOptions {
    let onTurns: @Sendable (Int) async -> Void = { await ctx.setLiveTurns($0) }
    let onEvent: @Sendable (LogKind, String) async -> Void = { await ctx.log($0, $1) }
    return AgentOptions(
      config: ctx.config, workspace: dirs.workspace, configDir: dirs.configDir, systemPromptFile: instructions, eventsFile: dirs.events(events),
      prompt: prompt, onEvent: onEvent, onTurns: onTurns)
  }

  // 한 번 돌린다. 취소면 CancellationError, 실패면 ToolError 를 던진다.
  static func run(_ options: AgentOptions, _ ctx: JobContext, label: String) async throws -> AgentResult {
    let result = await AgentRunner.run(options)
    await ctx.addUsage(result)
    if result.status == .cancelled { throw CancellationError() }
    guard result.status == .ok else { throw ToolError("\(label): \(result.message ?? result.status.rawValue)") }
    return result
  }

  // 검사에서 틀린 것을 알려 같은 세션을 이어 한 번 고쳐 쓰게 한다
  static func fix(_ options: AgentOptions, session: String?, problems: [String], ctx: JobContext, label: String, events: String) async throws {
    guard let session else { throw ToolError("\(label): 세션 id 가 없어 고쳐 쓰게 할 수 없습니다") }
    let prompt =
      "러너 검사에서 아래 문제가 나왔다. 지침대로 out/ 의 파일을 고쳐 다시 써라. 문제가 없는 부분은 그대로 둔다.\n\n"
      + problems.map { "- \($0)" }.joined(separator: "\n")
    var o = options.with(prompt: prompt, resume: (session, false), eventsFile: options.eventsFile.deletingLastPathComponent().appending(path: "events-\(events).jsonl"))
    o.onTurns = options.onTurns
    _ = try await run(o, ctx, label: "\(label) 고쳐 쓰기")
  }

  // 용어 어휘를 input/glossary.yaml 로 둔다. 아직 없으면 빈 어휘를 둔다 (지침이 늘 있는 파일로 가리킬 수 있게).
  // subject 를 주면 그 과목의 용어만 넣는다 (번역: 검사와 같은 용어)
  static func writeGlossary(_ data: DataFolder, into input: URL, subject: String? = nil) throws {
    let all = Glossary.load(data)
    let glossary = subject.map(all.of) ?? all
    let map: YAMLMap = ["kind": "glossary", "v": 1, "terms": .array(glossary.terms.map(\.yaml))]
    try FileOps.write(YAML.stringify(map), to: input.appending(path: "glossary.yaml"))
  }

  static func provenance(_ ctx: JobContext, _ kind: JobKind, _ instructions: Instructions) -> YAMLMap {
    ["job": .string(ctx.id), "instructions": .map(instructions.provenance(kind)), "model": .string(ctx.config.model)]
  }
}

// 이벤트 기록에서 에이전트가 Read 한 파일 (작업 공간 기준 상대 경로). 출처를 단 쪽을 실제로 읽었는지 볼 때 쓴다.
public enum EventCoverage {
  public static func readFiles(_ events: [URL], workspace: URL) -> Set<String> {
    let cwd = workspace.path
    var out: Set<String> = []
    for file in events {
      guard let text = FileOps.readIfExists(file) else { continue }
      for line in text.split(separator: "\n") {
        guard line.contains("\"tool_use\""), let event = try? JSONValue.parse(Data(line.utf8)), event["type"]?.stringValue == "assistant" else { continue }
        for item in event["message"]?["content"]?.arrayValue ?? [] where item["type"]?.stringValue == "tool_use" && item["name"]?.stringValue == "Read" {
          guard let path = item["input"]?["file_path"]?.stringValue else { continue }
          let rel = path.hasPrefix(cwd + "/") ? String(path.dropFirst(cwd.count + 1)) : path.hasPrefix("./") ? String(path.dropFirst(2)) : path
          out.insert(rel)
        }
      }
    }
    return out
  }
}

// 에이전트가 쓴 JSON 파일 읽기
enum AgentJSON {
  static func read(_ url: URL, label: String) -> Result<JSONValue, AgentOutputProblem> {
    guard let data = try? Data(contentsOf: url) else { return .failure(AgentOutputProblem("\(label) 를 쓰지 않았습니다")) }
    do {
      return .success(try JSONValue.parse(data))
    } catch {
      return .failure(AgentOutputProblem("\(label) 가 JSON 으로 읽히지 않습니다: \(error.localizedDescription)"))
    }
  }

  static func string(_ v: JSONValue?) -> String? { v?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }

  static func strings(_ v: JSONValue?) -> [String] {
    (v?.arrayValue ?? []).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
  }

  static func ints(_ v: JSONValue?) -> [Int] {
    (v?.arrayValue ?? []).compactMap { $0.numberValue.flatMap { $0.rounded() == $0 ? Int($0) : nil } }
  }

  static func numbers(_ v: JSONValue?) -> [Double] {
    (v?.arrayValue ?? []).compactMap(\.numberValue)
  }

  static func symbols(_ v: JSONValue?) -> [SymbolDef] {
    (v?.arrayValue ?? []).compactMap { s in
      guard let symbol = string(s["symbol"]), let meaning = string(s["meaning"]) else { return nil }
      return SymbolDef(symbol: symbol, meaning: meaning, unit: string(s["unit"]))
    }
  }
}

struct AgentOutputProblem: Error, Sendable {
  let message: String
  init(_ message: String) { self.message = message }
}
