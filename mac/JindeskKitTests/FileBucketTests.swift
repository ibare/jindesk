import Foundation
import ImageIO
import Testing
@testable import JindeskKit

// 자료 버킷 (DATA.md 의 자료 버킷). GCS 는 URLProtocol 로 흉내 낸다. 시험마다 다른 호스트를 써서 서로 섞이지 않는다.
@MainActor
@Suite struct FileBucketTests {
  let host = "\(UUID().uuidString.lowercased()).gcs.test"
  let key = BucketKey(accessID: "GOOG1TEST", secret: "secret")

  var client: GCSClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FakeGCS.self]
    return GCSClient(bucket: "jindesk-files-dev", key: key, session: URLSession(configuration: configuration), endpoint: URL(string: "https://\(host)")!)
  }

  // AWS 문서의 SigV4 예제 (GET Object): 같은 서명이 나와야 GCS 의 S3 호환 API 가 받는다
  @Test func 서명은_SigV4_예제와_같다() {
    let empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let auth = GCSClient.authorization(
      method: "GET", path: "/test.txt", query: [],
      headers: ["host": "examplebucket.s3.amazonaws.com", "range": "bytes=0-9", "x-amz-content-sha256": empty, "x-amz-date": "20130524T000000Z"],
      payloadHash: empty, amzDate: "20130524T000000Z", key: BucketKey(accessID: "AKIAIOSFODNN7EXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
      region: "us-east-1", service: "s3")
    #expect(
      auth
        == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    )
    #expect(GCSClient.canonicalQuery([("prefix", "a b"), ("max-keys", "1")]) == "max-keys=1&prefix=a%20b")
    #expect(BucketObject.page("20261018-3fa2c1d0", 7) == "sources/20261018-3fa2c1d0/pages/0007.heic")
  }

  // 지어낸 두 쪽짜리 PDF 를 자료로 넣는다
  func intake(_ t: TempPlace) async throws -> SourceSummary {
    let pdf = t.root.appending(path: "inbox/Kinematics.pdf")
    SampleFiles.pdf(pdf, [.text("Displacement is a vector quantity measured in metres."), .text("Velocity is the rate of change of displacement.")])
    let m = JobManager(data: t.data, folders: t.folders)
    let id = try await m.submit(config: testConfig) {
      try SourceIntake.prepare(IntakeRequest(files: [pdf], labels: SourceLabels(grade: "DP1", subject: "Physics", level: "HL"), memo: nil), $0)
    }
    #expect(await m.waitForEnd(id).phase == "done")
    return try #require(SourceLibrary.load(t.data).sources.first)
  }

  @Test func 자료를_넣으면_보기용_쪽_이미지가_생기고_원본과_함께_올린다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let source = try await intake(t)
    // 보기용 쪽 이미지: HEIC, 긴 변 2000
    let view = SourcePages.viewImage(source.folder, page: 1, folders: t.folders)
    let image = try #require(CGImageSourceCreateWithURL(view as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    #expect(max(image.width, image.height) == 2000)

    let out = await SourceFiles.sync(SourceLibrary.load(t.data), folders: t.folders, client: client)
    #expect(out.error == nil)
    #expect(out.uploaded == 3)
    #expect(
      FakeGCS.objects(host).keys.sorted()
        == ["jindesk-files-dev/sources/\(source.id)/original.pdf", "jindesk-files-dev/sources/\(source.id)/pages/0001.heic", "jindesk-files-dev/sources/\(source.id)/pages/0002.heic"])
    #expect(FakeGCS.requests(host).allSatisfy { $0.auth.hasPrefix("AWS4-HMAC-SHA256 Credential=GOOG1TEST/") })

    // 다 올린 자료는 다시 묻지 않는다
    FakeGCS.reset(host)
    let again = await SourceFiles.sync(SourceLibrary.load(t.data), folders: t.folders, client: client)
    #expect(again.uploaded == 0)
    #expect(FakeGCS.requests(host).isEmpty)
  }

  @Test func 새_맥에서는_로컬에_없는_원본을_받고_쪽_이미지는_볼_때_받는다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let source = try await intake(t)
    _ = await SourceFiles.sync(SourceLibrary.load(t.data), folders: t.folders, client: client)
    let original = try Data(contentsOf: source.folder.url.appending(path: "original.pdf"))

    // 새 맥: 리포에서 받은 데이터 폴더에는 원본이 없고, 캐시도 비었다
    FileOps.remove(source.folder.url.appending(path: "original.pdf"))
    FileOps.remove(t.folders.cache)
    let fresh = AppFolders(support: t.root.appending(path: "support2"), cache: t.root.appending(path: "cache2"))
    // 원본이 없는 동안의 쪽 보기는 버킷에서 받는다
    let page = try await SourceFiles.viewImage(source, page: 2, folders: fresh, client: client)
    #expect(try Data(contentsOf: page) == FakeGCS.objects(host)["jindesk-files-dev/sources/\(source.id)/pages/0002.heic"])

    let out = await SourceFiles.sync(SourceLibrary.load(t.data), folders: fresh, client: client)
    #expect(out.downloaded == 1)
    #expect(try Data(contentsOf: source.folder.url.appending(path: "original.pdf")) == original)
  }

  @Test func 키가_틀리면_올리지_못하고_까닭을_남긴다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    _ = try await intake(t)
    FakeGCS.deny(host)
    let out = await SourceFiles.sync(SourceLibrary.load(t.data), folders: t.folders, client: client)
    #expect(out.uploaded == 0)
    #expect(out.error?.contains("키가 맞지 않거나") == true)
    #expect(!FileOps.exists(SourceFiles.doneFile(t.folders, bucket: "jindesk-files-dev")))
  }
}

// 가짜 GCS (S3 호환 API 의 HEAD, GET, PUT). 호스트마다 객체를 따로 둔다.
final class FakeGCS: URLProtocol, @unchecked Sendable {
  struct Store {
    var objects: [String: Data] = [:]
    var requests: [(method: String, path: String, auth: String)] = []
    var denied = false
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var stores: [String: Store] = [:]

  static func edit<T>(_ host: String, _ change: (inout Store) -> T) -> T {
    lock.withLock {
      var store = stores[host] ?? Store()
      defer { stores[host] = store }
      return change(&store)
    }
  }

  static func objects(_ host: String) -> [String: Data] { edit(host) { $0.objects } }
  static func requests(_ host: String) -> [(method: String, path: String, auth: String)] { edit(host) { $0.requests } }
  static func reset(_ host: String) { edit(host) { $0.requests = [] } }
  static func deny(_ host: String) { edit(host) { $0.denied = true } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let url = request.url!
    let method = request.httpMethod ?? "GET"
    let path = String((url.path.removingPercentEncoding ?? url.path).dropFirst())
    let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
    let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
    let (code, data): (Int, Data) = Self.edit(url.host ?? "") { store in
      store.requests.append((method, path, auth))
      if store.denied { return (403, Data()) }
      switch method {
      case "HEAD": return (store.objects[path] == nil ? 404 : 200, Data())
      case "GET": return store.objects[path].map { (200, $0) } ?? (404, Data())
      case "PUT":
        store.objects[path] = body
        return (200, Data())
      default: return (400, Data())
      }
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  static func read(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while stream.hasBytesAvailable {
      let n = stream.read(&buffer, maxLength: buffer.count)
      if n <= 0 { break }
      data.append(buffer, count: n)
    }
    return data
  }
}
