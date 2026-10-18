import Foundation
import JindeskKit
import Testing

// 원래 자료의 쪽 이미지 (MOBILE.md 의 원래 자료의 쪽). 자료 버킷은 URLProtocol 로 흉내 낸다.
@Suite struct PageImagesTests {
  let host = "\(UUID().uuidString.lowercased()).gcs.test"
  let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "jindesk-pages-\(UUID().uuidString)")

  var pages: PageImages {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FakeBucket.self]
    let client = GCSClient(bucket: "jindesk-files", key: BucketKey(accessID: "GOOG1READ", secret: "s"), session: URLSession(configuration: configuration), endpoint: URL(string: "https://\(host)")!)
    return PageImages(root: root, client: client)
  }

  @Test func 쪽을_버킷에서_받아_두고_다시_받지_않는다() async throws {
    FakeBucket.put(host, "jindesk-files/sources/20261018-3fa2c1d0/pages/0003.heic", Data("쪽 3".utf8))
    let url = try await pages.image("20261018-3fa2c1d0", page: 3)
    #expect(try Data(contentsOf: url) == Data("쪽 3".utf8))
    #expect(FakeBucket.count(host) == 1)
    _ = try await pages.image("20261018-3fa2c1d0", page: 3)
    #expect(FakeBucket.count(host) == 1)
  }

  @Test func 없는_쪽과_버킷을_넣지_않은_때는_까닭을_알린다() async throws {
    let missing = await #expect(throws: BucketError.self) { try await pages.image("20261018-3fa2c1d0", page: 9) }
    #expect(missing?.status == 404)
    let none = await #expect(throws: BucketError.self) { try await PageImages(root: root, client: nil).image("20261018-3fa2c1d0", page: 1) }
    #expect(none?.message.contains("설정에서 자료 버킷") == true)
  }
}

final class FakeBucket: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var objects: [String: [String: Data]] = [:]
  nonisolated(unsafe) private static var counts: [String: Int] = [:]

  static func put(_ host: String, _ path: String, _ data: Data) { lock.withLock { objects[host, default: [:]][path] = data } }
  static func count(_ host: String) -> Int { lock.withLock { counts[host] ?? 0 } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let url = request.url!
    let host = url.host ?? ""
    let path = String(url.path.dropFirst())
    let found: Data? = Self.lock.withLock {
      Self.counts[host, default: 0] += 1
      return Self.objects[host]?[path]
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: found == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: found ?? Data())
    client?.urlProtocolDidFinishLoading(self)
  }
}
