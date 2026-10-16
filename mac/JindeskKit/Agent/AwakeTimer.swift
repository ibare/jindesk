// 맥이 잠든 시간은 세지 않는 시간 상한.
// SuspendingClock 은 잠든 동안 멈추므로, 깨어 있던 시간만 센다. 덮개를 닫았다 열어도 깨자마자 상한이 지나 버리지 않는다.
import Foundation

public enum AwakeTimer {
  // 깨어 있던 시간이 limit 에 이르면 돌아온다. 취소되면 CancellationError 를 던진다.
  // 한 간격 사이에 벽시계가 깨어 있던 시간보다 30초 넘게 더 흘렀으면 잠들었던 것으로 보고 onSleep 으로 알린다.
  public static func wait(
    _ limit: Duration, tick: Duration = .seconds(15), onSleep: (@Sendable (Duration) async -> Void)? = nil
  ) async throws {
    let suspending = SuspendingClock()
    let continuous = ContinuousClock()
    var awake = Duration.zero
    while awake < limit {
      let step = min(tick, limit - awake)
      let s0 = suspending.now
      let c0 = continuous.now
      try await Task.sleep(for: step, clock: suspending)
      let slept = suspending.now - s0
      let wall = continuous.now - c0
      awake += slept
      if wall - slept > .seconds(30) { await onSleep?(wall - slept) }
    }
  }

  // 시간 상한과 함께 일을 한다. 상한이 먼저 오면 onExpire 를 부르고, 일이 끝날 때까지 기다린다.
  public static func race<T: Sendable>(
    limit: Duration, onSleep: (@Sendable (Duration) async -> Void)? = nil, onExpire: @escaping @Sendable () async -> Void,
    _ work: @escaping @Sendable () async -> T
  ) async -> T {
    let timer = Task {
      do {
        try await wait(limit, onSleep: onSleep)
        await onExpire()
      } catch {}
    }
    let result = await work()
    timer.cancel()
    return result
  }
}
