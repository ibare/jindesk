// 스키마 1 → 2 (MIGRATION.md 의 단계, DECISIONS.md 34): 관점(facets.yaml)의 판을 2 로 올린다.
// 판 2 의 관점에는 한 장 요약과 공식으로 고른 주장(summary, formulas)이 있다. 고르기는 에이전트가 하므로 여기서는 비워 두고,
// 관점 붙이기가 남은 일로 고른다 (요약이 없는 관점은 다시 붙인다).
import Foundation

public struct Step_1_2: MigrationStep {
  public let from = 1
  public let kind = MigrationKind.code
  public let summary = "관점(facets.yaml)의 판을 2 로 올린다. 한 장 요약과 공식은 관점 붙이기가 고른다"

  public init() {}

  public func run(_ copy: DataFolder, _ context: MigrationContext) async throws {
    for file in Self.facetFiles(copy) {
      guard var map = try YAML.read(file).map, map["kind"]?.string == "facets" else { continue }
      map["v"] = 2
      try FileOps.writeAtomic(YAML.stringify(map), to: file)
    }
  }

  public func verify(before: MigrationSnapshot, after copy: DataFolder) -> [String] {
    Self.facetFiles(copy).compactMap { file in
      let v = try? YAML.read(file)
      guard v?["kind"]?.string == "facets" else { return nil }
      return v?["v"]?.int == 2 ? nil : "\(file.path(percentEncoded: false)): 관점의 판이 2 가 아닙니다"
    }
  }

  // 개념 폴더의 facets.yaml (library/facets.yaml 은 관점 어휘라 빼고)
  static func facetFiles(_ data: DataFolder) -> [URL] {
    ["concepts", "unplaced"].flatMap { area -> [URL] in
      let root = data.library.appending(path: area)
      guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
      return walk.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "facets.yaml" }.sorted { $0.path < $1.path }
    }
  }
}
