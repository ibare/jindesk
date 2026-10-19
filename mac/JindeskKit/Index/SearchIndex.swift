// SQLite 색인 (DATA.md 의 색인). 캐시의 index.sqlite 에 둔다. 원본이 아니라서 깨지거나 스키마가 바뀌면 지우고 다시 만든다.
// 담는 것: 개념 목록(과목, 항목, 제목, 한국어 제목)과 단위 글(영어, 한국어), 자료 쪽의 글자층(찾기의 원래 자료, DECISIONS.md 34).
// 글은 trigram FTS5 로 찾는다. 개념 폴더의 파일과 자료의 글자층(크기, 수정 시각)이 바뀌었을 때만 그 부분을 다시 만든다.
import Foundation
import SQLite3

public struct SearchHit: Sendable, Equatable, Identifiable {
  public let concept: String
  public let unit: String?
  public let title: String
  public let titleKo: String?
  // 맞은 곳 앞뒤 글. 찾은 말은 SearchHit.open 과 SearchHit.close 사이에 있다
  public let snippet: String
  public var id: String { "\(concept)#\(unit ?? "")" }

  public init(concept: String, unit: String?, title: String, titleKo: String?, snippet: String) {
    self.concept = concept
    self.unit = unit
    self.title = title
    self.titleKo = titleKo
    self.snippet = snippet
  }

  public static let open: Character = "\u{1}"
  public static let close: Character = "\u{2}"

  // 표시된 글에서 첫 표시 앞 before 글자부터 모두 length 글자를 자른다
  public static func excerpt(_ marked: String, before: Int = 50, length: Int = 180) -> String {
    let chars = Array(marked)
    guard let first = chars.firstIndex(of: open) else { return String(chars.prefix(length)) + (chars.count > length ? "…" : "") }
    var start = max(0, first - before)
    // 낱말 가운데서 자르지 않는다
    while start > 0, start < first, !chars[start - 1].isWhitespace { start += 1 }
    let end = min(chars.count, start + length)
    var out = String(chars[start..<end])
    // 잘려 닫히지 않은 표시를 닫는다
    if out.filter({ $0 == open }).count > out.filter({ $0 == close }).count { out.append(close) }
    return (start > 0 ? "…" : "") + out + (end < chars.count ? "…" : "")
  }
}

// 원래 자료의 쪽에서 찾은 곳
public struct PageHit: Sendable, Equatable, Identifiable {
  public let source: String
  public let page: Int
  // 찾은 말이 SearchHit.open, SearchHit.close 사이에 있는 앞뒤 글
  public let snippet: String
  public var id: String { "\(source)#\(page)" }
}

public final class SearchIndex: @unchecked Sendable {
  static let schema = 3
  private let lock = NSLock()
  private var db: OpaquePointer?
  public let url: URL

  public init(_ folders: AppFolders) {
    url = folders.cache.appending(path: "index.sqlite")
  }

  deinit {
    if let db { sqlite3_close(db) }
  }

