import Foundation

// 모양을 미리 알 수 없는 JSON (훅 입력, stream-json 이벤트, JSONL 줄 등)
public enum JSONValue: Sendable, Equatable, Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let b = try? container.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? container.decode(Double.self) {
      self = .number(n)
    } else if let s = try? container.decode(String.self) {
      self = .string(s)
    } else if let a = try? container.decode([JSONValue].self) {
      self = .array(a)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let b): try container.encode(b)
    case .number(let n):
      if n.rounded() == n && abs(n) < 1e15 { try container.encode(Int64(n)) } else { try container.encode(n) }
    case .string(let s): try container.encode(s)
    case .array(let a): try container.encode(a)
    case .object(let o): try container.encode(o)
    }
  }

  public static func parse(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
  }

  public subscript(key: String) -> JSONValue? {
    if case .object(let o) = self { return o[key] }
    return nil
  }

  public var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  public var numberValue: Double? {
    if case .number(let n) = self { return n }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let b) = self { return b }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let a) = self { return a }
    return nil
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let o) = self { return o }
    return nil
  }

  // 값을 글자로 (null 은 "null")
  public var looseString: String {
    switch self {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    case .string(let s): return s
    case .array, .object:
      let data = (try? JSONEncoder().encode(self)) ?? Data()
      return String(decoding: data, as: UTF8.self)
    }
  }
}
