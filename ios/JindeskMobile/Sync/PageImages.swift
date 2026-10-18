// 원래 자료의 쪽 이미지 (MOBILE.md 의 원래 자료의 쪽, DATA.md 의 자료 버킷). 출처를 누르거나 넘길 때 그 쪽만 자료 버킷에서 받는다.
// 받은 쪽은 앱 지원 폴더의 pages/ 에 두어 다시 받지 않는다. 맥과 같은 이미지(HEIC, 긴 변 2000)다.
import Foundation
import JindeskKit

struct PageImages: Sendable {
  let root: URL
  let client: GCSClient?
  // 화면 확인: 버킷 대신 맥의 캐시처럼 놓인 폴더(<자료 id>/view/<쪽>.heic)에서 가져온다
  var localSource: URL?

  func file(_ source: String, _ page: Int) -> URL {
    root.appending(path: source).appending(path: String(format: "%04d.heic", page))
  }

  func image(_ source: String, page: Int) async throws -> URL {
    let target = file(source, page)
    if FileManager.default.fileExists(atPath: target.path) { return target }
    let data: Data
    if let localSource {
      let local = localSource.appending(path: source).appending(path: "view").appending(path: String(format: "%04d.heic", page))
      guard let bytes = try? Data(contentsOf: local) else { throw BucketError("이 쪽의 이미지가 없습니다") }
      data = bytes
    } else {
      guard let client else { throw BucketError("설정에서 자료 버킷을 넣으면 원래 자료의 쪽을 볼 수 있습니다") }
      data = try await client.get(BucketObject.page(source, page))
    }
    try FileOps.makeDirectory(target.deletingLastPathComponent())
    try FileOps.writeAtomic(data, to: target)
    return target
  }

  func clear() {
    FileOps.remove(root)
  }
}
