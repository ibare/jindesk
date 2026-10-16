// 외부 실행 파일(claude, ditto, soffice)을 띄우는 부품.
// 자식은 별도 프로세스 그룹으로 띄워, 자식이 띄운 하위 프로세스까지 그룹째 정리할 수 있게 한다.
import Darwin
import Foundation

public enum ChildInput: Sendable {
  case null
  case data(Data)
  // 다른 자식의 출력 파이프처럼 이미 열린 fd. 띄운 뒤 부르는 쪽이 닫는다.
  case fileDescriptor(Int32)
}

public enum ChildOutput: Sendable {
  case null
  // 끝난 뒤 ChildResult.stdout 으로 한 번에 받는다
  case collect
  // ChildProcess.lines 로 줄마다 받는다
  case lines
  case fileDescriptor(Int32)
}

public struct ChildSpec: Sendable {
  // 절대 경로. PATH 로 찾지 않는다 (앱은 셸의 PATH 를 물려받지 않는다).
  public var executable: String
  public var arguments: [String]
  public var environment: [String: String]
  public var directory: String?
  public var stdin: ChildInput
  public var stdout: ChildOutput
  // stderr 는 끝부분만 남긴다
  public var stderrLimit: Int

  public init(
    executable: String,
    arguments: [String] = [],
    environment: [String: String],
    directory: String? = nil,
    stdin: ChildInput = .null,
    stdout: ChildOutput = .collect,
    stderrLimit: Int = 64 * 1024
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.directory = directory
    self.stdin = stdin
    self.stdout = stdout
    self.stderrLimit = stderrLimit
  }
}

public enum ChildTermination: Sendable, Equatable {
  case exited(Int32)
  case signaled(Int32)
}

public struct ChildResult: Sendable {
  public let termination: ChildTermination
  public let stdout: Data
  public let stderr: String

  public var succeeded: Bool { termination == .exited(0) }

  public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }

  // 실패 메시지에 붙일 짧은 설명
  public var summary: String {
    let how: String
    switch termination {
    case .exited(let code): how = "종료 코드 \(code)"
    case .signaled(let sig): how = "신호 \(sig)"
    }
    let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return tail.isEmpty ? how : "\(how): \(String(tail.suffix(500)))"
  }
}

public struct ChildProcessError: LocalizedError, Sendable {
  public let executable: String
  public let code: Int32

  public var errorDescription: String? {
    "\(executable) 을(를) 실행하지 못했습니다: \(String(cString: strerror(code)))"
  }
}

// 띄운 자식 하나. 가변 상태는 모두 queue 안에서만 다룬다.
public final class ChildProcess: @unchecked Sendable {
  public let pid: pid_t
  // stdout 이 .lines 일 때만 값이 나온다. 그 밖에는 바로 끝난다.
  public let lines: AsyncStream<String>

  private let linesContinuation: AsyncStream<String>.Continuation
  private let streamsLines: Bool
  private let stderrLimit: Int
  private let queue: DispatchQueue

  private var stdoutData = Data()
  private var pendingLine = Data()
  private var stderrTail = Data()
  private var openStreams = 0
  private var termination: ChildTermination?
  private var result: ChildResult?
  private var waiters: [CheckedContinuation<ChildResult, Never>] = []
  private var readers: [DispatchSourceRead] = []

  // 그룹 리더가 끝난 뒤에도 하위 프로세스가 출력 파이프를 붙잡고 있으면 이만큼 기다렸다가 그룹을 끝낸다.
  private static let lingerAfterExit: TimeInterval = 5

  private init(pid: pid_t, streamsLines: Bool, stderrLimit: Int) {
    self.pid = pid
    self.streamsLines = streamsLines
    self.stderrLimit = stderrLimit
    self.queue = DispatchQueue(label: "jindesk.child.\(pid)")
    (lines, linesContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
  }

  // 띄우고 끝날 때까지 기다린다. 작업이 취소되면 그룹째 끝낸다.
  public static func run(_ spec: ChildSpec) async throws -> ChildResult {
    let child = try spawn(spec)
    return await child.waitCancellable()
  }

  // 띄우고 기다린다. 상한을 넘으면 그룹째 끝낸다. 작업이 취소되면 그룹째 끝낸다.
  public static func run(_ spec: ChildSpec, timeout: Duration) async throws -> ChildResult {
    let child = try spawn(spec)
    let timer = Task {
      try await Task.sleep(for: timeout)
      child.signalGroup(SIGKILL)
    }
    let result = await child.waitCancellable(grace: 2)
    timer.cancel()
    return result
  }

  public static func spawn(_ spec: ChildSpec) throws -> ChildProcess {
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }

    // 새 프로세스 그룹(리더 = 자식), 신호 처리 기본값, 명시하지 않은 fd 는 닫는다.
    let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
    posix_spawnattr_setflags(&attributes, Int16(flags))
    posix_spawnattr_setpgroup(&attributes, 0)
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for sig in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2, SIGALRM, SIGCHLD] { sigaddset(&defaults, sig) }
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    var mask = sigset_t()
    sigemptyset(&mask)
    posix_spawnattr_setsigmask(&attributes, &mask)

