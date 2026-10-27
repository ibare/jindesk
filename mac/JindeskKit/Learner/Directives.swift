// 요구 (learner/directives.jsonl, REGENERATION.md). "더 쉽게", "더 자세히" 같은 요구는 한 번 쓰고 버리는 프롬프트가 아니라 기록에 남는 데이터다.
// 덧붙이기만 한다. 상태가 바뀌면 같은 id 의 줄을 더한다. 살아 있는 요구(applied, accepted)는 그 단위를 다시 만드는 모든 작업에 들어간다.
import Foundation

public enum DirectiveOp: String, Sendable, CaseIterable {
  case easy, detail, example, visual, redraw, steps, fix

  // 대상 단위 뒤에 새 단위를 더하는 방식 (나머지는 곁 층이거나 대상 단위의 새 판)
  public var inserts: Bool { self == .example || self == .visual }

  public var label: String {
    switch self {
    case .easy: "더 쉽게"
    case .detail: "더 자세히"
    case .example: "예시 더"
    case .visual: "그림으로"
    case .redraw: "그림 다시"
    case .steps: "단계 더"
    case .fix: "고치기"
    }
  }

  // 결과가 놓이는 곳 · 그대로인 것 · 검사 (다시 만들기 시트의 설명)
  public var explanation: String {
    switch self {
    case .easy: "곁 층 \"쉽게\"로 단위 아래에 펼칩니다 · 원래 설명은 그대로 · 조건과 주장 유지, 새 주장 없음, MYP 독자 시험, 숫자·기호 대조"
    case .detail: "단위의 새 판 후보를 만들어 견주어 고릅니다 · 받아들이기 전까지 그대로 · 원래 주장 모두 포함, 새 주장은 출처나 보충 표시, 격리 검증, 과목 수준 독자 시험"
    case .example: "단위 뒤에 풀이나 확인 문제를 더합니다 · 원래 단위는 그대로 · 답을 계산으로 확인"
    case .visual: "단위 뒤에 그림 블록 후보를 만들어 견주어 고릅니다 · 원래 단위는 그대로 · 돌아가는지 확인"
    case .redraw: "그림 블록의 새 판 후보를 만듭니다 · 이전 판은 남습니다 · 돌아가는지 확인"
    case .steps: "풀이 블록의 새 판 후보(단계를 더 잘게)를 만듭니다 · 받아들이기 전까지 그대로 · 단계마다 계산 확인, 마지막 식 그대로"
    case .fix: "원문 단위가 틀렸다고 알립니다 · 두 에이전트가 따로 자료와 대조해 둘 다 틀렸다고 하면 원문을 고칩니다 · 아니면 근거를 답글로 답니다"
    }
  }

  // 새 판을 학생이 견주어 고르는 방식
  public var needsChoice: Bool { self == .detail || self == .visual || self == .redraw || self == .steps }
}

public enum DirectiveStatus: String, Sendable {
  case requested, candidate, applied, accepted, kept, failed, recheck

  public var label: String {
    switch self {
    case .requested: "요청함"
    case .candidate: "새 판 · 비교"
    case .applied: "반영됨"
    case .accepted: "받아들임"
    case .kept: "지금 판 유지"
    case .failed: "만들지 못함"
    case .recheck: "원문이 바뀌어 다시 확인"
    }
  }

  public var isLiving: Bool { self == .applied || self == .accepted }
}

public struct DirectiveTarget: Sendable, Equatable {
  public var concept: String
  public var unit: String
  public let rev: Int

  public init(concept: String, unit: String, rev: Int) {
    self.concept = concept
    self.unit = unit
    self.rev = rev
  }

  var json: JSONValue { .object(["concept": .string(concept), "unit": .string(unit), "rev": .number(Double(rev))]) }

  init?(json: JSONValue?) {
    guard let j = json, let c = j["concept"]?.stringValue, let u = j["unit"]?.stringValue else { return nil }
    self.init(concept: c, unit: u, rev: j["rev"]?.numberValue.map { Int($0) } ?? 1)
  }
}

