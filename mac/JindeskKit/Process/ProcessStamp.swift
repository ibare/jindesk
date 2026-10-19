// 프로세스 하나를 가리키는 값: PID 와 시작 시각. PID 는 다시 쓰이므로 시작 시각까지 같아야 같은 프로세스다.
import Darwin
import Foundation

public struct ProcessStamp: Sendable, Codable, Equatable {
  public let pid: Int32
  // 시작 시각 (1970 년부터의 마이크로초)
  public let started: Int64

  public init(pid: Int32, started: Int64) {
    self.pid = pid
    self.started = started
  }

  // 지금 이 프로세스
  public static let current = of(getpid()) ?? ProcessStamp(pid: getpid(), started: 0)

  // 그 PID 의 지금 프로세스. 없으면 nil.
  public static func of(_ pid: pid_t) -> ProcessStamp? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return ProcessStamp(pid: pid, started: Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec))
  }

  // 이 프로세스가 아직 살아 있는가
  public var isAlive: Bool { Self.of(pid) == self }
}
