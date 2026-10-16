import SwiftUI

// 인자가 명령줄 모드의 명령이면 화면 없이 명령을 실행하고 끝낸다. 그 밖에는 앱으로 뜬다.
@main
enum Main {
  @MainActor
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if CommandLineMode.handles(arguments) { CommandLineMode.run(arguments) }
    JindeskApp.main()
  }
}
