// SQLite 색인 (DATA.md 의 색인). 캐시의 index.sqlite 에 둔다. 원본이 아니라서 깨지거나 스키마가 바뀌면 지우고 다시 만든다.
// 담는 것: 개념 목록(과목, 항목, 제목, 한국어 제목)과 단위 글(영어, 한국어), 자료 쪽의 글자층(찾기의 원래 자료, DECISIONS.md 34),
// 비슷한 말 제안에 쓰는 낱말 목록. 글은 악센트를 가리지 않는 trigram FTS5 로 찾는다 (DECISIONS.md 48).
// 개념 폴더의 파일과 자료의 글자층(크기, 수정 시각)이 바뀌었을 때만 그 부분을 다시 만든다.
import Foundation
import SQLite3

// 찾은 개념 하나: 개념 단위로 묶고 순위를 매긴 것
public struct ConceptMatch: Sendable, Equatable, Identifiable {
  public struct Snippet: Sendable, Equatable {
    public let unit: String
    // 맞은 곳 앞뒤 글. 찾은 말은 SearchMark.open … close 사이에 있다
    public let text: String
  }

  public let concept: String
  public let subject: String
  public let title: String
  public let titleKo: String?
  // 이름(영어나 한국어)에 모든 낱말이 들었다
  public let inTitle: Bool
  // 맞은 단위 수 (이름 줄은 세지 않는다)
  public let count: Int
  // 맞은 단위의 앞뒤 글, 페이지 차례로 셋까지
  public let snippets: [Snippet]
  public var id: String { concept }
  // 학습 페이지를 열 때 내려갈 단위
  public var firstUnit: String? { snippets.first?.unit }
}

public struct SearchResults: Sendable, Equatable {
  public var concepts: [ConceptMatch] = []
  // 찾은 것이 없을 때 비슷한 말로 바꾼 질의 (셋까지)
  public var suggestions: [String] = []
  public static let empty = SearchResults()
}

// 원래 자료의 쪽에서 찾은 곳
public struct PageHit: Sendable, Equatable, Identifiable {
  public let source: String
  public let page: Int
  // 찾은 말이 SearchMark.open, SearchMark.close 사이에 있는 앞뒤 글
  public let snippet: String
  public var id: String { "\(source)#\(page)" }
}

public final class SearchIndex: @unchecked Sendable {
  static let schema = 4
  // 개념 상한과 개념마다 드는 앞뒤 글 수
  public static let conceptLimit = 100
  static let snippetLimit = 3
  private let lock = NSLock()
  private var db: OpaquePointer?
  public let url: URL

  public convenience init(_ folders: AppFolders) {
    self.init(url: folders.cache.appending(path: "index.sqlite"))
  }

