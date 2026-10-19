// 자료 묶음 (bundles/<묶음 id>.yaml, DECISIONS.md 35). 같은 내용을 다루는 자료들이고, 자료 읽기와 개념 정리의 단위다.
// 자료 하나는 묶음 하나에만 든다. 어느 묶음 파일에도 없는 자료는 자료 id 를 묶음 id 로 하는 혼자인 묶음으로 본다.
// 엔트리의 묶음은 엔트리의 첫 자료로 정한다. 그래서 자료를 옮기면 아직 정리하지 않은 그 자료의 엔트리도 따라간다.
import Foundation

// 묶음 id: YYYYMMDD-<임의 8자> (만든 날). 혼자인 묶음은 자료 id 를 그대로 쓴다.
public enum BundleID {
  public static func make(created: Date) -> String {
    String(JobID.stamp(created).prefix(8)) + "-" + String(UUID().uuidString.lowercased().filter { $0 != "-" }.prefix(8))
  }

  public static func isValid(_ id: String) -> Bool { SourceID.isValid(id) }
}

public struct SourceBundle: Sendable, Equatable, Identifiable {
  public let id: String
  public var created: String
  // 넣은 차례
  public var sources: [String]
  public var memo: String?
  // 묶음 읽기가 자료 내용으로 지은 영어 이름. 읽기 전에는 nil
  public var title: String?
  // 파일이 없는 혼자인 묶음 (어느 묶음에도 없는 자료)
  public var implicit = false

  public init(id: String, created: String, sources: [String], memo: String? = nil, title: String? = nil) {
    self.id = id
    self.created = created
    self.sources = sources
    self.memo = memo?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  public var yaml: YAMLMap {
    [
      "kind": "bundle",
      "v": 1,
      "id": .string(id),
      "created": .string(created),
      "sources": .array(sources.map(YAMLValue.string)),
      "memo": memo.map(YAMLValue.string) ?? .null,
      "title": title.map(YAMLValue.string) ?? .null,
    ]
  }

  public static func read(_ url: URL) throws -> SourceBundle {
    let v = try YAML.read(url)
    guard v["kind"]?.string == "bundle", let id = v["id"]?.string else { throw ToolError("\(url.path) 의 모양이 맞지 않습니다") }
    return SourceBundle(id: id, created: v["created"]?.string ?? "", sources: v["sources"]?.strings ?? [], memo: v["memo"]?.string, title: v["title"]?.string)
  }
}

public enum BundleStore {
  // 함께 도는 자료 넣기와 자료 읽기가 같은 묶음 파일을 고쳐 쓰지 않도록 잠근다
  static let lock = NSLock()

  public static func file(_ data: DataFolder, id: String) -> URL { data.bundles.appending(path: "\(id).yaml") }

  // 모든 묶음. 만든 때가 늦은 것부터. 어느 묶음에도 없는 자료는 혼자인 묶음으로 더한다.
  public static func all(_ data: DataFolder, library: SourceLibrary? = nil) -> [SourceBundle] {
    let library = library ?? SourceLibrary.load(data)
    var out: [SourceBundle] = FileOps.list(data.bundles).filter { $0.hasSuffix(".yaml") && !$0.hasPrefix(".") }.compactMap {
      try? SourceBundle.read(data.bundles.appending(path: $0))
    }
    let known = Set(library.sources.map(\.id))
    for i in out.indices { out[i].sources = out[i].sources.filter(known.contains) }
    out.removeAll { $0.sources.isEmpty }
    let placed = Set(out.flatMap(\.sources))
    for s in library.sources where !placed.contains(s.id) {
      var lone = SourceBundle(id: s.id, created: s.meta.received, sources: [s.id])
      lone.implicit = true
      out.append(lone)
    }
    return out.sorted { ($0.created, $0.id) > ($1.created, $1.id) }
  }

  public static func bundle(_ data: DataFolder, id: String, library: SourceLibrary? = nil) -> SourceBundle? {
    all(data, library: library).first { $0.id == id }
  }

  // 자료 id → 묶음 id
  public static func membership(_ bundles: [SourceBundle]) -> [String: String] {
    Dictionary(bundles.flatMap { b in b.sources.map { ($0, b.id) } }, uniquingKeysWith: { a, _ in a })
  }

  // 그 자료가 든 묶음
  public static func bundle(of source: String, in data: DataFolder, library: SourceLibrary? = nil) -> SourceBundle? {
    all(data, library: library).first { $0.sources.contains(source) }
  }

  // 묶음의 과목 id (첫 자료의 과목 꼬리표)
  public static func subject(_ bundle: SourceBundle, library: SourceLibrary) -> String? {
    bundle.sources.lazy.compactMap { library.source($0)?.labels.labels.subjectID }.first
  }

