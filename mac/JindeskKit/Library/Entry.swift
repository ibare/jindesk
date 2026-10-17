// 원시 개념 엔트리 (library/entries/<과목 id>/<항목>/<slug>.md). 자료 읽기가 쓰고, 고치지 않는다.
// 머리말 YAML 과 영어 본문이다. 주장마다 출처(<자료 id>#p<쪽>)를 단다.
import Foundation

// 머리말: 첫 줄 --- 부터 다음 --- 까지
public enum FrontMatter {
  public static func split(_ text: String) -> (data: YAMLValue, body: String)? {
    guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
      return nil
    }
    let head = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
    guard let data = try? YAML.parse(head + "\n") else { return nil }
    return (data, String(text[end.upperBound...]))
  }

  public static func render(_ map: YAMLMap) -> String {
    "---\n" + YAML.stringify(map) + "---\n"
  }
}

// 출처 표기: <자료 id>#p<쪽>
public enum SourceRef {
  public static func make(_ source: String, page: Int) -> String { "\(source)#p\(page)" }

  public static func parse(_ ref: String) -> (source: String, page: Int)? {
    guard let hash = ref.lastIndex(of: "#") else { return nil }
    let source = String(ref[..<hash])
    let rest = ref[ref.index(after: hash)...]
    guard rest.hasPrefix("p"), let page = Int(rest.dropFirst()), page > 0, SourceID.isValid(source) else { return nil }
    return (source, page)
  }
}

public struct SymbolDef: Sendable, Equatable {
  public let symbol: String
  public let meaning: String
  public let unit: String?

  public init(symbol: String, meaning: String, unit: String? = nil) {
    self.symbol = symbol
    self.meaning = meaning
    self.unit = unit?.nilIfBlank
  }

  public var yaml: YAMLValue {
    var m: YAMLMap = ["symbol": .string(symbol), "meaning": .string(meaning)]
    if let unit { m["unit"] = .string(unit) }
    return .map(m)
  }

  public init?(yaml: YAMLValue) {
    guard let s = yaml["symbol"]?.string, let m = yaml["meaning"]?.string else { return nil }
    self.init(symbol: s, meaning: m, unit: yaml["unit"]?.string)
  }
}

public struct EntryClaim: Sendable, Equatable {
  public let text: String
  public let src: [String]
  public let conditions: [String]

  public init(text: String, src: [String], conditions: [String] = []) {
    self.text = text
    self.src = src
    self.conditions = conditions
  }

  var yaml: YAMLValue {
    var m: YAMLMap = ["text": .string(text), "src": .array(src.map(YAMLValue.string))]
    if !conditions.isEmpty { m["conditions"] = .array(conditions.map(YAMLValue.string)) }
    return .map(m)
  }

  init?(yaml: YAMLValue) {
    guard let text = yaml["text"]?.string else { return nil }
    self.init(text: text, src: yaml["src"]?.strings ?? [], conditions: yaml["conditions"]?.strings ?? [])
  }
}

public struct Entry: Sendable, Equatable, Identifiable {
  // entries/ 아래 경로에서 .md 를 뗀 것: <과목 id>/<항목>/<slug>
  public let id: String
  public let subject: String
  // 목차에 있는 항목 코드. 목차 밖이면 nil 이고 경로의 항목은 unplaced 다
  public let item: String?
  // 자료 읽기가 내용을 보고 제안한 항목이나 단원 이름
  public let itemProposed: String?
  public let title: String
  public let source: String
  public let pages: [Int]
  public let claims: [EntryClaim]
  public let symbols: [SymbolDef]
  public let examples: [String]
  public let misconceptions: [String]
  public let body: String
  public let recorded: String
  public let provenance: YAMLMap