  private func open() -> OpaquePointer? {
    if let db { return db }
    try? FileOps.makeDirectory(url.deletingLastPathComponent())
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
      sqlite3_close(handle)
      return nil
    }
    db = handle
    if scalar("PRAGMA user_version") != String(Self.schema) {
      exec("DROP TABLE IF EXISTS concepts; DROP TABLE IF EXISTS units; DROP TABLE IF EXISTS pages; DROP TABLE IF EXISTS meta;")
      exec(
        """
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE concepts(id TEXT PRIMARY KEY, subject TEXT, item TEXT, title TEXT, title_ko TEXT);
        CREATE VIRTUAL TABLE units USING fts5(concept UNINDEXED, unit UNINDEXED, en, ko, tokenize='trigram');
        CREATE VIRTUAL TABLE pages USING fts5(source UNINDEXED, page UNINDEXED, text, tokenize='trigram');
        PRAGMA user_version = \(Self.schema);
        """)
    }
    return db
  }

  @discardableResult
  private func exec(_ sql: String) -> Bool {
    sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
  }

  private func scalar(_ sql: String) -> String? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
    return String(cString: text)
  }

  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private func run(_ sql: String, _ args: [String?]) {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    for (i, a) in args.enumerated() {
      if let a { sqlite3_bind_text(stmt, Int32(i + 1), a, -1, Self.transient) } else { sqlite3_bind_null(stmt, Int32(i + 1)) }
    }
    sqlite3_step(stmt)
  }

  // 개념 폴더의 파일 크기와 수정 시각으로 만든 표시. 바뀌었으면 다시 만든다.
  static func signature(_ data: DataFolder) -> String {
    var parts: [String] = []
    for root in [data.conceptsRoot, data.unplacedRoot] {
      for rel in FileOps.files(under: root) where rel.hasSuffix(".yaml") {
        let attrs = try? FileManager.default.attributesOfItem(atPath: root.appending(path: rel).path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        parts.append("\(root.lastPathComponent)/\(rel):\(size):\(Int(mtime * 1000))")
      }
    }
    return Hash.short(Data(parts.sorted().joined(separator: "\n").utf8))
  }

  // 자료 쪽 글자층의 표시 (sources/<자료 id>/pages/<쪽>.txt)
  static func pageSignature(_ data: DataFolder) -> String {
    let root = data.url.appending(path: "sources")
    var parts: [String] = []
    for rel in FileOps.files(under: root) where rel.contains("/pages/") && rel.hasSuffix(".txt") {
      let attrs = try? FileManager.default.attributesOfItem(atPath: root.appending(path: rel).path)
      parts.append("\(rel):\((attrs?[.size] as? Int) ?? 0):\(Int(((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000))")
    }
    return Hash.short(Data(parts.sorted().joined(separator: "\n").utf8))
  }

  // 바뀐 것이 있으면 다시 만든다. 다시 만들었으면 true.
  @discardableResult
  public func update(_ data: DataFolder) -> Bool {
    let pages = updatePages(data)
    return updateConcepts(data) || pages
  }

  private func updatePages(_ data: DataFolder) -> Bool {
    let sig = Self.pageSignature(data)
    return lock.withLock {
      guard open() != nil else { return false }
      if scalar("SELECT value FROM meta WHERE key = 'pages'") == sig { return false }
      exec("BEGIN; DELETE FROM pages;")
      for s in SourceLibrary.load(data).sources {
        for n in 1...max(s.meta.pages, 1) {
          let text = SourcePages.text(s.folder, page: n)
          if !text.isEmpty { run("INSERT INTO pages VALUES (?, ?, ?)", [s.id, String(n), text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)]) }
        }
      }
      run("INSERT OR REPLACE INTO meta VALUES ('pages', ?)", [sig])
      exec("COMMIT;")
      return true
    }
  }

  private func updateConcepts(_ data: DataFolder) -> Bool {
    let sig = Self.signature(data)
    return lock.withLock {
      guard open() != nil else { return false }
      if scalar("SELECT value FROM meta WHERE key = 'signature'") == sig { return false }
      exec("BEGIN; DELETE FROM concepts; DELETE FROM units;")
      for c in ConceptStore.everything(data) {
        let folder = ConceptFolder(c.cid, in: data)
        let page = Page.load(folder)
        let layers = Layers.load(folder)
        run("INSERT INTO concepts VALUES (?, ?, ?, ?, ?)", [c.id, c.subject, c.item ?? c.itemProposed, c.title, page?.titleKo])
        run("INSERT INTO units VALUES (?, ?, ?, ?)", [c.id, nil, c.title, page?.titleKo])
        // 단위 글은 수식 구분자와 마크다운 표시를 걷어 담는다 (찾기 결과에 그대로 보인다)
        if let page {
          for u in page.units where u.english != nil {
            run("INSERT INTO units VALUES (?, ?, ?, ?)", [c.id, u.id, u.english.map(TexText.plain), (layers?.ko[u.id]?.text).map(TexText.plain)])
          }
        } else {
          for u in c.units { run("INSERT INTO units VALUES (?, ?, ?, ?)", [c.id, u.id, TexText.plain(u.text), nil]) }
        }
      }
      run("INSERT OR REPLACE INTO meta VALUES ('signature', ?)", [sig])
      exec("COMMIT;")
      return true
    }
  }

  static func mark(_ s: String, _ q: String) -> String {
    guard let r = s.range(of: q, options: .caseInsensitive) else { return s }
    return s[..<r.lowerBound] + String(SearchHit.open) + s[r] + String(SearchHit.close) + s[r.upperBound...]
  }

  // 원래 자료의 쪽에서 찾는다 (자료, 쪽 차례). 세 글자보다 짧으면 찾지 않는다 (글자층에 너무 많이 맞는다).
  public func sourcePages(_ query: String, limit: Int = 400) -> [PageHit] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard q.count >= 3 else { return [] }
    return lock.withLock {
      guard open() != nil else { return [] }
      let sql = "SELECT source, page, highlight(pages, 2, char(1), char(2)) FROM pages WHERE pages MATCH ? ORDER BY source, CAST(page AS INTEGER) LIMIT \(limit)"
      var stmt: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
      defer { sqlite3_finalize(stmt) }
      sqlite3_bind_text(stmt, 1, "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\"", -1, Self.transient)
      var hits: [PageHit] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        let text = { (i: Int32) in sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        hits.append(PageHit(source: text(0), page: Int(text(1)) ?? 0, snippet: SearchHit.excerpt(text(2), before: 40, length: 140)))
      }
      return hits
    }
  }

  // 영어와 한국어를 함께 찾는다. 세 글자보다 짧으면 FTS 대신 LIKE 로 찾는다.
  public func search(_ query: String, limit: Int = 40) -> [SearchHit] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return [] }
    return lock.withLock {
      guard open() != nil else { return [] }
      let sql: String
      let arg: String
      if q.count >= 3 {
        sql = """
          SELECT u.concept, u.unit, c.title, c.title_ko, highlight(units, 2, char(1), char(2)), highlight(units, 3, char(1), char(2))
          FROM units u JOIN concepts c ON c.id = u.concept WHERE units MATCH ? ORDER BY rank LIMIT \(limit)
          """
        arg = "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
      } else {
        sql = """
          SELECT u.concept, u.unit, c.title, c.title_ko, u.en, u.ko
          FROM units u JOIN concepts c ON c.id = u.concept WHERE u.en LIKE ? OR u.ko LIKE ? LIMIT \(limit)
          """
        arg = "%" + q + "%"
      }
      var stmt: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
      defer { sqlite3_finalize(stmt) }
      sqlite3_bind_text(stmt, 1, arg, -1, Self.transient)
      if q.count < 3 { sqlite3_bind_text(stmt, 2, arg, -1, Self.transient) }
      var hits: [SearchHit] = []
      func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
      while sqlite3_step(stmt) == SQLITE_ROW {
        // 찾은 말이 있는 칸(영어나 한국어)을 고른다. 짧은 말은 FTS 가 표시하지 않으므로 여기서 표시한다.
        let columns = [text(4), text(5)].compactMap { $0 }.map { q.count >= 3 ? $0 : Self.mark($0, q) }
        let marked = columns.first { $0.contains(SearchHit.open) } ?? columns.first ?? ""
        hits.append(SearchHit(concept: text(0) ?? "", unit: text(1), title: text(2) ?? "", titleKo: text(3), snippet: SearchHit.excerpt(marked)))
      }
      return hits
    }
  }
}
