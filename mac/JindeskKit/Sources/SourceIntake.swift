// 자료 넣기 (source-intake, JOBS.md). 에이전트 없이 러너만 한다.
// 그날 받은 파일 몇 개에 꼬리표(학년, 과목, 수준)와 메모를 붙여 넣는다. 강의 계획 항목과 단원은 고르지 않는다.
// 자료 하나는 데이터 폴더의 sources/.incoming-<자료 id>/ 에서 다 만든 뒤 sources/<자료 id>/ 로 한 번에 옮긴다.
import Foundation

public struct IntakeRequest: Sendable, Equatable {
  public var files: [URL]
  public var labels: SourceLabels
  public var memo: String?
  public var syllabusBasis: Bool

  public init(files: [URL], labels: SourceLabels, memo: String? = nil, syllabusBasis: Bool = false) {
    self.files = files
    self.labels = labels
    self.memo = memo
    self.syllabusBasis = syllabusBasis
  }
}

// 넣기 전에 파일마다 볼 것: 새 자료인지, 왜 빼는지
public struct IntakeCandidate: Sendable, Equatable, Identifiable {
  public enum Status: Sendable, Equatable {
    case new
    // 이미 넣은 자료 (자료 id)
    case existing(String)
    // 이번에 함께 넣는 파일과 같은 내용 (그 파일 이름)
    case sameAs(String)
    case tooLarge(Int)
    case unsupported(String)
    case unreadable(String)

    public var accepted: Bool { self == .new }

    public var reason: String? {
      switch self {
      case .new: nil
      case .existing(let id): "이미 넣은 자료입니다 (\(id))"
      case .sameAs(let name): "\(name) 와 내용이 같습니다"
      case .tooLarge(let bytes): "너무 큽니다 (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), 상한 \(SourceIntake.sizeLimit / 1024 / 1024)MB)"
      case .unsupported(let ext): "다룰 수 없는 형식입니다 (.\(ext))"
      case .unreadable(let message): "읽지 못했습니다: \(message)"
      }
    }
  }

  public let url: URL
  public let bytes: Int
  // 원본 sha256 (읽지 못했으면 빈 값)
  public let sha256: String
  public let status: Status
  public var id: String { url.path }
  public var name: String { url.lastPathComponent }
}

public enum SourceIntake {
  public static let sizeLimit = 100 * 1024 * 1024

  // 파일마다 해시를 내고, 이미 있는 자료와 이번에 함께 넣는 파일끼리 겹치는지 본다.
  public static func plan(_ files: [URL], library: SourceLibrary, sizeLimit: Int = sizeLimit) -> [IntakeCandidate] {
    let existing = library.hashes
    var seen: [String: String] = [:]
    return files.map { url in
      let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
      let format = SourceFormat(url)
      if case .unsupported(let ext) = format { return IntakeCandidate(url: url, bytes: bytes, sha256: "", status: .unsupported(ext)) }
      if bytes > sizeLimit { return IntakeCandidate(url: url, bytes: bytes, sha256: "", status: .tooLarge(bytes)) }
      let sha: String
      do {
        sha = try Hash.file(url)
      } catch {
        return IntakeCandidate(url: url, bytes: bytes, sha256: "", status: .unreadable(error.localizedDescription))
      }
      let short = String(sha.prefix(16))
      if let id = existing[short] { return IntakeCandidate(url: url, bytes: bytes, sha256: sha, status: .existing(id)) }
      if let first = seen[short] { return IntakeCandidate(url: url, bytes: bytes, sha256: sha, status: .sameAs(first)) }
      seen[short] = url.lastPathComponent
      return IntakeCandidate(url: url, bytes: bytes, sha256: sha, status: .new)
    }
  }

  public static func prepare(_ request: IntakeRequest, _ ctx: PrepareContext) throws -> PreparedJob {
    guard !request.files.isEmpty else { throw RequestError("넣을 파일이 없습니다") }
    for url in request.files where !FileOps.exists(url) { throw RequestError("파일이 없습니다: \(url.path)") }
    let first = request.files[0].deletingPathExtension().lastPathComponent
    let id = try JobID.make(date: ctx.now, slugSource: "intake \(first)", exists: ctx.taken)
    let title = request.files.count == 1 ? request.files[0].lastPathComponent : "\(request.files[0].lastPathComponent) 외 \(request.files.count - 1)개"
    return PreparedJob(id: id, kind: .sourceIntake, title: title) { context in
      try await run(request, context)
    }
  }

