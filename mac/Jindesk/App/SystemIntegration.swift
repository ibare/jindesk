// 창 밖에서 보이는 시스템 연동: 작업 중 잠자기 막기
import AppKit

// 덮개를 연 채 자리를 비웠을 때 작업 중에만 잠자기를 막는다. 덮개를 닫아 잠드는 것은 막지 못한다
// (그때는 잠든 시간을 시간 상한에서 뺀다).
@MainActor
final class SleepGuard {
  private var activity: NSObjectProtocol?

  func update(active: Bool) {
    if active, activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Jindesk 작업 실행 중")
    } else if !active, let a = activity {
      ProcessInfo.processInfo.endActivity(a)
      activity = nil
    }
  }
}