    // 부모 쪽에서 닫아야 할 fd (자식에게 넘긴 쪽)
    var closeAfterSpawn: [Int32] = []
    // 부모가 읽거나 쓸 fd
    var stdinWriter: Int32?
    var stdoutReader: Int32?
    var stderrReader: Int32 = -1

    func makePipe() -> (read: Int32, write: Int32) {
      var fds: [Int32] = [-1, -1]
      pipe(&fds)
      for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
      return (fds[0], fds[1])
    }

    switch spec.stdin {
    case .null:
      posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
    case .data:
      let p = makePipe()
      posix_spawn_file_actions_adddup2(&fileActions, p.read, 0)
      closeAfterSpawn.append(p.read)
      stdinWriter = p.write
    case .fileDescriptor(let fd):
      posix_spawn_file_actions_adddup2(&fileActions, fd, 0)
    }

    switch spec.stdout {
    case .null:
      posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
    case .collect, .lines:
      let p = makePipe()
      posix_spawn_file_actions_adddup2(&fileActions, p.write, 1)
      closeAfterSpawn.append(p.write)
      stdoutReader = p.read
    case .fileDescriptor(let fd):
      posix_spawn_file_actions_adddup2(&fileActions, fd, 1)
    }

    let err = makePipe()
    posix_spawn_file_actions_adddup2(&fileActions, err.write, 2)
    closeAfterSpawn.append(err.write)
    stderrReader = err.read

    if let directory = spec.directory {
      posix_spawn_file_actions_addchdir(&fileActions, directory)
    }

    let argv = [spec.executable] + spec.arguments
    let envp = spec.environment.map { "\($0.key)=\($0.value)" }
    var pid: pid_t = 0
    let status = withCStringArray(argv) { argvPtr in
      withCStringArray(envp) { envPtr in
        posix_spawn(&pid, spec.executable, &fileActions, &attributes, argvPtr, envPtr)
      }
    }
    for fd in closeAfterSpawn { close(fd) }
    guard status == 0 else {
      for fd in [stdinWriter, stdoutReader, stderrReader].compactMap({ $0 }) { close(fd) }
      throw ChildProcessError(executable: spec.executable, code: status)
    }

