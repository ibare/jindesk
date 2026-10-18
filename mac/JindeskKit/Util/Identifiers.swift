import Foundation

// 작업 id: YYYYMMDD-HHMM-<짧은-슬러그> (DATA.md 의 id)
public enum JobID {
  public static let pattern = try! NSRegularExpression(pattern: #"^\d{8}-\d{4}-[a-z0-9]+(?:-[a-z0-9]+)*$"#)

  public static func isValid(_ id: String) -> Bool {
    pattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
  }

  // 영어 소문자, 숫자, - 만 남긴다
  public static func slugify(_ source: String, maxLength: Int = 40) -> String {
    let lowered = source.lowercased().decomposedStringWithCompatibilityMapping
    var out = ""
    var lastDash = false
    for scalar in lowered.unicodeScalars {
      if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
        out.unicodeScalars.append(scalar)
        lastDash = false
      } else if !lastDash {
        out.append("-")
        lastDash = true
      }
    }
    out = String(out.drop { $0 == "-" })
    while out.hasSuffix("-") { out.removeLast() }
    out = String(out.prefix(maxLength))
    while out.hasSuffix("-") { out.removeLast() }
    return out
  }

  // 이미 쓰인 id 면 끝에 -2, -3 ... 을 붙인다
  public static func make(date: Date, slugSource: String, exists: (String) -> Bool) throws -> String {
    let base = "\(stamp(date))-\(slugify(slugSource).nilIfEmpty ?? "job")"
    if !exists(base) { return base }
    for n in 2..<100 where !exists("\(base)-\(n)") { return "\(base)-\(n)" }
    throw RequestError("작업 id 를 만들 수 없습니다: \(base)")
  }

  // YYYYMMDD-HHMM (로컬 시간)
  public static func stamp(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return String(format: "%04d%02d%02d-%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
  }
}

// 사용자 입력이 잘못되어 요청을 받을 수 없을 때. 화면에 그대로 보여 준다.
public struct RequestError: LocalizedError, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

// 도구나 파일 처리가 실패했을 때
public struct ToolError: LocalizedError, Sendable {
  public let message: String
  // 사람이 읽을 부분 (표준 오류)
  public let stderr: String

  public init(_ message: String, stderr: String = "") {
    self.message = message
    self.stderr = stderr
  }

  public var errorDescription: String? { message }
}

public enum Clock {
  // 로컬 시간대 오프셋을 포함한 ISO 8601 (예: 2026-10-09T11:50:00+09:00)
  public static func isoLocal(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let offset = timeZone.secondsFromGMT(for: date) / 60
    let sign = offset >= 0 ? "+" : "-"
    return String(
      format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, sign, abs(offset) / 60,
      abs(offset) % 60)
  }

  public static func parse(_ iso: String) -> Date? {
    if let d = try? Date(iso, strategy: .iso8601) { return d }
    return try? Date(iso, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
  }

  // YYYY-MM (실행 요약 파일 이름)
  public static func month(_ date: Date = Date()) -> String {
    let c = Calendar.current.dateComponents([.year, .month], from: date)
    return String(format: "%04d-%02d", c.year!, c.month!)
  }
}

extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }

  public var nilIfBlank: String? {
    let t = trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
  }
}
