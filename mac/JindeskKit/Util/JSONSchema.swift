// 데이터 파일의 JSON Schema 검증 (schemas/<스키마 버전>/<kind>.schema.json). 러너가 쓰는 파일과 마이그레이션 사본을 본다.
// 쓰는 기능만 다룬다: type, const, enum, properties, required, additionalProperties, items, minItems, minimum, minLength, pattern, anyOf, $ref(#/$defs/…).
import Foundation

public struct SchemaSet: Sendable {
  public let directory: URL
  private let schemas: [String: JSONValue]

  // 그 스키마 버전의 폴더 (예: schemas/1)
  public init(_ directory: URL) {
    self.directory = directory
    var out: [String: JSONValue] = [:]
    for name in FileOps.list(directory) where name.hasSuffix(".schema.json") {
      if let data = try? Data(contentsOf: directory.appending(path: name)), let v = try? JSONValue.parse(data) {
        out[String(name.dropLast(".schema.json".count))] = v
      }
    }
    schemas = out
  }

  public var kinds: [String] { schemas.keys.sorted() }

  // kind 에 맞는 스키마로 본다. 스키마가 없는 kind 는 문제로 본다.
  public func validate(_ value: YAMLValue, label: String) -> [String] {
    guard let kind = value["kind"]?.string else { return ["\(label): kind 가 없습니다"] }
    guard let schema = schemas[kind] else { return ["\(label): \(kind) 의 스키마가 없습니다"] }
    return JSONSchema.validate(value.json, schema, root: schema, path: label)
  }
}

public enum JSONSchema {
  public static func validate(_ v: JSONValue, _ s: JSONValue, root: JSONValue, path: String) -> [String] {
    if let ref = s["$ref"]?.stringValue {
      guard ref.hasPrefix("#/$defs/"), let target = root["$defs"]?[String(ref.dropFirst(8))] else { return ["\(path): 스키마의 $ref 를 찾지 못했습니다 (\(ref))"] }
      return validate(v, target, root: root, path: path)
    }
    var out: [String] = []
    if let any = s["anyOf"]?.arrayValue {
      if !any.contains(where: { validate(v, $0, root: root, path: path).isEmpty }) { out.append("\(path): 어느 모양에도 맞지 않습니다") }
      return out
    }
    if let c = s["const"], c != v { out.append("\(path): \(c.looseString) 이어야 합니다") }
    if let e = s["enum"]?.arrayValue, !e.contains(v) { out.append("\(path): \(e.map(\.looseString).joined(separator: ", ")) 가운데 하나여야 합니다 (\(v.looseString))") }
    if let t = s["type"] {
      let types = t.arrayValue?.compactMap(\.stringValue) ?? [t.stringValue].compactMap { $0 }
      if !types.contains(where: { matches(v, $0) }) {
        out.append("\(path): \(types.joined(separator: " 나 ")) 이어야 합니다")
        return out
      }
    }
    switch v {
    case .object(let o):
      for key in s["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where o[key] == nil { out.append("\(path).\(key): 없습니다") }
      let props = s["properties"]?.objectValue ?? [:]
      for (key, value) in o.sorted(by: { $0.key < $1.key }) {
        if let p = props[key] {
          out += validate(value, p, root: root, path: "\(path).\(key)")
        } else if let extra = s["additionalProperties"] {
          if extra == .bool(false) { out.append("\(path).\(key): 스키마에 없는 필드입니다") } else if extra.objectValue != nil {
            out += validate(value, extra, root: root, path: "\(path).\(key)")
          }
        }
      }
    case .array(let a):
      if let min = s["minItems"]?.numberValue, Double(a.count) < min { out.append("\(path): \(Int(min))개 이상이어야 합니다") }
      if let items = s["items"] { for (i, x) in a.enumerated() { out += validate(x, items, root: root, path: "\(path)[\(i)]") } }
    case .string(let str):
      if let min = s["minLength"]?.numberValue, Double(str.count) < min { out.append("\(path): 비었습니다") }
      if let p = s["pattern"]?.stringValue, str.range(of: p, options: .regularExpression) == nil { out.append("\(path): 모양이 맞지 않습니다 (\(str))") }
    case .number(let n):
      if let min = s["minimum"]?.numberValue, n < min { out.append("\(path): \(YAML.formatNumber(min)) 보다 작습니다") }
    default:
      break
    }
    return out
  }

  static func matches(_ v: JSONValue, _ type: String) -> Bool {
    switch (type, v) {
    case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null), ("number", .number): true
    case ("integer", .number(let n)): n.rounded() == n
    default: false
    }
  }
}

// 데이터 폴더 전체를 스키마로 본다: 모든 YAML 과 엔트리(.md)의 머리말
public enum DataValidation {
  public static func validate(_ data: DataFolder, schemas: SchemaSet) -> [String] {
    var out: [String] = []
    for rel in FileOps.files(under: data.url) where !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
      let url = data.url.appending(path: rel)
      if rel.hasSuffix(".yaml") {
        guard let v = try? YAML.read(url) else { continue }
        out += schemas.validate(v, label: rel)
      } else if rel.hasPrefix("library/entries/") && rel.hasSuffix(".md") {
        guard let text = FileOps.readIfExists(url), let (head, _) = FrontMatter.split(text) else {
          out.append("\(rel): 머리말을 읽지 못했습니다")
          continue
        }
        out += schemas.validate(head, label: rel)
      }
    }
    return out
  }
}
