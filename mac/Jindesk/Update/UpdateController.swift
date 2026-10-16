// 자동 업데이트 (UPDATES.md). Sparkle 2 가 켤 때와 6시간마다 이 리포의 GitHub Releases 를 보고, 새 판을 뒤에서 내려받는다.
// 내려받은 판은 작업이 없을 때 바로 설치하고 다시 켠다. 작업이 돌고 있으면 새 작업을 멈추고(hold) 끝나기를 기다린다.
// 훅 실행 파일이 번들 안에 있어서, 작업 중에 번들이 바뀌면 훅이 뜨지 못하고 웹 호출이 막히기 때문이다.
import AppKit
import JindeskKit
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateStatus {
  enum State: Equatable {
    // 공개 키가 없는 빌드(개발 빌드)는 업데이트를 확인하지 않는다
    case disabled(String)
    case idle
    // 내려받아 두었고, 작업이 끝나면 설치한다
    case waiting(String)
    case installing(String)
  }

  var state: State = .idle
  var lastCheck: Date?
  var lastError: String?
}

@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
  // 대리자로 self 를 넘기므로 super.init 뒤에 만든다
  private var controller: SPUStandardUpdaterController?
  private weak var model: AppModel?
  private var pendingInstall: (() -> Void)?
  private var pendingVersion: String?

  init(model: AppModel) {
    self.model = model
    super.init()
    #if DEBUG
      // 개발 중인 빌드가 릴리즈 판으로 바뀌어 버리지 않게 한다
      model.update.state = .disabled("디버그 빌드라 업데이트를 확인하지 않습니다")
      return
    #endif
    let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
    guard !key.isEmpty else {
      model.update.state = .disabled("공개 키가 없는 빌드라 업데이트를 확인하지 않습니다")
      return
    }
    controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
  }

  var updater: SPUUpdater? { controller?.updater }

  func checkNow() {
    guard case .idle = model?.update.state else { return }
    controller?.checkForUpdates(nil)
  }

  // 작업이 끝날 때마다 부른다. 기다리던 업데이트가 있고 작업이 없으면 설치한다.
  func installIfIdle() {
    guard let install = pendingInstall, let model, model.canInstallUpdate else { return }
    pendingInstall = nil
    model.update.state = .installing(pendingVersion ?? "")
    install()
  }

  // MARK: - SPUUpdaterDelegate

  // 조용히 내려받은 업데이트가 끝낼 때 설치되기를 기다린다. 우리가 설치 시각을 정한다(true).
  nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void)
    -> Bool
  {
    let version = item.displayVersionString
    nonisolated(unsafe) let handler = immediateInstallHandler
    MainActor.assumeIsolated {
      pendingInstall = handler
      pendingVersion = version
      model?.update.state = .waiting(version)
      model?.jobs?.hold(.update)
      installIfIdle()
    }
    return true
  }

  // 사람이 설치를 고른 경우에도 작업 중이면 다시 켜기를 미룬다
  nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void)
    -> Bool
  {
    let version = item.displayVersionString
    nonisolated(unsafe) let handler = installHandler
    return MainActor.assumeIsolated {
      guard let model, !model.canInstallUpdate else { return false }
      pendingInstall = handler
      pendingVersion = version
      model.update.state = .waiting(version)
      model.jobs?.hold(.update)
      return true
    }
  }

  nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
    let message = error.map { ($0 as NSError).localizedDescription }
    MainActor.assumeIsolated {
      model?.update.lastCheck = Date()
      model?.update.lastError = message
    }
  }
}
