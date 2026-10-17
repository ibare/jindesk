import AppKit
import JindeskKit
import SwiftUI

struct JindeskApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var model = AppModel(folders: Self.folders)

  // 화면 찍기는 실제 앱 지원 폴더 대신 찍는 폴더 아래를 쓴다
  static var folders: AppFolders {
    #if DEBUG
      if let folders = SnapshotDriver.folders { return folders }
    #endif
    return .standard()
  }

  var body: some Scene {
    Window("Jindesk", id: "main") {
      RootView()
        .environment(model)
        .frame(minWidth: 900, minHeight: 560)
        .task { await delegate.attach(model) }
        .background(WindowOpenerBridge())
    }
    .commands {
      AppCommands(model: model)
    }

    // 관리자 설정: 학생 화면에서는 감춘다. 앱 메뉴에서 ⌥ 키를 누른 채 열어야 보인다.
    Window("관리자 설정", id: "admin") {
      AdminSettingsView()
        .environment(model)
        .frame(minWidth: 640, minHeight: 520)
    }
    .defaultSize(width: 720, height: 640)
    .windowResizability(.contentMinSize)

    MenuBarExtra {
      MenuBarContent().environment(model)
    } label: {
      MenuBarLabel().environment(model)
    }
  }
}

// 앱 대리자: 창을 닫아도 앱은 남고(메뉴 막대), 작업 중에 끝내려 하면 확인한다
final class AppDelegate: NSObject, NSApplicationDelegate {
  private weak var model: AppModel?

  @MainActor
  func attach(_ model: AppModel) async {
    guard self.model == nil else { return }
    self.model = model
    model.updater = UpdateController(model: model)
    AdminMenu.install()
    await model.start()
    #if DEBUG
      if let directory = SnapshotDriver.directory { await SnapshotDriver.run(model, to: directory) }
    #endif
  }

  @MainActor
  static func isMainWindow(_ window: NSWindow) -> Bool {
    window.identifier?.rawValue.hasPrefix("main") == true
  }

  @MainActor
  static func showMainWindow() {
    NSApp.activate()
    if let window = NSApp.windows.first(where: isMainWindow) {
      window.makeKeyAndOrderFront(nil)
    } else if let open = openMainWindow {
      open()
    }
  }

  // 메인 창과 관리자 설정 창을 연다 (SwiftUI 의 openWindow 를 화면이 넘겨준다)
  @MainActor static var openMainWindow: (() -> Void)?
  @MainActor static var openAdminWindow: (() -> Void)?

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    MainActor.assumeIsolated {
      guard let model, model.isBusy else { return .terminateNow }
      // 업데이트 설치로 끝나는 것은 작업이 없을 때뿐이다
      let running = model.jobs?.active.count ?? 0
      let alert = NSAlert()
      alert.messageText = model.backupStatus != nil ? "백업을 만드는 중입니다" : running > 0 ? "작업이 진행 중입니다" : "대기 중인 작업이 있습니다"
      alert.informativeText = "끝내면 진행 중인 일이 중단되고 대기열이 비워집니다. 다음에 켜면 이어서 할 수 있습니다."
      alert.addButton(withTitle: "취소")
      alert.addButton(withTitle: "끝내기")
      alert.alertStyle = .warning
      return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { model?.shutdown() }
    ProcessGroups.shared.killAll()
  }
}

// 관리자 설정 메뉴 항목은 ⌥ 키를 누른 채 메뉴를 열 때만 보인다 (SETUP.md)
@MainActor
enum AdminMenu {
  static let title = "관리자 설정…"
  private static var installed = false

  static func install() {
    guard !installed else { return }
    installed = true
    NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { refresh() }
    }
    refresh()
  }

  static func refresh() {
    let reveal = NSEvent.modifierFlags.contains(.option)
    for item in NSApp.mainMenu?.items ?? [] {
      for sub in item.submenu?.items ?? [] where sub.title == title { sub.isHidden = !reveal }
    }
  }
}

struct AppCommands: Commands {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(after: .appSettings) {
      Button(AdminMenu.title) {
        openWindow(id: "admin")
        NSApp.activate()
      }
      .keyboardShortcut(",", modifiers: [.command, .option])
    }
    CommandGroup(replacing: .newItem) {}
    CommandGroup(after: .newItem) {
      Button("자료 넣기…") {
        AppDelegate.showMainWindow()
        model.showIntake = true
      }
      .keyboardShortcut("o", modifiers: .command)
      .disabled(model.phase != .ready)
      Divider()
      Button("백업 만들기…") { BackupPanel.run(model) }
        .keyboardShortcut("b", modifiers: [.command, .shift])
        .disabled(model.data == nil || model.backupStatus != nil)
      Button("데이터 폴더 보기") {
        if let data = model.data { model.reveal(data.url) }
      }
      .disabled(model.data == nil)
    }
  }
}

// 백업 zip 을 둘 곳을 고르고 만든다
@MainActor
enum BackupPanel {
  static func run(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "여기에 백업 만들기"
    panel.message = "백업 zip 을 둘 곳을 고르세요. 외장 디스크처럼 이 맥 밖의 곳이 좋습니다."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      let message = await model.makeBackup(into: url)
      let alert = NSAlert()
      alert.messageText = message
      if let backup = model.lastBackup, message.hasPrefix("백업을 만들었습니다") {
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "Finder 에서 보기")
        if alert.runModal() == .alertSecondButtonReturn { model.reveal(backup) }
      } else {
        alert.runModal()
      }
    }
  }
}

// 메뉴 막대 아이콘: 작업 중에는 모래시계, 업데이트를 기다리면 화살표
struct MenuBarLabel: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let running = model.jobs?.active.count ?? 0
    if running > 1 {
      Text("\(Image(systemName: "hourglass")) \(running)")
    } else if running == 1 || model.backupStatus != nil {
      Image(systemName: "hourglass")
    } else if case .waiting = model.update.state {
      Image(systemName: "arrow.down.circle")
    } else {
      Image(systemName: "book.closed")
    }
  }
}

struct MenuBarContent: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let active = model.jobs?.active ?? []
    if let backup = model.backupStatus {
      Text(backup)
    } else if active.isEmpty {
      Text("쉬는 중")
    } else {
      Section("진행 중 \(active.count)") {
        ForEach(active) { s in Text("\(s.typeLabel) · \(s.title) · \(s.phaseLabel)") }
      }
    }
    if let queue = model.jobs?.queue, !queue.isEmpty {
      Text("대기 \(queue.count)")
    }
    if case .waiting(let version) = model.update.state {
      Divider()
      Text("업데이트 \(version) 대기 중 · 지금 작업이 끝나면 설치")
    }
    Divider()
    Button("Jindesk 열기") { AppDelegate.showMainWindow() }
    Divider()
    Button("Jindesk 끝내기") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
  }
}

// openWindow 를 앱 대리자에 넘긴다. 메인 창을 닫은 뒤 메뉴 막대에서 다시 열 때 쓴다.
struct WindowOpenerBridge: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear.onAppear {
      AppDelegate.openMainWindow = { openWindow(id: "main") }
      AppDelegate.openAdminWindow = { openWindow(id: "admin") }
    }
  }
}
