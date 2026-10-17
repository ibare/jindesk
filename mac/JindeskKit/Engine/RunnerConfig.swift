// 작업을 실행할 때 쓰는 설정. 토큰은 키체인에서만 읽는다 (.env 는 쓰지 않는다. 데이터 폴더를 통째로 백업하기 때문이다).
// 토큰은 자식 프로세스에만 넘기고 기록이나 화면에 싣지 않는다.
import Foundation

public enum Effort: String, CaseIterable, Sendable, Codable {
  case low, medium, high, xhigh, max
}

public struct ToolPaths: Sendable, Equatable {
  public var claude: String?
  public var soffice: String?

  public init(claude: String? = nil, soffice: String? = nil) {
    self.claude = claude
    self.soffice = soffice
  }

  public init(_ found: [String: String]) {
    self.init(claude: found["claude"], soffice: found["soffice"])
  }

  public func requireClaude() throws -> String {
    guard let claude else { throw RequestError("claude 를 찾지 못했습니다. 관리자 설정에서 위치를 지정하세요.") }
    return claude
  }
}

public struct RunnerConfig: Sendable {
  public var claudeToken: String
  public var model: String
  public var effort: Effort
  public var maxTurns: Int
  public var maxBudgetUSD: Double
  // 에이전트 실행 한 번의 상한. 맥이 잠든 시간은 세지 않는다.
  public var timeout: Duration
  public var tools: ToolPaths
  // 외부 호출 검사 훅 실행 파일
  public var guardHelper: String
  // 작업별 지침 (앱 번들의 jobs/)
  public var instructions: InstructionSource
  // 수식 검사에 쓰는 렌더러의 KaTeX (앱 번들의 renderer/katex/katex.min.js). 없으면 수식 검사를 건너뛴다.
  public var katex: URL?
  // 자식 프로세스의 기본 환경 (자격 증명 변수를 뺀 앱 환경 + PATH + 로캘)
  public var baseEnvironment: [String: String]
  // 에이전트 출력에서 계정 사용량을 읽을 때마다 부른다. 작업 관리자가 작업을 시작할 때 넣는다.
  public var onUsage: (@Sendable (UsageReading) -> Void)?

  public init(
    claudeToken: String, model: String = RunnerConfig.defaultModel, effort: Effort = .high, maxTurns: Int = 400, maxBudgetUSD: Double = 30,
    timeout: Duration = .seconds(3600), tools: ToolPaths, guardHelper: String, instructions: InstructionSource,
    katex: URL? = nil, baseEnvironment: [String: String]
  ) {
    self.claudeToken = claudeToken
    self.model = model
    self.effort = effort
    self.maxTurns = maxTurns
    self.maxBudgetUSD = maxBudgetUSD
    self.timeout = timeout
    self.tools = tools
    self.guardHelper = guardHelper
    self.instructions = instructions
    self.katex = katex
    self.baseEnvironment = baseEnvironment
  }

  public static let defaultModel = "claude-opus-5-5"

  public var timeoutMinutes: Double { Double(timeout.components.seconds) / 60 }
}

// 관리자 설정. 앱 설정(UserDefaults)에 둔다. 학생 화면에는 보이지 않는다. 비어 있는 값은 기본값을 쓴다.
public struct AdminSettings: Sendable, Equatable {
  public var model: String?
  public var effort: Effort?
  public var maxTurns: Int?
  public var maxBudgetUSD: Double?
  public var timeoutMinutes: Double?
  // 5시간 사용량이 이 값(%) 이상이면 새 작업을 미룬다. 0 이면 미루지 않는다.
  public var holdAtPercent: Int?
  // 대기열마다 함께 도는 수 (자료, 대화)
  public var laneLimits: [String: Int]
  // 찾은 위치 대신 쓸 claude 경로
  public var claudePath: String?

  public init(
    model: String? = nil, effort: Effort? = nil, maxTurns: Int? = nil, maxBudgetUSD: Double? = nil, timeoutMinutes: Double? = nil,
    holdAtPercent: Int? = nil, laneLimits: [String: Int] = [:], claudePath: String? = nil
  ) {
    self.model = model
    self.effort = effort
    self.maxTurns = maxTurns
    self.maxBudgetUSD = maxBudgetUSD
    self.timeoutMinutes = timeoutMinutes
    self.holdAtPercent = holdAtPercent
    self.laneLimits = laneLimits
    self.claudePath = claudePath
  }

  public static let defaults = (effort: Effort.high, maxTurns: 400, maxBudgetUSD: 30.0, timeoutMinutes: 60.0, holdAtPercent: 90)

  // 실제로 쓸 값
  public var resolvedHoldAtPercent: Int? {
    let v = holdAtPercent ?? Self.defaults.holdAtPercent
    return v > 0 ? v : nil
  }

  public func limit(_ lane: JobLane) -> Int { laneLimits[lane.rawValue] ?? lane.defaultLimit }

