import SwiftUI

// 인자가 명령줄 모드의 명령이면 화면 없이 명령을 실행하고 끝낸다. 그 밖에는 앱으로 뜬다.
@main
enum Main {
  @MainActor
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if CommandLineMode.handles(arguments) { CommandLineMode.run(arguments) }
    showScrollBarsWhenScrolling()
    JindeskApp.main()
  }

  // 스크롤바는 스크롤할 때만 보인다. 마우스가 있으면 시스템 설정 "자동"이 늘 보이는 스크롤바가 되므로
  // 이 앱에서만 "스크롤할 때"로 덮는다. 인자 도메인은 시스템 설정보다 앞서고 저장되지 않는다.
  // 학습 페이지의 WKWebView 도 웹 프로세스를 띄울 때 앱의 이 값을 받아 간다.
  private static func showScrollBarsWhenScrolling() {
    let defaults = UserDefaults.standard
    var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["AppleShowScrollBars"] = "WhenScrolling"
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
  }
}
