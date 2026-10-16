import Foundation

// 데이터 폴더 밖의 두 곳 (DATA.md 의 "네 곳").
// - 앱 지원 폴더: work/ 작업 공간, backups/ 마이그레이션 전 자동 백업, state.json 화면 상태, usage.json 계정 사용량. 백업하지 않는다.
// - 캐시: SQLite 색인, 쪽 이미지, 렌더러에 넘길 조합 결과. 지워도 다시 만든다.
public struct AppFolders: Sendable, Equatable {
  public static let bundleID = "com.mintae.Jindesk"

  public let support: URL
  public let cache: URL

  // 실제 경로로 둔다. 에이전트(claude)는 작업 디렉터리를 실제 경로로 기록하므로, 경로를 견줄 때 같은 모양이어야 한다.
  public init(support: URL, cache: URL) {
    self.support = URL(fileURLWithPath: FileOps.resolvedPath(support.path), isDirectory: true)
    self.cache = URL(fileURLWithPath: FileOps.resolvedPath(cache.path), isDirectory: true)
  }

  public static func standard() -> AppFolders {
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    return AppFolders(
      support: library.appending(path: "Application Support/\(bundleID)"),
      cache: library.appending(path: "Caches/\(bundleID)"))
  }

  public var work: URL { support.appending(path: "work") }
  public var backups: URL { support.appending(path: "backups") }
  public var stateFile: URL { support.appending(path: "state.json") }
  public var usageFile: URL { support.appending(path: "usage.json") }

  public func workDir(_ id: String) -> URL { work.appending(path: id) }

  public func prepare() throws {
    for dir in [work, backups, cache] { try FileOps.makeDirectory(dir) }
  }
}
