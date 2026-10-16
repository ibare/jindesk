// claude -p --output-format stream-json 이벤트를 진행 화면용 한 줄 기록으로 바꾼다.
import Foundation

public enum StreamEvents {
  static func clip(_ s: String, _ max: Int) -> String {
    let one = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return one.count > max ? String(one.prefix(max)) + "…" : one
  }

  static func rel(_ p: JSONValue?, _ cwd: String) -> String {
    guard let p = p?.stringValue else { return "" }
    if p == cwd { return "." }
    return p.hasPrefix("/") && p.hasPrefix(cwd + "/") ? String(p.dropFirst(cwd.count + 1)) : p
  }

  static func describeToolUse(_ name: String, _ input: JSONValue, _ cwd: String) -> String {
    switch name {
    case "Read":
      return "Read \(rel(input["file_path"], cwd))"
    case "Write", "Edit":
      return "\(name) \(rel(input["file_path"], cwd))"
    case "Grep":
      let path = truthy(input["path"]) ? " in \(rel(input["path"], cwd))" : ""
      return "Grep \"\(clip(text(input["pattern"]), 60))\"\(path)"
    case "Glob":
      let path = truthy(input["path"]) ? " in \(rel(input["path"], cwd))" : ""
      return "Glob \(text(input["pattern"]))\(path)"
    case "WebSearch":
      return "WebSearch \"\(clip(text(input["query"]), 120))\"\(input["mode"]?.stringValue == "extended" ? " (extended)" : "")"
    case "WebFetch":
      return "WebFetch \(clip(text(input["url"]), 160))"
    default:
      let json = String(decoding: (try? JSONEncoder().encode(input)) ?? Data(), as: UTF8.self)
      return "\(name) \(clip(json, 120))"
    }
  }

  // 자바스크립트 String(v ?? '')
  static func text(_ v: JSONValue?) -> String {
    guard let v, v != .null else { return "" }
    return v.looseString
  }

  // ?? 처럼 null·undefined 만 거른다
  static func truthyOrZero(_ v: JSONValue?) -> Bool { v != nil && v != .null }

  // 자바스크립트에서 참으로 보는 값인가
  static func truthy(_ v: JSONValue?) -> Bool {
    switch v {
    case nil, .null?: false
    case .bool(let b)?: b
    case .number(let n)?: n != 0 && !n.isNaN
    case .string(let s)?: !s.isEmpty
    default: true
    }
  }

  static func toolResultText(_ content: JSONValue?) -> String {
    if let s = content?.stringValue { return s }
    if let a = content?.arrayValue { return a.map { $0["text"]?.stringValue ?? "" }.joined(separator: " ") }
    return ""
  }

  public static func describe(_ e: JSONValue, cwd: String) -> [(LogKind, String)] {
    guard case .object = e else { return [] }
    var out: [(LogKind, String)] = []
    let type = e["type"]?.stringValue
    let subtype = e["subtype"]?.stringValue

    if type == "system", subtype == "init" {
      let tools = e["tools"]?.arrayValue?.map(\.looseString).joined(separator: ", ") ?? "?"
      out.append((.info, "에이전트 시작: 모델 \(e["model"]?.looseString ?? "undefined"), 도구 \(tools)"))
    } else if type == "system", subtype == "permission_denied" {
      let reason = e["decision_reason"] ?? e["message"]
      out.append((.warn, "권한 거부: \(e["tool_name"]?.looseString ?? "undefined") — \(clip(reason?.looseString ?? "", 160))"))
    } else if type == "assistant", let content = e["message"]?["content"]?.arrayValue {
      for block in content {
        if block["type"]?.stringValue == "tool_use" {
          out.append((.tool, describeToolUse(block["name"]?.looseString ?? "", block["input"]?.objectValue.map(JSONValue.object) ?? .object([:]), cwd)))
        } else if block["type"]?.stringValue == "text", let text = block["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          out.append((.text, clip(text, 300)))
        }
      }
    } else if type == "user", let content = e["message"]?["content"]?.arrayValue {
      for block in content where block["type"]?.stringValue == "tool_result" && block["is_error"]?.boolValue == true {
        out.append((.warn, "도구 오류: \(clip(toolResultText(block["content"]), 200))"))
      }
    } else if type == "rate_limit_event", let info = e["rate_limit_info"], case .object = info {
      if info["status"]?.stringValue != "allowed" {
        out.append((.warn, "사용량 한도 상태: \(info["status"]?.looseString ?? "undefined") (\(info["rateLimitType"]?.looseString ?? ""))"))
      }
    } else if type == "result" {
      let cost = e["total_cost_usd"]?.numberValue.map { String(format: ", 추정 비용 $%.2f", $0) } ?? ""
      let isError = e["is_error"]?.boolValue == true
      out.append((isError ? .error : .info, "에이전트 종료: \(subtype ?? "undefined"), \(truthyOrZero(e["num_turns"]) ? text(e["num_turns"]) : "?")턴\(cost)"))
    }
    return out
  }
}