    ProcessGroups.shared.add(pid)
    var streamsLines = false
    if case .lines = spec.stdout { streamsLines = true }
    let child = ChildProcess(pid: pid, streamsLines: streamsLines, stderrLimit: spec.stderrLimit)
    child.start(stdoutReader: stdoutReader, stderrReader: stderrReader, stdinWriter: stdinWriter, stdinData: spec.stdin)
    return child
  }

  // 그룹 전체에 신호를 보낸다. 이미 끝난 그룹이면 아무 일도 없다.
  public func signalGroup(_ signal: Int32) {
    _ = kill(-pid, signal)
  }

  // SIGTERM 을 보내고, grace 안에 끝나지 않으면 SIGKILL 을 보낸다.
  public func stop(grace: TimeInterval = 10) {
    signalGroup(SIGTERM)
    queue.asyncAfter(deadline: .now() + grace) { [self] in
      if result == nil { signalGroup(SIGKILL) }
    }
  }

  public func wait() async -> ChildResult {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        if let result { continuation.resume(returning: result) } else { waiters.append(continuation) }
      }
    }
  }

  public func waitCancellable(grace: TimeInterval = 10) async -> ChildResult {
    await withTaskCancellationHandler {
      await wait()
    } onCancel: {
      stop(grace: grace)
    }
  }

  // MARK: - 내부

  private func start(stdoutReader: Int32?, stderrReader: Int32, stdinWriter: Int32?, stdinData: ChildInput) {
    queue.sync {
      if let fd = stdoutReader { addReader(fd) { [self] chunk in receiveStdout(chunk) } }
      addReader(stderrReader) { [self] chunk in receiveStderr(chunk) }
      if stdoutReader == nil { linesContinuation.finish() }
    }

    if let fd = stdinWriter, case .data(let data) = stdinData {
      Thread.detachNewThread {
        data.withUnsafeBytes { buffer in
          var offset = 0
          while offset < buffer.count {
            let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { break }
          }
        }
        close(fd)
      }
    }

    // 끝나기를 기다리는 스레드. 블로킹 waitpid 라 경쟁 조건이 없다.
    let pid = self.pid
    Thread.detachNewThread { [self] in
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
      let termination: ChildTermination =
        (status & 0x7f) == 0 ? .exited((status >> 8) & 0xff) : .signaled(status & 0x7f)
      queue.async { [self] in
        self.termination = termination
        ProcessGroups.shared.remove(pid)
        // 하위 프로세스가 파이프를 붙잡고 있으면 잠시 기다린 뒤 그룹째 끝낸다.
        if openStreams > 0 {
          queue.asyncAfter(deadline: .now() + Self.lingerAfterExit) { [self] in
            guard result == nil else { return }
            _ = kill(-pid, SIGKILL)
            queue.asyncAfter(deadline: .now() + 1) { [self] in
              for reader in readers { reader.cancel() }
            }
          }
        }
        finishIfDone()
      }
    }
  }

  private func addReader(_ fd: Int32, onChunk: @escaping (Data) -> Void) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    openStreams += 1
    source.setEventHandler { [weak source] in
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      while true {
        let n = read(fd, &buffer, buffer.count)
        if n > 0 {
          onChunk(Data(buffer[0..<n]))
        } else if n < 0 && errno == EINTR {
          continue
        } else {
          if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) { source?.cancel() }
          return
        }
      }
    }
    source.setCancelHandler { [self] in
      close(fd)
      openStreams -= 1
      if openStreams == 0 { flushLines() }
      finishIfDone()
    }
    readers.append(source)
    source.resume()
  }

  private func receiveStdout(_ chunk: Data) {
    guard streamsLines else {
      stdoutData.append(chunk)
      return
    }
    pendingLine.append(chunk)
    while let newline = pendingLine.firstIndex(of: 0x0A) {
      let line = pendingLine[pendingLine.startIndex..<newline]
      linesContinuation.yield(String(decoding: line, as: UTF8.self))
      pendingLine.removeSubrange(pendingLine.startIndex...newline)
    }
  }

  private func receiveStderr(_ chunk: Data) {
    stderrTail.append(chunk)
    if stderrTail.count > stderrLimit { stderrTail.removeFirst(stderrTail.count - stderrLimit) }
  }

  private func flushLines() {
    guard streamsLines else { return }
    if !pendingLine.isEmpty { linesContinuation.yield(String(decoding: pendingLine, as: UTF8.self)) }
    pendingLine.removeAll()
    linesContinuation.finish()
  }

  private func finishIfDone() {
    guard result == nil, openStreams == 0, let termination else { return }
    let result = ChildResult(termination: termination, stdout: stdoutData, stderr: String(decoding: stderrTail, as: UTF8.self))
    self.result = result
    readers.removeAll()
    for waiter in waiters { waiter.resume(returning: result) }
    waiters.removeAll()
  }
}

private func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
  var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
  pointers.append(nil)
  defer { for p in pointers { free(p) } }
  return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

// 띄운 프로세스 그룹의 리더 PID. 앱이 끝날 때 그룹째 정리한다.
public final class ProcessGroups: @unchecked Sendable {
  public static let shared = ProcessGroups()

  private let lock = NSLock()
  private var pids = Set<pid_t>()

  func add(_ pid: pid_t) {
    lock.withLock { _ = pids.insert(pid) }
  }

  func remove(_ pid: pid_t) {
    lock.withLock { _ = pids.remove(pid) }
  }

  public var active: Set<pid_t> {
    lock.withLock { pids }
  }

  // 앱 종료 처리에서 부른다. 동기로만 동작한다.
  public func killAll() {
    for pid in active { _ = kill(-pid, SIGKILL) }
  }
}
