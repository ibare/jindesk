// 데이터 폴더의 YAML. 키 순서를 지키는 값으로 읽고, DATA.md 의 쓰기 규칙대로 쓴다.
// - 읽기는 YAML 1.2 core 규칙이다 (yes, on 같은 말은 참·거짓이 아니라 문자열이다).
// - 문자열은 늘 큰따옴표나 블록 스칼라(|)로 쓴다. 맨 문자열을 쓰지 않으므로 no, 12:30, 010 이 다른 타입으로 읽히지 않는다.
// - 키 순서는 값을 만드는 쪽(스키마)이 정한다. 들여쓰기 2칸, 줄 끝 LF, 마지막 줄바꿈 하나, UTF-8 NFC.
// 그래서 같은 값은 늘 같은 바이트가 된다.
import Foundation
import Yams

public indirect enum YAMLValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([YAMLValue])
  case map(YAMLMap)

  public subscript(key: String) -> YAMLValue? {
    if case .map(let m) = self { return m[key] }
    return nil
  }

  public var string: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  public var int: Int? {
    switch self {
    case .int(let n): return n
    case .double(let d) where d.rounded() == d && abs(d) < 1e15: return Int(d)
    default: return nil
    }
  }

  public var double: Double? {
    switch self {
    case .int(let n): return Double(n)
    case .double(let d): return d
    default: return nil
    }
  }

  public var bool: Bool? {
    if case .bool(let b) = self { return b }
    return nil
  }

  public var array: [YAMLValue]? {
    if case .array(let a) = self { return a }
    return nil
  }

  public var map: YAMLMap? {
    if case .map(let m) = self { return m }
    return nil
  }

  public var isNull: Bool { self == .null }

  // 문자열 목록 (문자열이 아닌 항목은 뺀다)
  public var strings: [String] {
    (array ?? []).compactMap(\.string)
  }
}

extension YAMLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
  ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByFloatLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(nilLiteral: ()) { self = .null }
  public init(arrayLiteral elements: YAMLValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, YAMLValue)...) { self = .map(YAMLMap(elements)) }
}

// 키 순서를 지키는 맵. 쓰는 모양(style)은 값 비교에 넣지 않는다.
public struct YAMLMap: Equatable, Sendable, ExpressibleByDictionaryLiteral {
  public struct Entry: Equatable, Sendable {
    public let key: String
    public var value: YAMLValue
  }

  // auto: 맨 위가 아니고, 여러 줄 글이나 맵 목록이 없으면 한 줄({ … })로 쓴다
  public enum Style: Sendable { case auto, block, flow }

  public private(set) var entries: [Entry]
  public var style: Style = .auto

  public init(_ pairs: [(String, YAMLValue)] = [], style: Style = .auto) {
    entries = []
    self.style = style
    for (k, v) in pairs { self[k] = v }
  }

  public init(dictionaryLiteral elements: (String, YAMLValue)...) {
    self.init(elements)
  }

  public var keys: [String] { entries.map(\.key) }
  public var isEmpty: Bool { entries.isEmpty }

  // 있는 키는 제자리에서 바꾸고, 없으면 끝에 더한다. nil 을 넣으면 지운다.
  public subscript(key: String) -> YAMLValue? {
    get { entries.first { $0.key == key }?.value }
    set {
      if let i = entries.firstIndex(where: { $0.key == key }) {
        if let newValue { entries[i].value = newValue } else { entries.remove(at: i) }
      } else if let newValue {
        entries.append(Entry(key: key, value: newValue))
      }
    }
  }

  public func with(style: Style) -> YAMLMap {
    var copy = self
    copy.style = style
    return copy
  }

  public static func == (a: YAMLMap, b: YAMLMap) -> Bool { a.entries == b.entries }
}

