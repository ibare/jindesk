// 학생의 코멘트 (learner/comments.jsonl, DATA.md 와 PAGES.md 의 코멘트). 덧붙이기만 한다. 지우기는 kind: delete 줄을 더한다.
// 종류: memo(메모), ask(질문 → 물어보기 작업이 답한다), flag(이상해요), answer(답글), delete.
// 자리는 단위 id, 판, 인용(영어 원문의 앞부분)으로 찾는다. 개념이 옮겨졌으면 library/moves.jsonl 로 새 id 를 찾는다.
import Foundation

public enum CommentKind: String, Sendable, CaseIterable {
  case memo, ask, flag, answer, delete

  public var label: String {
    switch self {
    case .memo: "메모"
    case .ask: "질문"
    case .flag: "이상해요"
    case .answer: "답"
    case .delete: "지움"
    }
  }
}

public struct CommentAnchor: Sendable, Equatable {
  public var concept: String
  public var unit: String
  public var rev: Int
  public let quote: String

  public init(concept: String, unit: String, rev: Int, quote: String) {
    self.concept = concept
    self.unit = unit
    self.rev = rev
    self.quote = quote
  }

  var json: JSONValue {
    .object(["concept": .string(concept), "unit": .string(unit), "rev": .number(Double(rev)), "quote": .string(quote)])
  }

  init?(json: JSONValue?) {
    guard let j = json, let c = j["concept"]?.stringValue, let u = j["unit"]?.stringValue else { return nil }
    self.init(concept: c, unit: u, rev: j["rev"]?.numberValue.map { Int($0) } ?? 1, quote: j["quote"]?.stringValue ?? "")
  }
}

public struct Comment: Sendable, Equatable, Identifiable {
  public let id: String
  public let at: String
  // learner 또는 job:<종류>
  public let by: String
  public let kind: CommentKind
  public var anchor: CommentAnchor?
  public let text: String?
  public let replyTo: String?
  public let job: String?
  public let textEn: String?
  public let textKo: String?
  public let src: [String]
  // 자료 밖 설명이 들어간 답
  public let supplementary: Bool
  public let target: String?

  public init(
    id: String, at: String, by: String, kind: CommentKind, anchor: CommentAnchor? = nil, text: String? = nil, replyTo: String? = nil, job: String? = nil,
    textEn: String? = nil, textKo: String? = nil, src: [String] = [], supplementary: Bool = false, target: String? = nil
  ) {
    self.id = id
    self.at = at
    self.by = by
    self.kind = kind
    self.anchor = anchor
    self.text = text
    self.replyTo = replyTo
    self.job = job
    self.textEn = textEn
    self.textKo = textKo
    self.src = src
    self.supplementary = supplementary
    self.target = target
  }

  var json: JSONValue {
    var o: [String: JSONValue] = ["v": .number(1), "id": .string(id), "at": .string(at), "by": .string(by), "kind": .string(kind.rawValue)]
    if let anchor { o["anchor"] = anchor.json }
    if let text { o["text"] = .string(text) }
    if let replyTo { o["reply_to"] = .string(replyTo) }
    if let job { o["job"] = .string(job) }
    if let textEn { o["text_en"] = .string(textEn) }
    if let textKo { o["text_ko"] = .string(textKo) }
    if !src.isEmpty { o["src"] = .array(src.map(JSONValue.string)) }
    if supplementary { o["supplementary"] = .bool(true) }
    if let target { o["target"] = .string(target) }
    return .object(o)
  }

  init?(json v: JSONValue) {
    guard let id = v["id"]?.stringValue, let kind = v["kind"]?.stringValue.flatMap(CommentKind.init(rawValue:)) else { return nil }
    self.init(
      id: id, at: v["at"]?.stringValue ?? "", by: v["by"]?.stringValue ?? "learner", kind: kind, anchor: CommentAnchor(json: v["anchor"]),
      text: v["text"]?.stringValue, replyTo: v["reply_to"]?.stringValue, job: v["job"]?.stringValue, textEn: v["text_en"]?.stringValue,
      textKo: v["text_ko"]?.stringValue, src: (v["src"]?.arrayValue ?? []).compactMap(\.stringValue), supplementary: v["supplementary"]?.boolValue ?? false,
      target: v["target"]?.stringValue)
  }

  // cm-YYYYMMDD-HHMMSS-<4자>
  public static func makeID(_ date: Date = Date()) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
    let tail = String((0..<4).map { _ in alphabet.randomElement()! })
    return String(format: "cm-%04d%02d%02d-%02d%02d%02d-", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!) + tail
  }
}

public enum CommentStore {
  public static func file(_ data: DataFolder) -> URL { data.learner.appending(path: "comments.jsonl") }

  public static func append(_ data: DataFolder, _ comment: Comment) throws {
    try FileOps.appendLine(JSONText.line(comment.json), to: file(data))
  }

  // 지운 것을 빼고, 옮겨진 개념과 단위를 지금 자리로 바꾼 코멘트 (적은 차례).
  // 단위가 옮겨 갔으면 판을 0 으로 두어 "이전 판에 단 코멘트"로 보이게 한다 (DECISIONS.md 47).
  public static func load(_ data: DataFolder) -> [Comment] {
    let all = ((try? JSONLines.read(file(data)))?.values ?? []).compactMap(Comment.init(json:))
    let deleted = Set(all.filter { $0.kind == .delete }.compactMap(\.target))
    var resolver = AnchorResolver(data, moves: Moves.all(data))
    return all.filter { $0.kind != .delete && !deleted.contains($0.id) && !deleted.contains($0.replyTo ?? "") }.map { c in
      var c = c
      if let a = c.anchor {
        let r = resolver.resolve(concept: a.concept, unit: a.unit)
        c.anchor?.concept = r.concept
        c.anchor?.unit = r.unit
        if r.moved { c.anchor?.rev = 0 }
      }
      return c
    }
  }

  // 한 개념의 코멘트와 그 답글
  public static func thread(_ comments: [Comment], concept: String) -> [Comment] {
    let roots = comments.filter { $0.anchor?.concept == concept }
    let ids = Set(roots.map(\.id))
    return roots + comments.filter { $0.replyTo.map(ids.contains) == true }
  }
}
