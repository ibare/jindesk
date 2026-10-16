// 명령줄 모드. 앱 실행 파일에 명령을 주면 화면 없이 실행한다.
//   Jindesk doctor [--data <데이터 폴더>] [--out <결과 파일>]
//   Jindesk migrate --check <백업 폴더나 zip> [--sample <n>] [--keep]
//   Jindesk backup --out <폴더> [--data <데이터 폴더>]
//   Jindesk version
import AppKit
import ArgumentParser
import Foundation
import JindeskKit

struct JindeskCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "Jindesk",
    abstract: "Jindesk 명령줄 모드",
    subcommands: [DoctorCommand.self, MigrateCommand.self, BackupCommand.self, VersionCommand.self]
  )
}

@MainActor
enum CommandLineMode {
  static let commands: Set<String> = ["doctor", "migrate", "backup", "version", "help", "--help", "-h"]

  // 첫 인자가 명령이면 명령줄 모드다. "-" 로 시작하는 인자(-snapshotDir, Xcode 가 붙이는 -NSDocumentRevisionsDebugMode 등)만 있으면 앱으로 뜬다.
  // 모르는 명령도 명령줄 모드로 받아 오류를 보인다. 화면 앱으로 떠 버리면 스크립트가 멈춘다.
  static func handles(_ arguments: [String]) -> Bool {
    guard let first = arguments.first else { return false }
    return commands.contains(first) || !first.hasPrefix("-")
  }

  static func run(_ arguments: [String]) -> Never {
    // 파일로 넘겨도 기록이 바로바로 보이도록 줄 단위로 내보낸다
    setvbuf(stdout, nil, _IOLBF, 0)
    Task { @MainActor in
      do {
        var command = try JindeskCommand.parseAsRoot(arguments)
        if var asyncCommand = command as? AsyncParsableCommand {
          try await asyncCommand.run()
        } else {
          try command.run()
        }
        exit(0)
      } catch {
        JindeskCommand.exit(withError: error)
      }
    }
    // 메인 런루프를 돌린다. 타이머가 없으면 run() 이 바로 돌아온다.
    Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in }
    RunLoop.main.run()
    exit(0)
  }

  // --data 를 주지 않으면 앱에서 고른 데이터 폴더
  static func dataFolder(_ path: String?) -> DataFolder? {
    path.map(DataFolder.init(path:)) ?? DataFolderStore.load()
  }
}

// 결과를 화면과 (주어지면) 파일에 함께 쓴다. Dock 이나 open 으로 띄운 경우는 화면 출력이 보이지 않으므로 파일로 확인한다.
struct Output {
  let file: String?
  private var lines: [String] = []

  init(file: String?) {
    self.file = file
  }

  mutating func line(_ text: String) {
    print(text)
    lines.append(text)
  }

  func save() throws {
    guard let file else { return }
    try (lines.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
  }
}

struct DoctorCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "doctor", abstract: "실행 환경을 점검한다")

  @Option(help: "데이터 폴더. 주지 않으면 앱에서 고른 폴더") var data: String?
  @Option(help: "결과를 쓸 파일") var out: String?

  func run() async throws {
    var output = Output(file: out)
    output.line("실행 파일: \(AppPaths.executable.path)")
    let input = await Doctor.Input(
      guardHelper: AppPaths.guardHelper, instructions: AppPaths.instructions, schemas: AppPaths.schemas, data: CommandLineMode.dataFolder(data),
      folders: .standard(), claudePath: AdminSettings.load(AppPaths.defaults).claudePath, app: AppPaths.version)
    let items = await Doctor.run(input)
    for item in items {
      let mark = switch item.status {
      case .ok: "✓"
      case .warn: "!"
      case .fail: "✗"
      }
      output.line("\(mark) \(item.name) — \(item.detail)")
    }
    try output.save()
    if items.contains(where: { $0.status == .fail }) { throw ExitCode(1) }
  }
}

struct MigrateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "migrate", abstract: "데이터 폴더 사본에서 마이그레이션을 시험한다. 원래 폴더는 건드리지 않는다",
    discussion: "학생에게 받은 백업 폴더나 zip 으로, 릴리즈 전에 이번 판의 마이그레이션이 통과하는지 본다 (MIGRATION.md).")

  @Option(name: .customLong("check"), help: "백업 폴더나 zip") var check: String
  @Option(help: "에이전트 단계는 표본 n 개만 돌린다") var sample: Int?
  @Flag(help: "시험한 사본을 지우지 않고 남긴다 (바뀐 파일을 직접 볼 때)") var keep = false

  func run() async throws {
    let source = URL(fileURLWithPath: (check as NSString).expandingTildeInPath)
    guard FileOps.exists(source) else { throw ValidationError("없는 경로입니다: \(source.path)") }
    let folders = AppFolders.standard()
    try folders.prepare()
    let report = try await MigrationCheck.run(source: source, folders: folders, app: AppPaths.version, sample: sample) { print("· \($0)") }
    print("스키마: \(report.from.map(String.init) ?? "\(report.to)") → \(report.to) (앱 \(CurrentSchema.version))")
    for note in report.notes { print(note) }
    print("더해진 파일 \(report.added.count) · 지워진 파일 \(report.removed.count) · 바뀐 파일 \(report.changed.count)")
    for path in report.added { print("  + \(path)") }
    for path in report.removed { print("  - \(path)") }
    for path in report.changed { print("  ~ \(path)") }
    if report.issues.isEmpty {
      print("✓ 검증 통과")
    } else {
      print("✗ 검증 실패 \(report.issues.count)건")
      for issue in report.issues { print("  · \(issue)") }
    }
    if keep {
      print("사본: \(report.workFolder.path)")
    } else {
      FileOps.remove(report.workFolder)
    }
    if !report.issues.isEmpty { throw ExitCode(1) }
  }
}

struct BackupCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "backup", abstract: "데이터 폴더의 백업 zip 을 만든다. 작업이 돌고 있으면 끝날 때까지 기다린다")

  @Option(help: "백업 zip 을 둘 폴더") var out: String
  @Option(help: "데이터 폴더. 주지 않으면 앱에서 고른 폴더") var data: String?

  func run() async throws {
    guard let folder = await CommandLineMode.dataFolder(data), folder.isInitialized else { throw ValidationError("Jindesk 데이터 폴더를 찾지 못했습니다") }
    let url = try await Backup.make(folder, into: URL(fileURLWithPath: (out as NSString).expandingTildeInPath)) {
      print("다른 Jindesk 프로세스가 작업 중입니다. 끝나기를 기다립니다…")
    }
    print(url.path)
  }
}

struct VersionCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "version", abstract: "앱 판과 스키마 버전을 보인다")

  func run() async throws {
    let version = AppPaths.version
    print("Jindesk \(version.label) · 스키마 \(CurrentSchema.version)")
  }
}
