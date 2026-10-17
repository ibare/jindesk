// 에이전트의 외부 호출(WebSearch, WebFetch) 검사. 웹 도구는 관점 붙이기의 레퍼런스 찾기에만 준다.
// 로컬·사설망 주소를 조회하려 하면 막는다.
// 로컬 주소를 막는 이유: 웹 조회가 이 맥에서 직접 나가므로, 막지 않으면 이 맥의 다른 서비스나 지난 기록에 닿을 수 있다.
import Foundation

public enum ExternalCallCheck {
  // 이름으로 알 수 있는 로컬 호스트. 주소(IPv4, IPv6)는 바이트로 바꿔 isPrivateAddress 로 판정한다.
  static let localNamePatterns: [NSRegularExpression] = [
    #"^localhost$"#,
    #"\.localhost$"#,
    #"\.local$"#,
    #"\.internal$"#,
    #"\.home\.arpa$"#,
  ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

  // 막을 이유를 돌려준다. 괜찮으면 nil.
  public static func blockReason(tool: String, input: JSONValue?) -> String? {
    guard tool == "WebFetch", let outbound = input?["url"]?.looseString, !outbound.isEmpty else { return nil }
    guard let components = URLComponents(string: outbound), let scheme = components.scheme?.lowercased() else {
      return "주소를 해석할 수 없어 막았다: \(outbound)"
    }
    guard scheme == "http" || scheme == "https" else {
      return "http(s) 가 아닌 주소는 조회할 수 없다: \(scheme):"
    }
    guard let rawHost = components.host, !rawHost.isEmpty else {
      return "주소를 해석할 수 없어 막았다: \(outbound)"
    }
    guard let host = normalizedHost(rawHost), let local = isLocal(host) else {
      return "주소를 해석할 수 없어 막았다: \(outbound)"
    }
    if local {
      return "로컬·사설망 주소(\(host))는 조회할 수 없다. 공개된 외부 자료만 조회한다."
    }
    return nil
  }

  // 로컬·사설망이면 true, 공개 주소나 이름이면 false. 주소처럼 보이지만 해석할 수 없으면 nil.
  static func isLocal(_ host: String) -> Bool? {
    let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    if bare.contains(":") {
      guard let bytes = ipv6Bytes(bare) else { return nil }
      return isLocalIPv6(bytes)
    }
    if let bytes = ipv4Bytes(bare) { return isLocalIPv4(bytes) }
    let range = NSRange(bare.startIndex..., in: bare)
    return localNamePatterns.contains { $0.firstMatch(in: bare, range: range) != nil }
  }

  static func ipv4Bytes(_ s: String) -> [UInt8]? {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    let bytes = parts.compactMap { UInt8($0) }
    return bytes.count == 4 ? bytes : nil
  }

  // inet_pton 으로 16바이트로 바꾼다. 영역 표시(%en0)가 붙은 주소는 해석하지 않는다(막는다).
  static func ipv6Bytes(_ s: String) -> [UInt8]? {
    var addr = in6_addr()
    guard inet_pton(AF_INET6, s, &addr) == 1 else { return nil }
    return withUnsafeBytes(of: &addr) { Array($0) }
  }

  // 사설·특수 용도 IPv4 (RFC 6890 중 웹에서 닿으면 안 되는 범위)
  static func isLocalIPv4(_ b: [UInt8]) -> Bool {
    switch (b[0], b[1], b[2]) {
    case (0, _, _), (10, _, _), (127, _, _): return true
    case (100, 64...127, _): return true  // 통신사 공유 주소(CGNAT, Tailscale 등)
    case (169, 254, _): return true  // 링크 로컬
    case (172, 16...31, _): return true
    case (192, 168, _): return true
    case (192, 0, 0): return true  // IETF 프로토콜 할당
    case (198, 18...19, _): return true  // 성능 시험망
    case (224...255, _, _): return true  // 멀티캐스트, 예약, 브로드캐스트
    default: return false
    }
  }

  static func isLocalIPv6(_ b: [UInt8]) -> Bool {
    let zeros10 = b[0..<10].allSatisfy { $0 == 0 }
    // :: 와 ::1
    if zeros10 && b[10] == 0 && b[11] == 0 && b[12..<15].allSatisfy({ $0 == 0 }) && (b[15] == 0 || b[15] == 1) { return true }
    // IPv4 대응(::ffff:a.b.c.d)과 IPv4 호환(::a.b.c.d): 뒤 4바이트를 IPv4 규칙으로
    if zeros10 && ((b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0)) { return isLocalIPv4(Array(b[12..<16])) }
    // NAT64 (64:ff9b::/96) 도 뒤 4바이트가 IPv4 다. 지역용 NAT64 (64:ff9b:1::/48) 는 막는다.
    if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b {
      if b[4] == 0 && b[5] == 1 { return true }
      if b[4..<12].allSatisfy({ $0 == 0 }) { return isLocalIPv4(Array(b[12..<16])) }
    }
    // 6to4 (2002::/16) 는 2~5바이트가 IPv4 다
    if b[0] == 0x20 && b[1] == 0x02 { return isLocalIPv4(Array(b[2..<6])) }
    if b[0] & 0xfe == 0xfc { return true }  // 고유 로컬 fc00::/7
    if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true }  // 링크 로컬 fe80::/10
    if b[0] == 0xfe && b[1] & 0xc0 == 0xc0 { return true }  // 사이트 로컬 fec0::/10 (폐지됐지만 막는다)
    if b[0] == 0xff { return true }  // 멀티캐스트
    return false
  }

  // 브라우저(WHATWG URL)처럼 호스트를 정규화한다. 소문자로 바꾸고 끝의 점을 떼며,
  // 2130706433, 0x7f.1, 0177.0.0.1 같은 숫자 IPv4 표기를 점 네 개 표기로 바꾼다. IPv4 로 보이지만 해석할 수 없으면 nil.
  static func normalizedHost(_ raw: String) -> String? {
    var host = raw.lowercased()
    if host.hasPrefix("[") || host.contains(":") { return host }
    while host.hasSuffix(".") { host.removeLast() }
    if host.isEmpty { return nil }

    let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard let last = parts.last, ipv4Number(last) != nil || last.allSatisfy(\.isNumber) else { return host }
    let numbers = parts.map(ipv4Number)
    guard numbers.count <= 4, numbers.allSatisfy({ $0 != nil }) else { return nil }
    let values = numbers.map { $0! }
    for v in values.dropLast() where v > 255 { return nil }
    let tailBytes = 4 - (values.count - 1)
    guard values.last! < (UInt64(1) << (8 * UInt64(tailBytes))) else { return nil }
    var address = values.last!
    for (i, v) in values.dropLast().enumerated() { address += v << (8 * UInt64(3 - i)) }
    return (0..<4).map { String((address >> (8 * UInt64(3 - $0))) & 0xff) }.joined(separator: ".")
  }

  static func ipv4Number(_ part: String) -> UInt64? {
    if part.isEmpty { return nil }
    if part.hasPrefix("0x") {
      let digits = part.dropFirst(2)
      return digits.isEmpty ? 0 : UInt64(digits, radix: 16)
    }
    if part.count > 1 && part.hasPrefix("0") { return UInt64(part.dropFirst(), radix: 8) }
    return UInt64(part, radix: 10)
  }
}
