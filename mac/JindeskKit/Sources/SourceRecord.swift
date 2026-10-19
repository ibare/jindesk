// 자료 폴더 하나 (sources/<자료 id>/, DATA.md 의 데이터 폴더 배치).
// meta.yaml 은 받을 때 정해진 사실이라 고치지 않는다. labels.yaml 은 학생이 붙인 것이라 고칠 수 있다.
import Foundation

public struct SourceFolder: Sendable, Equatable {
  public let id: String
  public let url: URL

  public init(id: String, in data: DataFolder) {
    self.id = id
    self.url = data.sources.appending(path: id)
  }

  public init(id: String, url: URL) {
    self.id = id
    self.url = url
  }

  public var meta: URL { url.appending(path: "meta.yaml") }
  public var labels: URL { url.appending(path: "labels.yaml") }
  public var index: URL { url.appending(path: "index.md") }
  public var pages: URL { url.appending(path: "pages") }

  public func pageText(_ n: Int) -> URL { pages.appending(path: Self.pageName(n) + ".txt") }

  public static func pageName(_ n: Int) -> String { String(format: "%04d", n) }

  // 받은 그대로의 파일 (original.<확장자>)
  public var original: URL? {
    FileOps.list(url).first { $0.hasPrefix("original.") }.map { url.appending(path: $0) }
  }

  // 쪽을 그릴 문서: 바꾼 PDF 가 있으면 그것, 없으면 원본
  public var renderable: URL? {
    for name in ["source.pdf", "source.jpg"] where FileOps.exists(url.appending(path: name)) { return url.appending(path: name) }
    return original
  }
}

// 자료 id: YYYYMMDD-<내용 해시 앞 8자> (받은 날)
public enum SourceID {
  public static func make(received: Date, sha256: String) -> String {
    String(JobID.stamp(received).prefix(8)) + "-" + String(sha256.prefix(8))
  }

  public static func isValid(_ id: String) -> Bool {
    id.range(of: #"^\d{8}-[0-9a-f]{8}$"#, options: .regularExpression) != nil
  }
}

// meta.yaml: 받을 때 정해진 사실
public struct SourceMeta: Sendable, Equatable {
  public struct Original: Sendable, Equatable {
    public let name: String
    public let bytes: Int
    // sha256 앞 16자
    public let sha256: String
  }

  public struct Conversion: Sendable, Equatable {
    public let to: String
    public let by: String
    public let appVersion: String?
  }

  public struct TextLayer: Sendable, Equatable {
    public let by: String
    public let pagesWithText: Int
    // Vision 글자 인식으로 글자층을 만든 쪽
    public let ocrPages: [Int]
  }

  // 여러 수업이 든 파일을 수업마다 쪼갠 자료의 원래 파일 (자료 나누기, DECISIONS.md 41)
  public struct SplitFrom: Sendable, Equatable {
    public let name: String
    // 원래 파일의 sha256 앞 16자. 같은 파일을 다시 넣으면 이것으로 알아본다
    public let sha256: String
    // 원래 파일에서의 첫 쪽과 마지막 쪽
    public let pages: [Int]
    // 수업 이름 (자료가 쓴 차시 표시와 제목)
    public let title: String
  }

  public let id: String
  public let original: Original
  public let received: String
  public let converted: Conversion?
  public let pages: Int
  public let textLayer: TextLayer
  // 앞 쪽을 이어 채운 쪽 묶음
  public let buildUps: [[Int]]
  public let splitFrom: SplitFrom?

  public init(
    id: String, original: Original, received: String, converted: Conversion?, pages: Int, textLayer: TextLayer, buildUps: [[Int]], splitFrom: SplitFrom? = nil
  ) {
    self.id = id
    self.original = original
    self.received = received
    self.converted = converted
    self.pages = pages
    self.textLayer = textLayer
    self.buildUps = buildUps
    self.splitFrom = splitFrom
  }