  // 시작할 때 다시 고른다. 요청한 뒤 다른 작업이 같은 파일을 넣었으면 뺀다.
  static func run(_ request: IntakeRequest, _ context: JobContext) async throws {
    await context.setPhase("preparing")
    let library = SourceLibrary.load(context.data)
    let labels = LabelMatch.canonical(request.labels) { library.usedValues($0) }
    let candidates = plan(request.files, library: library)
    var warnings: [String] = []
    for c in candidates where !c.status.accepted {
      warnings.append("\(c.name): \(c.status.reason ?? "")")
      await context.log(.warn, "뺌: \(c.name) — \(c.status.reason ?? "")")
    }
    await context.setPhase("running")
    var added: [String] = []
    var failed = 0
    for c in candidates where c.status.accepted {
      try context.checkCancellation()
      await context.log(.info, "넣는 중: \(c.name)")
      do {
        let id = try await ingest(c, labels: labels, memo: request.memo, syllabusBasis: request.syllabusBasis, context: context)
        added.append(id)
        await context.log(.info, "넣었습니다: \(c.name) → \(id)")
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        failed += 1
        warnings.append("\(c.name): \(error.localizedDescription)")
        await context.log(.error, "넣지 못했습니다: \(c.name) — \(error.localizedDescription)")
      }
    }
    await context.report(
      counts: [JobCount(key: "added", label: "넣음", count: added.count), JobCount(key: "skipped", label: "뺌", count: candidates.count - added.count)],
      warnings: warnings.isEmpty ? nil : warnings)
    if added.isEmpty && failed > 0 { throw ToolError("파일을 하나도 넣지 못했습니다") }

    // 뒤따름: 자료마다 자료 읽기. 토큰 없이 넣었으면 넣지 않는다 (토큰을 넣은 뒤 이어서 하기로 읽는다).
    guard !added.isEmpty else { return }
    guard !context.config.claudeToken.isEmpty else {
      await context.log(.warn, "자료 읽기는 넣지 않았습니다. 토큰 없이 넣었거나 명령줄에서 --follow 없이 넣었습니다. 이어서 하기로 읽을 수 있습니다")
      return
    }
    guard labels.subjectID != nil else {
      await context.log(.warn, "과목 꼬리표가 없어 자료 읽기를 넣지 않았습니다. 꼬리표를 붙인 뒤 이어서 하기로 읽을 수 있습니다")
      return
    }
    for id in added where await context.queueFollowUp("자료 읽기", { try SourceReading.prepare(sourceID: id, $0) }) != nil {
      await context.log(.info, "자료 읽기를 대기열에 넣었습니다: \(id)")
    }
  }

