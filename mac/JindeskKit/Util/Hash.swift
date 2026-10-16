import CryptoKit
import Foundation

// sha256. 저장은 앞 16자다 (DATA.md 의 해시). 파일 대조는 전체 값을 쓴다.
public enum Hash {
  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func short(_ data: Data) -> String {
    String(sha256(data).prefix(16))
  }

  // 큰 파일도 메모리에 다 올리지 않고 조각으로 읽는다
  public static func file(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
