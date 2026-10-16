// 순서 있는 값(YAMLValue)을 JSON 으로 쓴다. 작은 기계 기록(JSON)은 키를 정렬하고 2칸 들여쓰며(DATA.md),
// JSONL 줄과 claude --settings 값은 한 줄로 쓴다.
import Foundation

public enum JSONText {
  // indent 가 0 이면 한 줄로 쓴다
  public static func stringify(_ value: YAMLValue, indent: Int = 0) -> String {
    var out = ""
    write(value, indent: indent, level: 0, into: &out)
    return out
  }

  // 키를 정렬하고 2칸 들여쓴 기록 파일 (끝에 줄바꿈 하나)
  public static func record(_ value: JSONValue) -> String {
    stringify(YAMLValue(json: value), indent: 2) + "\n"
  }

  // JSONL 한 줄 (키 정렬, 줄바꿈 없음)
  public static func line(_ value: JSONValue) -> String {
    stringify(YAMLValue(json: value))
  }

  static func write(_ value: YAMLValue, indent: Int, level: Int, into out: inout String) {
    switch value {
    case .null: out += "null"
    case .bool(let b): out += b ? "true" : "false"
    case .int(let n): out += String(n)
    case .double(let d): out += d.isFinite ? YAML.formatNumber(d) : "null"
    case .string(let s): out += quote(s)
    case .array(let a):
      if a.isEmpty {
        out += "[]"
        return
      }
      out += "["
      for (i, item) in a.enumerated() {
        if i > 0 { out += "," }
        newline(indent, level + 1, &out)
        write(item, indent: indent, level: level + 1, into: &out)
      }
      newline(indent, level, &out)
      out += "]"
    case .map(let m):
      if m.isEmpty {
        out += "{}"
        return
      }
      out += "{"
      for (i, entry) in m.entries.enumerated() {
        if i > 0 { out += "," }
        newline(indent, level + 1, &out)
        out += quote(entry.key) + (indent > 0 ? ": " : ":")
        write(entry.value, indent: indent, level: level + 1, into: &out)
      }
      newline(indent, level, &out)
      out += "}"
    }
  }

  static func newline(_ indent: Int, _ level: Int, _ out: inout String) {
    guard indent > 0 else { return }
    out += "\n" + String(repeating: " ", count: indent * level)
  }

  public static func quote(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
      switch u {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      default:
        if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
      }
    }
    return out + "\""
  }
}

extension YAMLValue {
  // JSON 값을 순서 있는 값으로 바꾼다. 객체 키는 사전 순서가 없으므로 정렬한다.
  public init(json: JSONValue) {
    switch json {
    case .null: self = .null
    case .bool(let b): self = .bool(b)
    case .number(let n): self = n.rounded() == n && abs(n) < 1e15 ? .int(Int(n)) : .double(n)
    case .string(let s): self = .string(s)
    case .array(let a): self = .array(a.map(YAMLValue.init(json:)))
    case .object(let o): self = .map(YAMLMap(o.keys.sorted().map { ($0, YAMLValue(json: o[$0]!)) }))
    }
  }
}
