// 자료 버킷 (DATA.md 의 자료 버킷, DECISIONS.md 31). 원본 자료와 쪽 이미지를 git 리포가 아니라 GCS 버킷에 둔다.
// GCS 의 S3 호환 API 에 HMAC 키로 서명한 요청(AWS SigV4, 리전 auto)을 보낸다. 서버를 두지 않는다.
// 맥은 쓰기용 키, 폰은 읽기 전용 키를 쓴다. 이 파일은 맥 전용 코드에 기대지 않는다 (폰 앱도 빌드한다).
import CryptoKit
import Foundation

// 앱 설정에서 연결한 버킷 (개발 맥과 학생 맥이 다르다)
public struct BucketLink: Sendable, Equatable, Codable {
  public var name: String

  public init(name: String) {
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// 서비스 계정의 HMAC 키
public struct BucketKey: Sendable, Equatable, Codable {
  public let accessID: String
  public let secret: String

  public init(accessID: String, secret: String) {
    self.accessID = accessID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// 버킷 키를 둘 키체인 항목. 접근 id 와 비밀을 함께 둔다.
public struct BucketKeyStore: Sendable {
  public let service: String
  public let account: String

  public init(service: String, account: String) {
    self.service = service
    self.account = account
  }

  public var exists: Bool { Keychain.exists(service: service, account: account) }

  public func read() -> BucketKey? {
    guard let text = (try? Keychain.read(service: service, account: account)) ?? nil else { return nil }
    return try? JSONDecoder().decode(BucketKey.self, from: Data(text.utf8))
  }

  public func save(_ key: BucketKey) throws {
    guard !key.accessID.isEmpty, !key.secret.isEmpty else { throw BucketError("접근 id 와 비밀을 모두 넣습니다") }
    let text = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
    try Keychain.write(service: service, account: account, value: text, label: "Jindesk 자료 버킷 키")
  }

  public func delete() throws {
    try Keychain.delete(service: service, account: account)
  }

  // 맥의 쓰기용 키 (SETUP.md 의 자료 버킷)
  public static let mac = BucketKeyStore(service: ClaudeToken.service, account: "files-bucket-key")
}

public struct BucketError: LocalizedError, Sendable, Equatable {
  public let message: String
  // HTTP 상태 (요청이 닿았을 때)
  public var status: Int?
  public init(_ message: String, status: Int? = nil) {
    self.message = message
    self.status = status
  }
  public var errorDescription: String? { message }
}

// 버킷의 객체 이름 (DATA.md 의 자료 버킷). 데이터 폴더와 같은 경로를 쓴다.
public enum BucketObject {
  public static func file(_ source: String, _ name: String) -> String { "sources/\(source)/\(name)" }

  // 맥과 폰이 보는 쪽 이미지 (HEIC, 긴 변 2000)
  public static func page(_ source: String, _ page: Int) -> String { "sources/\(source)/pages/\(String(format: "%04d", page)).heic" }
}

public struct GCSClient: Sendable {
  public let bucket: String
  let key: BucketKey
  let session: URLSession
  let endpoint: URL

  public init(bucket: String, key: BucketKey, session: URLSession = .shared, endpoint: URL = URL(string: "https://storage.googleapis.com")!) {
    self.bucket = bucket
    self.key = key
    self.session = session
    self.endpoint = endpoint
  }

  // 있으면 true, 없으면 false
  public func exists(_ object: String) async throws -> Bool {
    let (_, status) = try await send("HEAD", object: object)
    switch status {
    case 200: return true
    case 404: return false
    default: throw Self.failure(status, object)
    }
  }

  public func get(_ object: String) async throws -> Data {
    let (body, status) = try await send("GET", object: object)
    guard status == 200 else { throw Self.failure(status, object) }
    return body
  }

  public func put(_ object: String, data: Data, contentType: String) async throws {
    let (_, status) = try await send("PUT", object: object, body: data, contentType: contentType)
    guard status == 200 else { throw Self.failure(status, object) }
  }

  // 버킷에 닿는지 (환경 점검): 객체 하나를 나열해 본다
  public func check() async throws {
    let (_, status) = try await send("GET", object: nil, query: [("max-keys", "1")])
    guard status == 200 else { throw Self.failure(status, bucket) }
  }

  static func failure(_ status: Int, _ what: String) -> BucketError {
    switch status {
    case 401, 403: BucketError("자료 버킷의 키가 맞지 않거나 권한이 없습니다 (\(what))", status: status)
    case 404: BucketError("자료 버킷이나 객체를 찾지 못했습니다 (\(what))", status: status)
    default: BucketError("자료 버킷 응답 \(status) (\(what))", status: status)
    }
  }

  private func send(_ method: String, object: String?, query: [(String, String)] = [], body: Data = Data(), contentType: String? = nil) async throws -> (Data, Int) {
    let path = "/" + Self.encode(bucket) + (object.map { "/" + $0.split(separator: "/", omittingEmptySubsequences: false).map { Self.encode(String($0)) }.joined(separator: "/") } ?? "")
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    components.percentEncodedPath = path
    if !query.isEmpty { components.percentEncodedQuery = Self.canonicalQuery(query) }
    var request = URLRequest(url: components.url!, timeoutInterval: 120)
    request.httpMethod = method
    let host = endpoint.host ?? "storage.googleapis.com"
    let date = Self.amzDate(Date())
    let payload = Self.hex(SHA256.hash(data: body))
    var headers = ["host": host, "x-amz-date": date, "x-amz-content-sha256": payload]
    if let contentType { headers["content-type"] = contentType }
    let auth = Self.authorization(
      method: method, path: path, query: query, headers: headers, payloadHash: payload, amzDate: date, key: key, region: "auto", service: "s3")
    for (name, value) in headers where name != "host" { request.setValue(value, forHTTPHeaderField: name) }
    request.setValue(auth, forHTTPHeaderField: "Authorization")
    if method == "PUT" { request.httpBody = body }
    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw BucketError("자료 버킷에 닿지 못했습니다: \(error.localizedDescription)")
    }
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  // MARK: - SigV4

  // AWS SigV4 서명의 Authorization 머리. headers 는 이름을 소문자로 준다 (host 포함).
  static func authorization(
    method: String, path: String, query: [(String, String)], headers: [String: String], payloadHash: String, amzDate: String, key: BucketKey,
    region: String, service: String
  ) -> String {
    let names = headers.keys.sorted()
    let canonicalHeaders = names.map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
    let signedHeaders = names.joined(separator: ";")
    let canonical = [method, path, canonicalQuery(query), canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
    let day = String(amzDate.prefix(8))
    let scope = "\(day)/\(region)/\(service)/aws4_request"
    let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
    var signing = SymmetricKey(data: Data("AWS4\(key.secret)".utf8))
    for part in [day, region, service, "aws4_request"] {
      signing = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: signing)))
    }
    let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: signing))
    return "AWS4-HMAC-SHA256 Credential=\(key.accessID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
  }

  static func canonicalQuery(_ query: [(String, String)]) -> String {
    let pairs: [(name: String, value: String)] = query.map { (encode($0.0), encode($0.1)) }
    let sorted = pairs.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
    return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
  }

  // RFC 3986 의 예약하지 않은 글자만 그대로 둔다
  static func encode(_ text: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
  }

  static func amzDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return f.string(from: date)
  }

  static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
