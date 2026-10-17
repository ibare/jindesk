import Foundation
import JindeskKit

// 앱 번들 안의 실행 파일과 자원 위치. 명령줄로 쓸 때는 심볼릭 링크로 불릴 수 있어 실제 경로를 따라간다.
enum AppPaths {
  static let executable: URL = {
    var size: UInt32 = 4096
    var buffer = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&buffer, &size) != 0 {
      buffer = [CChar](repeating: 0, count: Int(size))
      _ = _NSGetExecutablePath(&buffer, &size)
    }
    let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return URL(fileURLWithPath: path).resolvingSymlinksInPath()
  }()

  static var bundle: URL {
    executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }

  static var guardHelper: String {
    executable.deletingLastPathComponent().appendingPathComponent("jindesk-guard").path
  }

  // 빌드할 때 넣은 작업 지침과 스키마 (mac/project.yml 의 "작업 지침과 스키마 넣기")
  static var instructions: InstructionSource {
    InstructionSource(bundle.appending(path: "Contents/Resources/jobs"))
  }

  static var schemas: URL {
    bundle.appending(path: "Contents/Resources/schemas")
  }

  // 학습 페이지 렌더러 (리포의 renderer/)
  static var renderer: URL {
    bundle.appending(path: "Contents/Resources/renderer")
  }

  // 수식 검사에 쓰는 렌더러의 KaTeX
  static var katex: URL {
    renderer.appending(path: "katex/katex.min.js")
  }

  static let bundleID = AppFolders.bundleID

  // 앱 설정 저장소. 앱 번들로 인식되지 않게 띄우면 UserDefaults.standard 가 다른 곳을 가리키므로, 그때는 앱의 이름으로 연다.
  static var defaults: UserDefaults {
    Bundle.main.bundleIdentifier == bundleID ? .standard : (UserDefaults(suiteName: bundleID) ?? .standard)
  }

  static var version: AppVersion { AppVersion.from(Bundle(url: bundle) ?? .main) }
}