public enum YAML {
  public struct ParseError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { "YAML 을 해석하지 못했습니다: \(message)" }
  }

  // YAML 1.2 core 스키마
  static let resolver: Resolver = {
    var r = Resolver.basic
    r = try! r.appending(.null, #"^(?:~|null|Null|NULL|)$"#)
    r = try! r.appending(.bool, #"^(?:true|True|TRUE|false|False|FALSE)$"#)
    r = try! r.appending(.int, #"^(?:[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+)$"#)
    r = try! r.appending(.float, #"^(?:[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$"#)
    return r
  }()

  public static func parse(_ text: String) throws -> YAMLValue {
    do {
      guard let node = try Yams.compose(yaml: text, resolver) else { return .null }
      return try value(node)
    } catch let e as ParseError {
      throw e
    } catch {
      throw ParseError(message: String(describing: error))
    }
  }

  public static func read(_ url: URL) throws -> YAMLValue {
    try parse(try FileOps.read(url))
  }

  static func value(_ node: Node) throws -> YAMLValue {
    switch node {
    case .scalar(let scalar):
      // 따옴표나 블록으로 쓴 값은 늘 문자열이다
      if scalar.style != .plain && scalar.style != .any { return .string(scalar.string) }
      switch Tag.Name(rawValue: node.tag.rawValue) {
      case .null: return .null
      case .bool: return .bool(scalar.string.lowercased() == "true")
      case .int:
        let s = scalar.string
        if s.hasPrefix("0o") { return Int(s.dropFirst(2), radix: 8).map(YAMLValue.int) ?? .string(s) }
        if s.hasPrefix("0x") { return Int(s.dropFirst(2), radix: 16).map(YAMLValue.int) ?? .string(s) }
        if let n = Int(s) { return .int(n) }
        return Double(s).map(YAMLValue.double) ?? .string(s)
      case .float:
        let s = scalar.string
        switch s.lowercased() {
        case ".inf", "+.inf": return .double(.infinity)
        case "-.inf": return .double(-.infinity)
        case ".nan": return .double(.nan)
        default: return Double(s).map(YAMLValue.double) ?? .string(s)
        }
      default:
        return .string(scalar.string)
      }
    case .mapping(let mapping):
      var map = YAMLMap([])
      for (k, v) in mapping {
        guard case .scalar(let key) = k else { throw ParseError(message: "맵의 키는 글자여야 한다") }
        map[key.string] = try value(v)
      }
      return .map(map)
    case .sequence(let sequence):
      return .array(try sequence.map(value))
    case .alias:
      throw ParseError(message: "별칭(alias)은 쓰지 않는다")
    }
  }

  // 맨 위는 늘 블록 맵이다
  public static func stringify(_ map: YAMLMap) -> String {
    var out = ""
    writeBlockMap(map, indent: 0, into: &out)
    return out
  }

  static func writeBlockMap(_ map: YAMLMap, indent: Int, into out: inout String) {
    let pad = String(repeating: " ", count: indent)
    for entry in map.entries {
      out += pad + keyText(entry.key) + ":"
      writeAfterKey(entry.value, indent: indent, into: &out)
    }
  }

  // 키(또는 "- ") 뒤의 값
  static func writeAfterKey(_ value: YAMLValue, indent: Int, into out: inout String) {
    switch value {
    case .string(let s) where isMultiline(s):
      out += " " + blockLiteral(s, indent: indent + 2) + "\n"
    case .map(let m) where m.isEmpty:
      out += " {}\n"
    case .map(let m) where flowable(m):
      out += " " + flowText(.map(m)) + "\n"
    case .map(let m):
      out += "\n"
      writeBlockMap(m, indent: indent + 2, into: &out)
    case .array(let a) where a.isEmpty:
      out += " []\n"
    case .array(let a) where a.allSatisfy(isInlineScalar):
      out += " " + flowText(value) + "\n"
    case .array(let a):
      out += "\n"
      writeBlockList(a, indent: indent + 2, into: &out)
    default:
      out += " " + scalarText(value) + "\n"
    }
  }

  static func writeBlockList(_ array: [YAMLValue], indent: Int, into out: inout String) {
    let pad = String(repeating: " ", count: indent)
    for item in array {
      switch item {
      case .map(let m) where !m.isEmpty && !flowable(m):
        // 첫 키는 "- " 와 같은 줄에, 나머지는 그 밑에 맞춘다
        var nested = ""
        writeBlockMap(m, indent: indent + 2, into: &nested)
        out += pad + "- " + nested.dropFirst(indent + 2)
      case .array(let a) where !a.isEmpty && !a.allSatisfy(isInlineScalar):
        var nested = ""
        writeBlockList(a, indent: indent + 2, into: &nested)
        out += pad + "- " + nested.dropFirst(indent + 2)
      case .string(let s) where isMultiline(s):
        out += pad + "- " + blockLiteral(s, indent: indent + 2) + "\n"
      case .map, .array:
        out += pad + "- " + flowText(item) + "\n"
      default:
        out += pad + "- " + scalarText(item) + "\n"
      }
    }
  }

  // 한 줄로 쓸 수 있는 맵인가
  static func flowable(_ map: YAMLMap) -> Bool {
    if map.style == .block { return false }
    return map.entries.allSatisfy { canBeFlow($0.value) }
  }

  // 한 줄({ … }, [ … ]) 안에 들어갈 수 있는 값인가
  static func canBeFlow(_ value: YAMLValue) -> Bool {
    switch value {
    case .string(let s): return !isMultiline(s)
    case .map(let m): return m.style != .block && m.entries.allSatisfy { canBeFlow($0.value) }
    case .array(let a): return a.allSatisfy(canBeFlow)
    default: return true
    }
  }

  static func isInlineScalar(_ value: YAMLValue) -> Bool {
    switch value {
    case .map, .array: return false
    case .string(let s): return !isMultiline(s)
    default: return true
    }
  }

  static func flowText(_ value: YAMLValue) -> String {
    switch value {
    case .map(let m):
      if m.isEmpty { return "{}" }
      return "{ " + m.entries.map { keyText($0.key) + ": " + flowText($0.value) }.joined(separator: ", ") + " }"
    case .array(let a):
      return "[" + a.map(flowText).joined(separator: ", ") + "]"
    default:
      return scalarText(value)
    }
  }

  static func scalarText(_ value: YAMLValue) -> String {
    switch value {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .int(let n): return String(n)
    case .double(let d): return formatNumber(d)
    case .string(let s): return doubleQuoted(s.precomposedStringWithCanonicalMapping)
    case .array: return "[]"
    case .map: return "{}"
    }
  }

  // 여러 줄 글은 블록 스칼라로 쓴다. 다른 제어 문자가 섞였으면 큰따옴표로 쓴다.
  // 줄바꿈만으로 된 글은 블록으로 쓰면 값이 달라지므로 큰따옴표로 쓴다.
  static func isMultiline(_ s: String) -> Bool {
    s.contains("\n") && s.contains { $0 != "\n" }
      && !s.unicodeScalars.contains { ($0.value < 0x20 && $0 != "\t" && $0 != "\n") || (0x7F...0x9F).contains($0.value) }
  }

  public static func formatNumber(_ d: Double) -> String {
    if d.isNaN { return ".nan" }
    if d.isInfinite { return d > 0 ? ".inf" : "-.inf" }
    if d.rounded() == d && abs(d) < 1e15 { return String(format: "%.1f", d) }
    var s = "\(d)"
    if let e = s.range(of: "e") {
      var exponent = String(s[e.upperBound...])
      let sign = exponent.hasPrefix("-") ? "-" : "+"
      exponent = String(exponent.drop { $0 == "-" || $0 == "+" || $0 == "0" })
      s = String(s[..<e.lowerBound]) + "e" + sign + (exponent.isEmpty ? "0" : exponent)
    }
    return s
  }

  static let plainKey = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_.\-]*$"#)
  static let reservedKey: Set<String> = ["true", "false", "null", "True", "False", "Null", "TRUE", "FALSE", "NULL", "y", "n", "yes", "no", "on", "off"]

  // 키는 스키마가 정한 이름이라 대개 맨 글자로 쓴다. 그 밖에는 큰따옴표로 쓴다.
  static func keyText(_ key: String) -> String {
    let k = key.precomposedStringWithCanonicalMapping
    let plain = plainKey.firstMatch(in: k, range: NSRange(k.startIndex..., in: k)) != nil
    return plain && !reservedKey.contains(k) ? k : doubleQuoted(k)
  }

  static func doubleQuoted(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
      switch u {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\t": out += "\\t"
      case "\r": out += "\\r"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      case "\u{00}": out += "\\0"
      case "\u{07}": out += "\\a"
      case "\u{0B}": out += "\\v"
      case "\u{1B}": out += "\\e"
      case "\u{85}": out += "\\N"
      case "\u{A0}": out += "\\_"
      case "\u{2028}": out += "\\L"
      case "\u{2029}": out += "\\P"
      default:
        if u.value < 0x20 || (0x7F...0x9F).contains(u.value) {
          out += String(format: "\\x%02x", u.value)
        } else {
          out.unicodeScalars.append(u)
        }
      }
    }
    return out + "\""
  }

  // 블록 리터럴. 끝 줄바꿈 수에 따라 |-, |, |+ 를 고르고, 처음 글자가 있는 줄까지 공백으로 시작하는 줄이 있으면
  // 들여쓰기 폭을 밝힌다 (밝히지 않으면 그 공백까지 들여쓰기로 읽힌다).
  static func blockLiteral(_ raw: String, indent: Int) -> String {
    let s = raw.precomposedStringWithCanonicalMapping
    let trailing = s.reversed().prefix { $0 == "\n" }.count
    let chomp = trailing == 0 ? "-" : trailing == 1 ? "" : "+"
    let body = trailing == 1 ? String(s.dropLast()) : s
    let pad = String(repeating: " ", count: indent)
    let leading = body.split(separator: "\n", omittingEmptySubsequences: false).prefix { $0.allSatisfy { $0 == " " } }
    let firstText = body.split(separator: "\n", omittingEmptySubsequences: false).first { !$0.allSatisfy { $0 == " " } }
    let indicator = leading.contains { !$0.isEmpty } || firstText?.first == " " ? "2" : ""
    var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : pad + $0 }
    // |+ 는 끝의 빈 줄들이 값이다. 마지막 줄바꿈은 값을 쓴 뒤 붙는다.
    if trailing > 1 { lines.removeLast() }
    return "|" + indicator + chomp + "\n" + lines.joined(separator: "\n")
  }
}