public struct Directive: Sendable, Equatable, Identifiable {
  public let id: String
  public let at: String
  public let op: DirectiveOp
  public var target: DirectiveTarget
  public let note: String?
  public let fromComment: String?
  public var status: DirectiveStatus
  public var job: String?
  // 반영·받아들인 결과가 놓인 단위 (예시 더, 그림으로 는 새 단위)
  public var result: String?
  public var updatedAt: String
  // 대상이 단위를 옮긴 줄을 따라 왔다 (다시 정리, DECISIONS.md 47). 파일에 쓰지 않고 불러올 때 정한다
  public var moved = false
}

public enum DirectiveStore {
  public static func file(_ data: DataFolder) -> URL { data.learner.appending(path: "directives.jsonl") }

  // 줄을 접어 요구마다 마지막 상태로. 대상은 옮겨진 개념과 단위를 따라 지금 자리로 바꾼다 (DECISIONS.md 47).
  public static func load(_ data: DataFolder) -> [Directive] {
    var resolver = AnchorResolver(data, moves: Moves.all(data))
    var out: [String: Directive] = [:]
    var order: [String] = []
    for v in (try? JSONLines.read(file(data)))?.values ?? [] {
      guard let id = v["id"]?.stringValue else { continue }
      if var d = out[id] {
        if let s = v["status"]?.stringValue.flatMap(DirectiveStatus.init(rawValue:)) { d.status = s }
        if let j = v["job"]?.stringValue { d.job = j }
        if let r = v["result"]?.stringValue { d.result = r }
        d.updatedAt = v["at"]?.stringValue ?? d.updatedAt
        out[id] = d
      } else if let op = v["op"]?.stringValue.flatMap(DirectiveOp.init(rawValue:)), var target = DirectiveTarget(json: v["target"]) {
        let r = resolver.resolve(concept: target.concept, unit: target.unit)
        target.concept = r.concept
        target.unit = r.unit
        let at = v["at"]?.stringValue ?? ""
        out[id] = Directive(
          id: id, at: at, op: op, target: target, note: v["note"]?.stringValue, fromComment: v["from_comment"]?.stringValue,
          status: v["status"]?.stringValue.flatMap(DirectiveStatus.init(rawValue:)) ?? .requested, job: v["job"]?.stringValue, result: v["result"]?.stringValue,
          updatedAt: at, moved: r.moved)
        order.append(id)
      }
    }
    return order.compactMap { out[$0] }
  }

  static let lock = NSLock()

  // 새 요구. id 는 d<n> (데이터 폴더 안에서 유일)
  public static func request(_ data: DataFolder, op: DirectiveOp, target: DirectiveTarget, note: String?, fromComment: String?) throws -> Directive {
    try lock.withLock {
      let n = (load(data).compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
      let id = "d\(n)"
      let at = Clock.isoLocal()
      var o: [String: JSONValue] = [
        "v": .number(1), "id": .string(id), "at": .string(at), "by": .string("learner"), "op": .string(op.rawValue), "target": target.json,
        "status": .string(DirectiveStatus.requested.rawValue),
      ]
      if let note = note?.nilIfBlank { o["note"] = .string(note) }
      if let fromComment { o["from_comment"] = .string(fromComment) }
      try FileOps.appendLine(JSONText.line(.object(o)), to: file(data))
      return Directive(
        id: id, at: at, op: op, target: target, note: note?.nilIfBlank, fromComment: fromComment, status: .requested, job: nil, result: nil, updatedAt: at)
    }
  }

  public static func update(_ data: DataFolder, id: String, status: DirectiveStatus, job: String? = nil, result: String? = nil, extra: [String: JSONValue] = [:]) throws {
    var o: [String: JSONValue] = ["v": .number(1), "id": .string(id), "at": .string(Clock.isoLocal()), "status": .string(status.rawValue)]
    if let job { o["job"] = .string(job) }
    if let result { o["result"] = .string(result) }
    for (k, v) in extra { o[k] = v }
    try FileOps.appendLine(JSONText.line(.object(o)), to: file(data))
  }

  public static func forConcept(_ all: [Directive], concept: String) -> [Directive] {
    all.filter { $0.target.concept == concept }
  }
}