  // 명령줄처럼 앱의 색인과 따로 둘 때
  public init(url: URL) {
    self.url = url
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
      exec("DROP TABLE IF EXISTS concepts; DROP TABLE IF EXISTS units; DROP TABLE IF EXISTS pages; DROP TABLE IF EXISTS words; DROP TABLE IF EXISTS meta;")
      exec(
        """
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE concepts(id TEXT PRIMARY KEY, subject TEXT, item TEXT, title TEXT, title_ko TEXT);
        CREATE VIRTUAL TABLE units USING fts5(concept UNINDEXED, unit UNINDEXED, en, ko, tokenize='trigram remove_diacritics 1');
        CREATE VIRTUAL TABLE pages USING fts5(source UNINDEXED, page UNINDEXED, text, tokenize='trigram remove_diacritics 1');
        CREATE TABLE words(word TEXT PRIMARY KEY, n INTEGER);
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

  // 줄마다 칸을 글로 돌려준다 (NULL 은 nil)
  private func rows(_ sql: String, _ args: [String]) -> [[String?]] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    for (i, a) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), a, -1, Self.transient) }
    var out: [[String?]] = []
    let n = sqlite3_column_count(stmt)
    while sqlite3_step(stmt) == SQLITE_ROW {
      out.append((0..<n).map { i in sqlite3_column_text(stmt, i).map { String(cString: $0) } })
    }
    return out
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
      exec("BEGIN; DELETE FROM concepts; DELETE FROM units; DELETE FROM words;")
      var words: [String: Int] = [:]
      func count(_ text: String?) {
        guard let text else { return }
        for w in Self.latinWords(text) { words[w, default: 0] += 1 }
      }
      for c in ConceptStore.everything(data) {
        let folder = ConceptFolder(c.cid, in: data)
        let page = Page.load(folder)
        let layers = Layers.load(folder)
        run("INSERT INTO concepts VALUES (?, ?, ?, ?, ?)", [c.id, c.subject, c.item ?? c.itemProposed, c.title, page?.titleKo])
        // 이름 줄: 단위 id 가 없다. 단위보다 먼저 넣어 rowid 가 페이지 차례를 따르게 한다
        run("INSERT INTO units VALUES (?, ?, ?, ?)", [c.id, nil, c.title, page?.titleKo])
        count(c.title)
        // 단위 글은 수식 구분자와 마크다운 표시를 걷어 담는다 (찾기 결과에 그대로 보인다)
        if let page {
          for u in page.units where u.english != nil {
            let en = u.english.map(TexText.plain)
            run("INSERT INTO units VALUES (?, ?, ?, ?)", [c.id, u.id, en, (layers?.ko[u.id]?.text).map(TexText.plain)])
            count(en)
          }
        } else {
          for u in c.units {
            let en = TexText.plain(u.text)
            run("INSERT INTO units VALUES (?, ?, ?, ?)", [c.id, u.id, en, nil])
            count(en)
          }
        }
      }
      for (w, n) in words { run("INSERT INTO words VALUES (?, ?)", [w, String(n)]) }
      run("INSERT OR REPLACE INTO meta VALUES ('signature', ?)", [sig])
      exec("COMMIT;")
      return true
    }
  }

  // 비슷한 말 제안의 낱말: 라틴 문자(악센트 포함) 네 글자 이상, 소문자
  static func latinWords(_ text: String) -> [String] {
    var out: [String] = []
    var current = ""
    func flush() {
      if current.count >= 4 { out.append(current.lowercased()) }
      current = ""
    }
    for ch in text {
      if ch.isLetter, ch.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic && $0.value < 0x0250 }) { current.append(ch) } else { flush() }
    }
    flush()
    return out
  }

  // MARK: - 찾기

  // 맞은 단위 하나 (WHERE 를 지난 줄)
  private struct Row {
    let concept: String
    let unit: String?
    let en: String?
    let ko: String?
    let subject: String
    let title: String
    let titleKo: String?
    let rank: Double
  }

  // 한 단위(이름 줄 포함) 안에 모든 낱말이 든 줄을 페이지 차례로
  private func matchingRows(_ q: SearchQuery) -> [Row] {
    var conditions: [String] = []
    var args: [String] = []
    if let match = q.match {
      conditions.append("units MATCH ?")
      args.append(match)
    }
    for s in q.short {
      conditions.append("(u.en LIKE ? OR u.ko LIKE ?)")
      args += ["%\(s)%", "%\(s)%"]
    }
    let rank = q.match == nil ? "0" : "u.rank"
    let sql = """
      SELECT u.concept, u.unit, u.en, u.ko, c.subject, c.title, c.title_ko, \(rank)
      FROM units u JOIN concepts c ON c.id = u.concept WHERE \(conditions.joined(separator: " AND ")) ORDER BY u.rowid
      """
    return rows(sql, args).map { r in
      Row(concept: r[0] ?? "", unit: r[1], en: r[2], ko: r[3], subject: r[4] ?? "", title: r[5] ?? "", titleKo: r[6], rank: Double(r[7] ?? "0") ?? 0)
    }
  }

  // 찾은 개념을 순위대로 (DECISIONS.md 48): 이름에 든 개념, 친 말이 그대로 든 개념, 맞은 단위가 많은 개념, FTS 순위.
  // 앞의 셋은 낱말 첫머리에서 맞은 것을 센다 (SearchQuery.startsWord). 낱말 가운데에 걸린 것("using" 안의 "sin")은 뒤로 간다.
  // 결과가 없으면 비슷한 말로 바꾼 질의를 셋까지 붙인다 (그 질의로 찾은 것이 있을 때만).
  public func search(_ query: String, limit: Int = SearchIndex.conceptLimit) -> SearchResults {
    let q = SearchQuery(query)
    guard !q.isEmpty else { return .empty }
    return lock.withLock {
      guard open() != nil else { return .empty }
      var results = SearchResults(concepts: concepts(q, limit: limit))
      if results.concepts.isEmpty { results.suggestions = suggestions(q) }
      return results
    }
  }

  private func concepts(_ q: SearchQuery, limit: Int) -> [ConceptMatch] {
    var order: [String] = []
    var byConcept: [String: [Row]] = [:]
    for r in matchingRows(q) {
      if byConcept[r.concept] == nil { order.append(r.concept) }
      byConcept[r.concept, default: []].append(r)
    }
    let multi = q.terms.count > 1
    let ranked = order.map { id -> (match: ConceptMatch, titleStart: Bool, exact: Bool, starts: Int, rank: Double) in
      let rows = byConcept[id]!
      func fields(_ r: Row) -> [String] { [r.en, r.ko].compactMap { $0 } }
      let units = rows.filter { $0.unit != nil }
      let titleStart = rows.contains { $0.unit == nil && q.startsWords(fields($0)) }
      let exact = multi && rows.contains { r in fields(r).contains { SearchQuery.startsWord($0, q.phrase) } }
      // 첫머리로 맞은 단위를 먼저 (페이지 차례는 그 안에서 지킨다). 찾은 곳으로 데려갈 때도 이 차례의 첫 단위로 간다
      let starting = units.filter { q.startsWords(fields($0)) }
      let ordered = starting + units.filter { u in !starting.contains { $0.unit == u.unit } }
      let snippets = ordered.prefix(Self.snippetLimit).map { r -> ConceptMatch.Snippet in
        // 찾은 말이 든 칸 (영어 먼저)
        let marked = [r.en, r.ko].compactMap { $0 }.map(q.mark)
        let text = marked.first { $0.contains(SearchMark.open) } ?? marked.first ?? ""
        return ConceptMatch.Snippet(unit: r.unit!, text: SearchMark.excerpt(text))
      }
      let first = rows[0]
      let match = ConceptMatch(
        concept: id, subject: first.subject, title: first.title, titleKo: first.titleKo, inTitle: rows.contains { $0.unit == nil }, count: units.count,
        snippets: snippets)
      return (match, titleStart, exact, starting.count, rows.map(\.rank).min() ?? 0)
    }
    return ranked.sorted { a, b in
      if a.titleStart != b.titleStart { return a.titleStart }
      if a.exact != b.exact { return a.exact }
      if a.starts != b.starts { return a.starts > b.starts }
      if a.match.count != b.match.count { return a.match.count > b.match.count }
      if a.rank != b.rank { return a.rank < b.rank }
      return a.match.title.localizedCaseInsensitiveCompare(b.match.title) == .orderedAscending
    }.prefix(limit).map(\.match)
  }

  // 낱말 목록에 없는 라틴 문자 낱말(네 글자 이상)을 가까운 낱말로 바꾼 질의. 찾은 것이 있는 것만 셋까지
  private func suggestions(_ q: SearchQuery) -> [String] {
    var candidates: [(term: String, words: [String])] = []
    for term in q.terms where !term.contains(" ") && Self.latinWords(term) == [term.lowercased()] {
      let folded = Self.fold(term)
      let max = folded.count <= 5 ? 1 : 2
      // 묶는 값은 글이라 정수로 바꿔 견준다 (글과 정수를 견주면 늘 거짓이다)
      let near = rows(
        "SELECT word, n FROM words WHERE length(word) BETWEEN CAST(? AS INTEGER) AND CAST(? AS INTEGER)", [String(folded.count - max), String(folded.count + max)])
        .compactMap { r -> (word: String, distance: Int, n: Int)? in
          guard let w = r[0] else { return nil }
          let d = Self.distance(folded, Self.fold(w), limit: max)
          return d <= max ? (w, d, Int(r[1] ?? "0") ?? 0) : nil
        }
      // 낱말 목록에 그대로 있으면 오타가 아니다
      if near.contains(where: { $0.distance == 0 }) { continue }
      let best = near.sorted { ($0.distance, -$0.n) < ($1.distance, -$1.n) }.map(\.word)
      if !best.isEmpty { candidates.append((term, Array(best.prefix(3)))) }
    }
    guard !candidates.isEmpty else { return [] }
    func replaced(_ choice: [String: String]) -> String {
      q.terms.map { t in choice[t].map { $0 } ?? (t.contains(" ") ? "\"\(t)\"" : t) }.joined(separator: " ")
    }
    // 낱말마다 가장 가까운 것으로 바꾼 질의, 그다음 첫 낱말만 다음 후보로 바꾼 질의
    let best = Dictionary(uniqueKeysWithValues: candidates.map { ($0.term, $0.words[0]) })
    var options = [replaced(best)]
    for w in candidates[0].words.dropFirst() {
      var choice = best
      choice[candidates[0].term] = w
      options.append(replaced(choice))
    }
    var out: [String] = []
    for o in options where !out.contains(o) && !concepts(SearchQuery(o), limit: 1).isEmpty {
      out.append(o)
      if out.count == 3 { break }
    }
    return out
  }

  static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

  // 편집 거리 (limit 을 넘으면 limit + 1)
  static func distance(_ a: String, _ b: String, limit: Int) -> Int {
    let a = Array(a)
    let b = Array(b)
    if abs(a.count - b.count) > limit { return limit + 1 }
    var prev = Array(0...b.count)
    for i in 1...max(a.count, 1) where !a.isEmpty {
      var cur = [i] + Array(repeating: 0, count: b.count)
      var best = cur[0]
      for j in 1...max(b.count, 1) where !b.isEmpty {
        cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        best = min(best, cur[j])
      }
      if best > limit { return limit + 1 }
      prev = cur
    }
    return a.isEmpty ? b.count : prev[b.count]
  }

  // 원래 자료의 쪽에서 찾는다 (자료, 쪽 차례). 세 글자 이상인 낱말이 하나는 있어야 찾는다 (짧은 말만으로는 글자층에 너무 많이 맞는다).
  public func sourcePages(_ query: String, limit: Int = 400) -> [PageHit] {
    let q = SearchQuery(query)
    guard let match = q.match else { return [] }
    return lock.withLock {
      guard open() != nil else { return [] }
      var sql = "SELECT source, page, text FROM pages WHERE pages MATCH ?"
      var args = [match]
      for s in q.short {
        sql += " AND text LIKE ?"
        args.append("%\(s)%")
      }
      sql += " ORDER BY source, CAST(page AS INTEGER) LIMIT \(limit)"
      return rows(sql, args).map { r in
        PageHit(source: r[0] ?? "", page: Int(r[1] ?? "0") ?? 0, snippet: SearchMark.excerpt(q.mark(r[2] ?? ""), before: 40, length: 140))
      }
    }
  }
}
