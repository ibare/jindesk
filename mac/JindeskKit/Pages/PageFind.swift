// 학습 페이지 안 찾기의 상태 (DECISIONS.md 48). 맥의 찾기 막대와 폰의 찾기 막대가 함께 쓴다.
// 막대가 요청을 만들면 학습 페이지 보기가 렌더러의 window.jindesk.find 에 보내고, 렌더러가 찾은 곳 수와 지금 몇 번째를 알린다.
import Foundation

// 렌더러에 보낼 요청. 요청마다 id 가 달라 같은 요청을 두 번 보내지 않는다
public struct FindRequest: Equatable, Sendable {
  public let id = UUID()
  public let query: String
  // 처음 내려갈 단위 (찾기 결과에서 연 개념)
  public let unit: String?
  // 0 처음, 1 다음, -1 이전
  public let step: Int

  public init(query: String, unit: String? = nil, step: Int = 0) {
    self.query = query
    self.unit = unit
    self.step = step
  }

  // window.jindesk.find 의 인자. keep 은 다시 그린 뒤 지금 곳을 지킨 채 다시 걸 때
  public func script(keep: Bool = false) -> String {
    var o: [String: JSONValue] = ["query": .string(query), "step": .number(Double(step))]
    if let unit { o["unit"] = .string(unit) }
    if keep { o["keep"] = .bool(true) }
    return "window.jindesk.find(\(JSONText.line(.object(o)).trimmingCharacters(in: .whitespacesAndNewlines)))"
  }

  public static let clear = "window.jindesk.find({query: \"\"})"
}

public struct PageFind: Equatable, Sendable {
  // 이 개념의 학습 페이지에서 찾는다. 다른 개념을 열면 막대가 닫힌다
  public let concept: String
  public private(set) var query: String
  public private(set) var request: FindRequest
  // 모두 몇 곳, 지금 몇 번째 (렌더러가 알린다. 없으면 0)
  public var total = 0
  public var index = 0
  // 막대의 찾을 말 칸에 커서를 둔다. 오를 때마다 칸이 받는다
  public var focus = 0

  public init(concept: String, query: String = "", unit: String? = nil) {
    self.concept = concept
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    self.query = q
    request = FindRequest(query: q, unit: unit)
  }

  // 찾을 말이 바뀌면 처음부터 다시 찾는다
  public mutating func setQuery(_ text: String) {
    let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard q != query else { return }
    query = q
    request = FindRequest(query: q)
    if q.isEmpty { (total, index) = (0, 0) }
  }

  // 다음(1)·이전(-1)
  public mutating func step(_ by: Int) {
    guard !query.isEmpty, total > 0 else { return }
    request = FindRequest(query: query, step: by)
  }

  // 막대에 보일 "지금 / 모두"
  public var countLabel: String {
    guard !query.isEmpty else { return "" }
    return total == 0 ? "없음" : "\(index) / \(total)"
  }
}
