import Foundation
import Security

// 로그인 키체인의 일반 암호 항목. 앱과 명령줄 모드가 같은 실행 파일이라 접근 승인을 한 번만 받는다.
// 접근 허용은 서명의 지정 요구사항(Developer ID 팀, 번들 id)에 묶이므로, 같은 서명의 새 판은 승인 창 없이 읽는다.
public enum Keychain {
  public struct Failure: LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? {
      let text = SecCopyErrorMessageString(status, nil) as String? ?? "알 수 없는 오류"
      return "키체인 오류 \(status): \(text)"
    }
  }

  static func query(service: String, account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  public static func read(service: String, account: String) throws -> String? {
    var q = query(service: service, account: account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw Failure(status: status) }
    return String(decoding: data, as: UTF8.self)
  }

  // 항목이 있는지만 본다. 값은 읽지 않는다.
  public static func exists(service: String, account: String) -> Bool {
    var q = query(service: service, account: account)
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
  }

  public static func write(service: String, account: String, value: String, label: String? = nil) throws {
    let data = Data(value.utf8)
    let update = SecItemUpdate(query(service: service, account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw Failure(status: update) }
    var q = query(service: service, account: account)
    q[kSecValueData as String] = data
    if let label { q[kSecAttrLabel as String] = label }
    let status = SecItemAdd(q as CFDictionary, nil)
    guard status == errSecSuccess else { throw Failure(status: status) }
  }

  public static func delete(service: String, account: String) throws {
    let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
  }
}

// Jindesk 가 쓰는 키체인 항목 (SETUP.md 의 "Claude 토큰을 키체인에 넣기")
public enum ClaudeToken {
  public static let service = "com.mintae.Jindesk"
  public static let account = "claude-oauth-token"
  public static let label = "Jindesk Claude 토큰"

  public static var exists: Bool { Keychain.exists(service: service, account: account) }

  public static func read() throws -> String? {
    try Keychain.read(service: service, account: account)?.nilIfBlank
  }

  public static func save(_ token: String) throws {
    guard let value = token.nilIfBlank else { throw RequestError("토큰이 비어 있습니다") }
    try Keychain.write(service: service, account: account, value: value, label: label)
  }

  public static func delete() throws {
    try Keychain.delete(service: service, account: account)
  }
}