  // 자료 하나를 만든다. 돌려주는 값은 자료 id.
  static func ingest(_ candidate: IntakeCandidate, labels: SourceLabels, memo: String?, syllabusBasis: Bool, context: JobContext, now: Date = Date())
    async throws -> String
  {
    let data = context.data
    let id = SourceID.make(received: now, sha256: candidate.sha256)
    let target = SourceFolder(id: id, in: data)
    if FileOps.exists(target.url) { throw ToolError("이미 넣은 자료입니다 (\(id))") }
    let staging = SourceFolder(id: id, url: data.sources.appending(path: ".incoming-\(id)"))
    FileOps.remove(staging.url)
    try FileOps.makeDirectory(staging.url)
    do {
      let ext = candidate.url.pathExtension.lowercased()
      let original = staging.url.appending(path: "original.\(ext)")
      try FileManager.default.copyItem(at: candidate.url, to: original)
      // 복사하는 사이 파일이 바뀌지 않았는지 본다
      guard try Hash.file(original) == candidate.sha256 else { throw ToolError("넣는 동안 파일이 바뀌었습니다. 다시 넣으세요") }

      let format = SourceFormat(candidate.url)
      let converted = try await Converter.convert(
        original, format: format, into: staging.url, soffice: context.config.tools.soffice, environment: context.config.baseEnvironment)
      if let converted { await context.log(.info, "\(converted.by) 로 \(converted.file) 를 만들었습니다") }
      let document = converted.map { staging.url.appending(path: $0.file) } ?? original

      let images = context.folders.pageImages(id)
      FileOps.remove(images)
      let pages = try await PageExtractor.extract(document: document, imagesDir: images) { n, total in
        if n == total || n % 20 == 0 { await context.log(.info, "\(candidate.name): \(n)/\(total)쪽") }
      }
      for p in pages.texts { try FileOps.write(p.text.isEmpty ? "" : p.text + "\n", to: staging.pageText(p.page)) }

      let meta = SourceMeta(
        id: id, original: .init(name: candidate.name, bytes: candidate.bytes, sha256: String(candidate.sha256.prefix(16))),
        received: Clock.isoLocal(now), converted: converted.map { .init(to: $0.file, by: $0.by, appVersion: $0.appVersion) }, pages: pages.count,
        textLayer: .init(
          by: "pdfkit", pagesWithText: pages.texts.filter { !$0.text.isEmpty }.count, ocrPages: pages.texts.filter { $0.by == "vision" }.map(\.page)),
        buildUps: pages.buildUps)
      try meta.write(to: staging)
      try SourceLabelsFile(source: id, labels: labels, memo: memo, syllabusBasis: syllabusBasis).write(to: staging)
      try FileOps.writeAtomic(SourceIndex.markdown(meta, pages), to: staging.index)

      // 한 번에 옮긴다. 그사이 같은 자료가 들어왔으면 넣지 않는다.
      if FileOps.exists(target.url) || SourceLibrary.load(data).hashes[meta.original.sha256] != nil {
        throw ToolError("이미 넣은 자료입니다 (\(id))")
      }
      try FileManager.default.moveItem(at: staging.url, to: target.url)
      return id
    } catch {
      FileOps.remove(staging.url)
      throw error
    }
  }

  // 켤 때 부른다. 넣다가 꺼져 남은 sources/.incoming-* 를 지운다.
  public static func removeLeftovers(_ data: DataFolder) -> [String] {
    FileOps.list(data.sources).filter { $0.hasPrefix(".incoming-") }.map { name in
      FileOps.remove(data.sources.appending(path: name))
      return name
    }
  }
}

// index.md: 에이전트가 먼저 읽는 쪽 목록
public enum SourceIndex {
  public static func markdown(_ meta: SourceMeta, _ pages: ExtractedPages) -> String {
    var lines: [String] = []
    lines.append("# 자료 \(meta.id)")
    lines.append("")
    lines.append("- 원본: \(meta.original.name)")
    if let c = meta.converted { lines.append("- 바꾼 파일: \(c.to) (\(c.by))") }
    lines.append("- 쪽: \(meta.pages)")
    lines.append("- 글자층은 검색과 출처 대조용이다. 수식의 위첨자·아래첨자와 그림 속 글자는 깨질 수 있으니, 뜻은 쪽 이미지로 읽는다.")
    if !meta.buildUps.isEmpty {
      lines.append("- 이어 채운 쪽: 앞 쪽의 글자를 모두 담고 더해 가는 쪽들이다. 마지막 쪽을 중심으로 읽고, 앞 쪽은 필요할 때만 본다.")
      for run in meta.buildUps { lines.append("  - \(run.map(String.init).joined(separator: ", ")) (마지막 모습: \(run.last ?? 0)쪽)") }
    }
    lines.append("")
    lines.append("| 쪽 | 글자 수 | 글자층 | 이어 채움 |")
    lines.append("|---|---|---|---|")
    let runOf = Dictionary(meta.buildUps.flatMap { run in run.map { ($0, run) } }, uniquingKeysWith: { a, _ in a })
    for p in pages.texts {
      var note = ""
      if let run = runOf[p.page] { note = p.page == run.last ? "마지막 모습" : "\(run.last ?? 0)쪽으로 이어짐" }
      lines.append("| \(p.page) | \(p.text.count) | \(p.by) | \(note) |")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
