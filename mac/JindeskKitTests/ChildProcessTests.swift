import Foundation
import Testing
@testable import JindeskKit

private let env = ChildEnvironment.base(from: ["HOME": NSHomeDirectory()], toolDirectories: [])

private func sh(_ script: String, stdout: ChildOutput = .collect, stdin: ChildInput = .null, directory: String? = nil) -> ChildSpec {
  ChildSpec(executable: "/bin/sh", arguments: ["-c", script], environment: env, directory: directory, stdin: stdin, stdout: stdout)
}

@Suite struct ChildProcessTests {
  @Test func 출력과_종료_코드와_stderr를_받는다() async throws {
    let ok = try await ChildProcess.run(sh("printf '가나다'; printf '경고' >&2"))
    #expect(ok.succeeded)
    #expect(ok.stdoutText == "가나다")
    #expect(ok.stderr == "경고")

    let failed = try await ChildProcess.run(sh("echo 실패 >&2; exit 3"))
    #expect(failed.termination == .exited(3))
    #expect(failed.summary == "종료 코드 3: 실패")
  }

  @Test func 줄_단위로_빈_줄과_긴_줄과_끝의_줄바꿈_없는_줄까지_받는다() async throws {
    let long = String(repeating: "x", count: 300_000)
    let child = try ChildProcess.spawn(sh("printf 'a\\n\\n'; printf '%s\\n' \"$LONG\"; printf 'tail'", stdout: .lines).with(env: ["LONG": long]))
    var lines: [String] = []
    for await line in child.lines { lines.append(line) }
    let result = await child.wait()
    #expect(result.succeeded)
    #expect(lines == ["a", "", long, "tail"])
  }

  @Test func 표준_입력으로_데이터를_넘긴다() async throws {
    let result = try await ChildProcess.run(sh("cat", stdin: .data(Data("입력값".utf8))))
    #expect(result.stdoutText == "입력값")
  }

  @Test func 작업_디렉터리를_바꿔_띄운다() async throws {
    let result = try await ChildProcess.run(sh("pwd -P", directory: "/private/tmp"))
    #expect(result.stdoutText.trimmingCharacters(in: .newlines) == "/private/tmp")
  }

  @Test func 그룹에_신호를_보내면_하위_프로세스까지_끝난다() async throws {
    let child = try ChildProcess.spawn(sh("sleep 60 & sleep 60 & wait"))
    try await Task.sleep(for: .milliseconds(200))
    let started = Date()
    child.stop(grace: 2)
    let result = await child.wait()
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(result.termination == .signaled(SIGTERM))
    // 그룹에 남은 프로세스가 없다
    #expect(await groupGone(child.pid))
  }

  @Test func 리더가_끝난_뒤_파이프를_붙잡은_하위_프로세스는_잠시_뒤_정리한다() async throws {
    let child = try ChildProcess.spawn(sh("sleep 60 & echo 끝"))
    let started = Date()
    let result = await child.wait()
    let elapsed = Date().timeIntervalSince(started)
    #expect(result.succeeded)
    #expect(result.stdoutText == "끝\n")
    #expect(elapsed > 4 && elapsed < 9)
    #expect(await groupGone(child.pid))
  }

  @Test func 작업이_취소되면_그룹째_끝낸다() async throws {
    let spec = sh("sleep 60 & sleep 60 & wait")
    let task = Task { try await ChildProcess.run(spec) }
    try await Task.sleep(for: .milliseconds(200))
    task.cancel()
    let result = try await task.value
    #expect(result.termination == .signaled(SIGTERM))
  }

  @Test func 없는_실행_파일은_오류를_던진다() {
    #expect(throws: ChildProcessError.self) {
      try ChildProcess.spawn(ChildSpec(executable: "/없는/실행파일", environment: env))
    }
  }

  @Test func 한_자식의_출력을_다른_자식의_입력으로_잇는다() async throws {
    var fds: [Int32] = [-1, -1]
    pipe(&fds)
    let producer = try ChildProcess.spawn(sh("printf '하나\\n둘\\n'", stdout: .fileDescriptor(fds[1])))
    let consumer = try ChildProcess.spawn(sh("wc -l", stdin: .fileDescriptor(fds[0])))
    close(fds[0])
    close(fds[1])
    let (p, c) = await (producer.wait(), consumer.wait())
    #expect(p.succeeded)
    #expect(c.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
  }
}

// 끝난 하위 프로세스는 launchd 가 거둬 갈 때까지 잠시 남을 수 있어 조금 기다린다.
private func groupGone(_ pgid: pid_t) async -> Bool {
  for _ in 0..<20 {
    if kill(-pgid, 0) == -1 && errno == ESRCH { return true }
    try? await Task.sleep(for: .milliseconds(100))
  }
  return false
}

extension ChildSpec {
  fileprivate func with(env extra: [String: String]) -> ChildSpec {
    var copy = self
    copy.environment.merge(extra) { $1 }
    return copy
  }
}

@Suite struct ChildEnvironmentTests {
  @Test func 자격_증명_변수를_빼고_PATH와_로캘을_채운다() {
    let base = ChildEnvironment.base(
      from: ["HOME": "/Users/x", "PATH": "/usr/bin:/custom", "ANTHROPIC_API_KEY": "k", "CLAUDE_CODE_OAUTH_TOKEN": "t", "GH_TOKEN": "g", "GITHUB_TOKEN": "g"],
      toolDirectories: ["/Users/x/.local/bin", "/usr/bin"])
    #expect(base["ANTHROPIC_API_KEY"] == nil && base["CLAUDE_CODE_OAUTH_TOKEN"] == nil && base["GH_TOKEN"] == nil && base["GITHUB_TOKEN"] == nil)
    #expect(base["PATH"] == "/Users/x/.local/bin:/usr/bin:/custom:/bin:/usr/sbin:/sbin")
    #expect(base["LANG"] == "en_US.UTF-8")
    #expect(ChildEnvironment.base(from: ["LC_ALL": "ko_KR.UTF-8"], toolDirectories: [])["LANG"] == nil)
  }

  @Test func 에이전트_환경에는_모델_토큰과_설정_폴더만_더한다() {
    let agent = ChildEnvironment.agent(base: ["HOME": "/h", "CLAUDE_X": "1"], token: "tok", configDirectory: "/c")
    #expect(agent == ["HOME": "/h", "CLAUDE_CODE_OAUTH_TOKEN": "tok", "CLAUDE_CONFIG_DIR": "/c", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"])
  }
}

