import Foundation

// 앱이 쓰는 데이터 폴더의 스키마 버전. 데이터 스펙(파일과 필드의 추가, 삭제, 모양)을 바꾸면 무조건 올리고, Migration/ 에 단계를 더한다.
// 스펙은 그대로 두고 로직만 바꾸면 올리지 않는다 (MIGRATION.md, DECISIONS.md 42).
public enum CurrentSchema {
  public static let version = 2
}

// meta/schema.yaml: 스키마 버전, 마이그레이션 이력, 연 앱 판(last_opened_by).
// 연 앱 판은 폴더를 만들 때 적는다. 0.1.1 은 열 때마다 고쳐 적었는데, 판이 다른 맥이 열기만 해도 커밋이 생겨 이제 고치지 않는다.
public struct SchemaFile: Sendable, Equatable {
  public struct Entry: Sendable, Equatable {
    public let from: Int
    public let to: Int
    public let app: String
    public let at: String
    // code 또는 code+agent
    public let kind: String
    public let backup: String

    public init(from: Int, to: Int, app: String, at: String, kind: String, backup: String) {
      self.from = from
      self.to = to
      self.app = app
      self.at = at
      self.kind = kind
      self.backup = backup
    }
  }

  public var schema: Int
  public var created: String
  public var lastOpenedBy: AppVersion
  public var history: [Entry]

  public init(schema: Int, created: String, lastOpenedBy: AppVersion, history: [Entry]) {
    self.schema = schema
    self.created = created
    self.lastOpenedBy = lastOpenedBy
    self.history = history
  }

  public static func read(_ folder: DataFolder) throws -> SchemaFile {
    let value = try YAML.read(folder.schemaFile)
    guard value["kind"]?.string == "schema", let schema = value["schema"]?.int else {
      throw ToolError("\(folder.schemaFile.path) 의 모양이 맞지 않습니다 (kind: schema, schema: <버전>)")
    }
    let opened = value["last_opened_by"]
    let history = (value["history"]?.array ?? []).compactMap { e -> Entry? in
      guard let from = e["from"]?.int, let to = e["to"]?.int else { return nil }
      return Entry(
        from: from, to: to, app: e["app"]?.string ?? "", at: e["at"]?.string ?? "", kind: e["kind"]?.string ?? "code", backup: e["backup"]?.string ?? "")
    }
    return SchemaFile(
      schema: schema, created: value["created"]?.string ?? "",
      lastOpenedBy: AppVersion(app: opened?["app"]?.string ?? "0", build: opened?["build"]?.string ?? "0"), history: history)
  }

  public var yaml: YAMLMap {
    [
      "kind": "schema",
      "v": 1,
      "schema": .int(schema),
      "created": .string(created),
      "last_opened_by": ["app": .string(lastOpenedBy.app), "build": .string(lastOpenedBy.build)],
      "history": .array(
        history.map { e in
          [
            "from": .int(e.from), "to": .int(e.to), "app": .string(e.app), "at": .string(e.at), "kind": .string(e.kind), "backup": .string(e.backup),
          ]
        }),
    ]
  }

  public func write(to folder: DataFolder) throws {
    try FileOps.writeAtomic(YAML.stringify(yaml), to: folder.schemaFile)
  }
}
