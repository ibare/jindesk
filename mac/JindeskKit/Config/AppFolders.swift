import Foundation

// 데이터 폴더 밖의 두 곳 (DATA.md 의 "네 곳").
// - 앱 지원 폴더: work/ 작업 공간, backups/ 마이그레이션 전 자동 백업, children/ 띄운 프로세스 그룹, state.json 화면 상태, usage.json 계정 사용량. 백업하지 않는다.
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
  // 띄운 프로세스 그룹의 기록. 앱이 비정상 종료해 남은 그룹을 다음에 켤 때 끝낸다 (ProcessGroups).
  public var children: URL { support.appending(path: "children") }
  public var stateFile: URL { support.appending(path: "state.json") }
  public var usageFile: URL { support.appending(path: "usage.json") }

  public func workDir(_ id: String) -> URL { work.appending(path: id) }

  // 자료의 쪽 이미지 (긴 변 1600px PNG). 원본에서 언제든 다시 그릴 수 있어 캐시에 둔다.
  public func pageImages(_ sourceID: String) -> URL { cache.appending(path: "pages").appending(path: sourceID) }

  // 맥과 폰이 보는 쪽 이미지 (HEIC, 긴 변 2000). 자료 버킷에도 올린다 (DATA.md 의 자료 버킷).
  public func viewImages(_ sourceID: String) -> URL { pageImages(sourceID).appending(path: "view") }

  public func prepare() throws {
    for dir in [work, backups, cache] { try FileOps.makeDirectory(dir) }
  }
}
