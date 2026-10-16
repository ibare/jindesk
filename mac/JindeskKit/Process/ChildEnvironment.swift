import Foundation

// 자식 프로세스에 넘길 환경 변수.
// Dock 이나 Finder 에서 띄운 앱은 셸의 PATH 와 로캘을 물려받지 않으므로 여기서 채운다.
public enum ChildEnvironment {
  // Claude/Anthropic 관련 변수(API 키가 토큰보다 우선하는 문제 포함)와 GitHub 자격 증명은 어떤 자식에게도 그대로 넘기지 않는다.
  static let blockedPrefixes = ["CLAUDE", "ANTHROPIC", "GH_", "GITHUB_"]

  public static func base(
    from environment: [String: String] = ProcessInfo.processInfo.environment,
    toolDirectories: [String]
  ) -> [String: String] {
    var env = environment.filter { key, _ in !blockedPrefixes.contains { key.hasPrefix($0) } }

    var path: [String] = []
    for dir in toolDirectories + (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    where !dir.isEmpty && !path.contains(dir) {
      path.append(dir)
    }
    env["PATH"] = path.joined(separator: ":")

    // 로캘이 없으면 도구들이 한글 파일 이름을 제대로 다루지 못한다.
    if env["LC_ALL"] == nil && env["LC_CTYPE"] == nil && env["LANG"] == nil {
      env["LANG"] = "en_US.UTF-8"
    }
    return env
  }

  // 에이전트(claude -p)용 환경. 모델 토큰 외의 자격 증명은 넣지 않는다.
  // 설정 폴더를 작업마다 따로 두어 ~/.claude 의 지침, 메모리, 설정이 보이지 않게 하고, 자동 메모리도 끈다.
  public static func agent(base: [String: String], token: String, configDirectory: String) -> [String: String] {
    var env = base.filter { key, _ in !blockedPrefixes.contains { key.hasPrefix($0) } }
    env["CLAUDE_CODE_OAUTH_TOKEN"] = token
    env["CLAUDE_CONFIG_DIR"] = configDirectory
    env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
    return env
  }
}