  public static func write(_ bundle: SourceBundle, data: DataFolder) throws {
    try FileOps.writeAtomic(YAML.stringify(bundle.yaml), to: file(data, id: bundle.id))
  }

  // 새 묶음을 만든다
  public static func create(_ data: DataFolder, sources: [String], memo: String?, now: Date = Date()) throws -> SourceBundle {
    try lock.withLock {
      var id = BundleID.make(created: now)
      while FileOps.exists(file(data, id: id)) { id = BundleID.make(created: now) }
      let bundle = SourceBundle(id: id, created: Clock.isoLocal(now), sources: sources, memo: memo)
      try write(bundle, data: data)
      return bundle
    }
  }

  // 자료 넣기: 자료를 그 묶음에 더한다. 그 id 의 묶음이 아직 없으면 만든다 (넣기를 준비할 때 정해 둔 새 묶음).
  // 메모는 묶음에 아직 없을 때만 이어 적는다. 다시 시작한 넣기가 같은 메모를 또 적지 않는다.
  public static func put(_ data: DataFolder, sources: [String], in id: String, memo: String?, now: Date = Date()) throws {
    try lock.withLock {
      var b = bundle(data, id: id) ?? SourceBundle(id: id, created: Clock.isoLocal(now), sources: [])
      b.sources += sources.filter { !b.sources.contains($0) }
      if let memo = memo?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, !"\n\(b.memo ?? "")\n".contains("\n\(memo)\n") {
        b.memo = [b.memo, memo].compactMap { $0 }.joined(separator: "\n")
      }
      b.implicit = false
      try write(b, data: data)
    }
  }

  // 그 묶음을 읽어 고쳐 쓴다. 혼자인 묶음이면 파일을 만든다.
  static func update(_ data: DataFolder, id: String, _ change: (inout SourceBundle) -> Void) throws -> SourceBundle {
    try lock.withLock {
      guard var bundle = bundle(data, id: id) else { throw ToolError("묶음을 찾지 못했습니다: \(id)") }
      change(&bundle)
      bundle.implicit = false
      if bundle.sources.isEmpty {
        FileOps.remove(file(data, id: id))
      } else {
        try write(bundle, data: data)
      }
      return bundle
    }
  }

  // 있는 묶음에 자료를 더한다. 메모가 있으면 이어 적는다.
  @discardableResult
  public static func add(_ data: DataFolder, sources: [String], to id: String, memo: String? = nil) throws -> SourceBundle {
    try update(data, id: id) { b in
      b.sources += sources.filter { !b.sources.contains($0) }
      if let memo = memo?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
        b.memo = [b.memo, memo].compactMap { $0 }.joined(separator: "\n")
      }
    }
  }

  // 묶음 읽기가 지은 이름. 이미 이름이 있으면 그대로 둔다.
  public static func name(_ data: DataFolder, id: String, title: String) throws {
    guard let title = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, bundle(data, id: id)?.title == nil else { return }
    _ = try update(data, id: id) { $0.title = title }
  }

  public static func setMemo(_ data: DataFolder, id: String, memo: String?) throws {
    _ = try update(data, id: id) { $0.memo = memo?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
  }

  // 자료를 다른 묶음으로 옮긴다. 묶음 id 가 nil 이면 새 묶음을 만든다. 옮긴 묶음 id 를 돌려준다.
  // 이미 끝난 읽기와 정리는 되돌리지 않는다. 아직 하지 않은 일만 옮긴 묶음에서 한다.
  @discardableResult
  public static func move(_ data: DataFolder, source: String, to target: String?, now: Date = Date()) throws -> String {
    guard let from = bundle(of: source, in: data) else { throw ToolError("자료가 든 묶음을 찾지 못했습니다: \(source)") }
    if from.id == target { return from.id }
    let targetID: String
    if let target {
      guard bundle(data, id: target) != nil else { throw ToolError("묶음을 찾지 못했습니다: \(target)") }
      targetID = target
      try add(data, sources: [source], to: target)
    } else {
      targetID = try create(data, sources: [source], memo: nil, now: now).id
    }
    // 혼자인 묶음은 자료가 옮겨 가면 저절로 없어진다
    if !from.implicit { _ = try update(data, id: from.id) { $0.sources.removeAll { $0 == source } } }
    return targetID
  }

  // 한 묶음의 자료를 모두 다른 묶음으로 옮긴다. 옮긴 묶음의 메모도 이어 적는다.
  public static func merge(_ data: DataFolder, from: String, into target: String) throws {
    guard from != target, let source = bundle(data, id: from) else { return }
    guard bundle(data, id: target) != nil else { throw ToolError("묶음을 찾지 못했습니다: \(target)") }
    try add(data, sources: source.sources, to: target, memo: source.memo)
    _ = try update(data, id: from) { $0.sources = [] }
  }
}