  public init(
    id: String, subject: String, item: String?, itemProposed: String?, title: String, source: String, pages: [Int], claims: [EntryClaim],
    symbols: [SymbolDef], examples: [String], misconceptions: [String], body: String, recorded: String, provenance: YAMLMap
  ) {
    self.id = id
    self.subject = subject
    self.item = item
    self.itemProposed = itemProposed
    self.title = title
    self.source = source
    self.pages = pages
    self.claims = claims
    self.symbols = symbols
    self.examples = examples
    self.misconceptions = misconceptions
    self.body = body
    self.recorded = recorded
    self.provenance = provenance
  }

  // 주장들이 가리키는 쪽
  public var refs: Set<String> { Set(claims.flatMap(\.src)) }

  public var frontMatter: YAMLMap {
    [
      "kind": "entry",
      "v": 1,
      "id": .string(id),
      "subject": .string(subject),
      "item": item.map(YAMLValue.string) ?? .null,
      "item_proposed": itemProposed.map(YAMLValue.string) ?? .null,
      "title": .string(title),
      "source": .string(source),
      "pages": .array(pages.map(YAMLValue.int)),
      "claims": .array(claims.map(\.yaml)),
      "symbols": .array(symbols.map(\.yaml)),
      "examples": .array(examples.map(YAMLValue.string)),
      "misconceptions": .array(misconceptions.map(YAMLValue.string)),
      "recorded": .string(recorded),
      "provenance": .map(provenance),
    ]
  }

  public var markdown: String {
    FrontMatter.render(frontMatter) + "\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
  }

  public static func parse(_ text: String) throws -> Entry {
    guard let (d, body) = FrontMatter.split(text), d["kind"]?.string == "entry", let id = d["id"]?.string, let subject = d["subject"]?.string,
      let title = d["title"]?.string, let source = d["source"]?.string
    else { throw ToolError("엔트리 머리말의 모양이 맞지 않습니다") }
    return Entry(
      id: id, subject: subject, item: d["item"]?.string, itemProposed: d["item_proposed"]?.string, title: title, source: source,
      pages: (d["pages"]?.array ?? []).compactMap(\.int), claims: (d["claims"]?.array ?? []).compactMap(EntryClaim.init(yaml:)),
      symbols: (d["symbols"]?.array ?? []).compactMap(SymbolDef.init(yaml:)), examples: d["examples"]?.strings ?? [],
      misconceptions: d["misconceptions"]?.strings ?? [], body: body.trimmingCharacters(in: .whitespacesAndNewlines),
      recorded: d["recorded"]?.string ?? "", provenance: d["provenance"]?.map ?? YAMLMap([]))
  }
}

public enum EntryStore {
  // 함께 도는 자료 읽기가 같은 경로를 고르지 않도록, 경로를 고르고 쓸 때까지 잠근다
  static let lock = NSLock()

  public static func all(_ data: DataFolder, subject: String) -> [Entry] {
    let dir = data.entriesDir(subject)
    return FileOps.files(under: dir).filter { $0.hasSuffix(".md") && !$0.split(separator: "/").contains { $0.hasPrefix(".") } }.compactMap { rel in
      guard let text = FileOps.readIfExists(dir.appending(path: rel)) else { return nil }
      return try? Entry.parse(text)
    }
  }

  // 과목마다 엔트리 (entries/ 아래 폴더 이름이 과목 id 다)
  public static func subjects(_ data: DataFolder) -> [String] {
    FileOps.list(data.entriesRoot).filter { !$0.hasPrefix(".") && FileOps.isDirectory(data.entriesRoot.appending(path: $0)) }.sorted()
  }

  // 새 엔트리의 id. 같은 경로가 있으면 <slug>--<작업 id> 로 나란히 둔다.
  static func placeID(_ data: DataFolder, subject: String, itemDir: String, slug: String, jobID: String, planned: Set<String>) -> String {
    let base = "\(subject)/\(itemDir)/\(slug)"
    func taken(_ id: String) -> Bool { planned.contains(id) || FileOps.exists(data.entryFile(id)) }
    if !taken(base) { return base }
    let withJob = "\(base)--\(jobID)"
    if !taken(withJob) { return withJob }
    var n = 2
    while taken("\(withJob)-\(n)") { n += 1 }
    return "\(withJob)-\(n)"
  }
}
