// 계정 사용량 (5시간 한도, 주간 한도). claude -p 의 stream-json 에 섞여 오는 rate_limit_event 에서 읽는다.
// 문서로 정해진 모양이 아니라 실행 기록에서 본 모양이라, 읽지 못하면 없는 것으로 둔다.
import Foundation

public struct UsageWindow: Sendable, Codable, Equatable {
  // 쓴 비율 (0~1)
  public let utilization: Double
  // 초기화되는 시각 (유닉스 초)
  public let resetsAt: Double

  public init(utilization: Double, resetsAt: Double) {
    self.utilization = utilization
    self.resetsAt = resetsAt
  }

  public var resetDate: Date { Date(timeIntervalSince1970: resetsAt) }
  public var percent: Int { Int((utilization * 100).rounded()) }

  // 초기화 시각이 아직 오지 않았으면 이 값이 지금 창의 값이다. 지났으면 지금 값을 모른다.
  public func isCurrent(at now: Date = Date()) -> Bool { resetDate > now }
}

public struct UsageReading: Sendable, Codable, Equatable {
  public var fiveHour: UsageWindow?
  public var sevenDay: UsageWindow?
  // 받은 시각 (ISO 8601)
  public var at: String

  public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, at: String) {
    self.fiveHour = fiveHour
    self.sevenDay = sevenDay
    self.at = at
  }

  public var receivedAt: Date? { Clock.parse(at) }

  // {"type":"rate_limit_event","rate_limit_info":{…,"unifiedWindows":{"five_hour":{"utilization":0.3,"resetsAt":…},"seven_day":{…}}}}
  public static func parse(_ event: JSONValue, at: String = Clock.isoLocal()) -> UsageReading? {
    guard event["type"]?.stringValue == "rate_limit_event", let windows = event["rate_limit_info"]?["unifiedWindows"] else { return nil }
    func window(_ v: JSONValue?) -> UsageWindow? {
      guard let u = v?["utilization"]?.numberValue, let r = v?["resetsAt"]?.numberValue, u.isFinite, r > 0 else { return nil }
      return UsageWindow(utilization: u, resetsAt: r)
    }
    let reading = UsageReading(fiveHour: window(windows["five_hour"]), sevenDay: window(windows["seven_day"]), at: at)
    return reading.fiveHour == nil && reading.sevenDay == nil ? nil : reading
  }

  // 마지막으로 받은 값 (앱 지원 폴더의 usage.json). 앱과 명령줄이 같이 쓴다.
  public static func load(_ folders: AppFolders) -> UsageReading? {
    guard let data = try? Data(contentsOf: folders.usageFile) else { return nil }
    return try? JSONDecoder().decode(UsageReading.self, from: data)
  }

  func save(_ folders: AppFolders) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(self) else { return }
    try? FileOps.write(data, to: folders.usageFile)
  }

  // 두 값 가운데 늦게 받은 것
  static func newer(_ a: UsageReading?, _ b: UsageReading?) -> UsageReading? {
    guard let a else { return b }
    guard let b else { return a }
    return (b.receivedAt ?? .distantPast) >= (a.receivedAt ?? .distantPast) ? b : a
  }

  // 실행 요약에 넣을 모양
  var json: JSONValue {
    func window(_ w: UsageWindow?) -> JSONValue {
      guard let w else { return .null }
      return .object(["utilization": .number(w.utilization), "resets_at": .number(w.resetsAt)])
    }
    return .object(["five_hour": window(fiveHour), "seven_day": window(sevenDay), "at": .string(at)])
  }
}
