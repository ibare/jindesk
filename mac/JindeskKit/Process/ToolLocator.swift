import Foundation

// claude 와 soffice(LibreOffice) 의 위치를 찾는다. 앱은 셸의 PATH 를 물려받지 않으므로 흔한 설치 위치와 로그인 셸의 PATH 를 함께 본다.
public enum ToolLocator {
  public static let tools = ["claude", "soffice"]

  public static func commonDirectories(home: String = NSHomeDirectory()) -> [String] {
    [
      "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
      "/Applications/LibreOffice.app/Contents/MacOS",
    ]
  }

  public static func find(_ name: String, in directories: [String]) -> String? {
    for dir in directories {
      let candidate = (dir as NSString).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }

  // 로그인 셸이 쓰는 PATH. 셸 설정이 멈춰도 앱이 붙잡히지 않도록 상한을 둔다.
  public static func loginShellPath(timeout: TimeInterval = 5) async -> [String] {
    guard let shell = loginShell() else { return [] }
    let spec = ChildSpec(
      executable: shell,
      arguments: ["-l", "-c", "printf %s \"$PATH\""],
      environment: ["HOME": NSHomeDirectory(), "USER": NSUserName(), "TERM": "dumb"],
      stdout: .collect
    )
    guard let child = try? ChildProcess.spawn(spec) else { return [] }
    let timer = Task {
      try await Task.sleep(for: .seconds(timeout))
      child.signalGroup(SIGKILL)
    }
    let result = await child.wait()
    timer.cancel()
    guard result.succeeded else { return [] }
    return result.stdoutText.split(separator: ":").map(String.init).filter { !$0.isEmpty }
  }

  static func loginShell() -> String? {
    guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
    let path = String(cString: shell)
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
  }

  // 흔한 위치를 먼저 보고, 없을 때만 로그인 셸의 PATH 를 본다.
  public static func locateAll() async -> [String: String] {
    var found: [String: String] = [:]
    let common = commonDirectories()
    for tool in tools { found[tool] = find(tool, in: common) }
    if found.count < tools.count {
      let shellPath = await loginShellPath()
      for tool in tools where found[tool] == nil { found[tool] = find(tool, in: shellPath) }
    }
    return found
  }
}