  public var yaml: YAMLMap {
    var map: YAMLMap = [
      "kind": "source",
      "v": 1,
      "id": .string(id),
      "original": ["name": .string(original.name), "bytes": .int(original.bytes), "sha256": .string(original.sha256)],
      "received": .string(received),
    ]
    if let c = converted {
      var conv: YAMLMap = ["to": .string(c.to), "by": .string(c.by)]
      if let v = c.appVersion { conv["app_version"] = .string(v) }
      map["converted"] = .map(conv)
    } else {
      map["converted"] = .null
    }
    map["pages"] = .int(pages)
    var layer: YAMLMap = ["by": .string(textLayer.by), "pages_with_text": .int(textLayer.pagesWithText)]
    if !textLayer.ocrPages.isEmpty { layer["ocr"] = ["by": "vision", "pages": .array(textLayer.ocrPages.map(YAMLValue.int))] }
    map["text_layer"] = .map(layer)
    map["build_ups"] = .array(buildUps.map { .array($0.map(YAMLValue.int)) })
    if let s = splitFrom {
      map["split_from"] = ["name": .string(s.name), "sha256": .string(s.sha256), "pages": .array(s.pages.map(YAMLValue.int)), "title": .string(s.title)]
    }
    return map
  }

  public static func read(_ folder: SourceFolder) throws -> SourceMeta {
    let v = try YAML.read(folder.meta)
    guard v["kind"]?.string == "source", let id = v["id"]?.string, let o = v["original"], let name = o["name"]?.string else {
      throw ToolError("\(folder.meta.path) 의 모양이 맞지 않습니다")
    }
    let converted = v["converted"]?.map.map { c in
      Conversion(to: c["to"]?.string ?? "", by: c["by"]?.string ?? "", appVersion: c["app_version"]?.string)
    }
    let layer = v["text_layer"]
    let split = v["split_from"].flatMap { s in
      s["name"]?.string.map { SplitFrom(name: $0, sha256: s["sha256"]?.string ?? "", pages: (s["pages"]?.array ?? []).compactMap(\.int), title: s["title"]?.string ?? "") }
    }
    return SourceMeta(
      id: id, original: Original(name: name, bytes: o["bytes"]?.int ?? 0, sha256: o["sha256"]?.string ?? ""),
      received: v["received"]?.string ?? "", converted: converted, pages: v["pages"]?.int ?? 0,
      textLayer: TextLayer(
        by: layer?["by"]?.string ?? "pdfkit", pagesWithText: layer?["pages_with_text"]?.int ?? 0,
        ocrPages: (layer?["ocr"]?["pages"]?.array ?? []).compactMap(\.int)),
      buildUps: (v["build_ups"]?.array ?? []).map { ($0.array ?? []).compactMap(\.int) }, splitFrom: split)
  }

  public func write(to folder: SourceFolder) throws {
    try FileOps.writeAtomic(YAML.stringify(yaml), to: folder.meta)
  }
}

// labels.yaml: 학생이 붙인 것 (꼬리표, 메모, 목차의 근거 표시)
public struct SourceLabelsFile: Sendable, Equatable {
  public let source: String
  public var labels: SourceLabels
  public var memo: String?
  public var syllabusBasis: Bool

  public init(source: String, labels: SourceLabels, memo: String?, syllabusBasis: Bool) {
    self.source = source
    self.labels = labels
    self.memo = memo?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.syllabusBasis = syllabusBasis
  }

  public var yaml: YAMLMap {
    [
      "kind": "labels",
      "v": 1,
      "source": .string(source),
      "labels": .map(labels.yaml.with(style: .flow)),
      "memo": memo.map(YAMLValue.string) ?? .null,
      "syllabus_basis": .bool(syllabusBasis),
    ]
  }

  public static func read(_ folder: SourceFolder) throws -> SourceLabelsFile {
    let v = try YAML.read(folder.labels)
    guard v["kind"]?.string == "labels" else { throw ToolError("\(folder.labels.path) 의 모양이 맞지 않습니다") }
    return SourceLabelsFile(
      source: v["source"]?.string ?? folder.id, labels: SourceLabels(yaml: v["labels"]?.map), memo: v["memo"]?.string,
      syllabusBasis: v["syllabus_basis"]?.bool ?? false)
  }

  public func write(to folder: SourceFolder) throws {
    try FileOps.writeAtomic(YAML.stringify(yaml), to: folder.labels)
  }
}