  static let keys = (
    model: "admin.model", effort: "admin.effort", maxTurns: "admin.maxTurns", budget: "admin.maxBudgetUSD", timeout: "admin.timeoutMinutes",
    hold: "admin.holdAtPercent", lanes: "admin.laneLimits", claude: "admin.claudePath"
  )

  public static func load(_ defaults: UserDefaults = .standard) -> AdminSettings {
    AdminSettings(
      model: defaults.string(forKey: keys.model)?.nilIfBlank,
      effort: defaults.string(forKey: keys.effort).flatMap(Effort.init(rawValue:)),
      maxTurns: defaults.object(forKey: keys.maxTurns) as? Int,
      maxBudgetUSD: defaults.object(forKey: keys.budget) as? Double,
      timeoutMinutes: defaults.object(forKey: keys.timeout) as? Double,
      holdAtPercent: defaults.object(forKey: keys.hold) as? Int,
      laneLimits: defaults.dictionary(forKey: keys.lanes) as? [String: Int] ?? [:],
      claudePath: defaults.string(forKey: keys.claude)?.nilIfBlank
    )
  }

  public func save(_ defaults: UserDefaults = .standard) {
    defaults.set(model, forKey: Self.keys.model)
    defaults.set(effort?.rawValue, forKey: Self.keys.effort)
    defaults.set(maxTurns, forKey: Self.keys.maxTurns)
    defaults.set(maxBudgetUSD, forKey: Self.keys.budget)
    defaults.set(timeoutMinutes, forKey: Self.keys.timeout)
    defaults.set(holdAtPercent, forKey: Self.keys.hold)
    defaults.set(laneLimits.isEmpty ? nil : laneLimits, forKey: Self.keys.lanes)
    defaults.set(claudePath, forKey: Self.keys.claude)
  }
}

public enum ConfigLoader {
  public struct Missing: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
  }

  // 에이전트를 띄우지 않는 작업(자료 넣기)의 설정. 토큰과 claude 가 없어도 된다.
  public static func loadForRunner(settings: AdminSettings, guardHelper: String, instructions: InstructionSource) async -> RunnerConfig {
    var found = ToolPaths(await ToolLocator.locateAll())
    if let path = settings.claudePath { found.claude = path }
    let base = ChildEnvironment.base(toolDirectories: ToolLocator.commonDirectories())
    return RunnerConfig(claudeToken: "", tools: found, guardHelper: guardHelper, instructions: instructions, baseEnvironment: base)
  }

  // 작업을 넣기 직전에 부른다. 토큰이 없거나 claude 가 너무 오래됐으면 작업을 시작하지 않는다.
  public static func load(settings: AdminSettings, data: DataFolder, guardHelper: String, instructions: InstructionSource, katex: URL? = nil) async throws
    -> RunnerConfig
  {
    guard let token = try? ClaudeToken.read() else {
      throw Missing(message: "Claude 토큰이 키체인에 없습니다. 관리자 설정에서 넣거나 SETUP.md 의 방법으로 넣으세요.")
    }

    var found = ToolPaths(await ToolLocator.locateAll())
    if let path = settings.claudePath { found.claude = path }
    let toolDirs = [found.claude].compactMap { $0.map { ($0 as NSString).deletingLastPathComponent } }
    let base = ChildEnvironment.base(toolDirectories: toolDirs + ToolLocator.commonDirectories())

    // 외부 호출 검사 훅은 실패하면 막도록(onFailure) 설정한다. 그 설정을 모르는 claude 에서는 훅이 실패해도 호출이 나가므로 쓰지 않는다.
    // claude 는 앱이 올려 주지 않는다. 네이티브 설치는 claude 가 스스로 업데이트한다.
    if let claude = found.claude,
      let result = try? await ChildProcess.run(ChildSpec(executable: claude, arguments: ["--version"], environment: base), timeout: .seconds(15)),
      let version = ClaudeVersion.parse(result.stdoutText), !ClaudeVersion.atLeast(version, ExternalGuard.minimumClaudeVersion)
    {
      throw Missing(
        message:
          "claude \(ClaudeVersion.text(version)) 는 너무 오래됐습니다. 터미널에서 claude update 로 \(ClaudeVersion.text(ExternalGuard.minimumClaudeVersion)) 이상으로 올리세요."
      )
    }

    let d = AdminSettings.defaults
    return RunnerConfig(
      claudeToken: token,
      model: settings.model ?? RunnerConfig.defaultModel,
      effort: settings.effort ?? d.effort,
      maxTurns: settings.maxTurns ?? d.maxTurns,
      maxBudgetUSD: settings.maxBudgetUSD ?? d.maxBudgetUSD,
      timeout: .seconds((settings.timeoutMinutes ?? d.timeoutMinutes) * 60),
      tools: found,
      guardHelper: guardHelper,
      instructions: instructions,
      katex: katex,
      baseEnvironment: base
    )
  }
}
