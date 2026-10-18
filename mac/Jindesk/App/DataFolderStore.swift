import Foundation
import JindeskKit

// 고른 데이터 폴더를 기억한다. 폴더를 옮겨도 따라가도록 북마크로 두고, 명령줄 모드가 읽을 수 있게 경로도 함께 둔다.
enum DataFolderStore {
  static let bookmarkKey = "dataFolderBookmark"
  static let pathKey = "dataFolderPath"

  static func load() -> DataFolder? {
    let defaults = AppPaths.defaults
    if let data = defaults.data(forKey: bookmarkKey) {
      var stale = false
      if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale) {
        if stale { save(url) }
        return DataFolder(url)
      }
    }
    return defaults.string(forKey: pathKey).map(DataFolder.init(path:))
  }

  // 폴더가 있어야 북마크를 만들 수 있다. 처음 만드는 폴더는 만든 뒤 부른다.
  static func save(_ url: URL) {
    let defaults = AppPaths.defaults
    defaults.set(try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: bookmarkKey)
    defaults.set(DataFolder(url).path, forKey: pathKey)
  }
}

// 이 맥의 앱 설정에서 연결한 자료 버킷 (DATA.md 의 자료 버킷). 키는 키체인(BucketKeyStore.mac)에 둔다.
enum BucketLinkStore {
  static let key = "filesBucket"

  static func load() -> BucketLink? {
    AppPaths.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(BucketLink.self, from: $0) }
  }

  static func save(_ link: BucketLink) {
    AppPaths.defaults.set(try? JSONEncoder().encode(link), forKey: key)
  }
}

// 이 맥의 앱 설정에서 연결한 데이터 리포 (DATA.md 의 데이터 리포). 데이터 폴더 안에는 두지 않는다. 명령줄 모드도 읽는다.
enum RepoLinkStore {
  static let key = "dataRepoLink"

  static func load() -> RepoLink? {
    AppPaths.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(RepoLink.self, from: $0) }
  }

  static func save(_ link: RepoLink) {
    AppPaths.defaults.set(try? JSONEncoder().encode(link), forKey: key)
  }
}
