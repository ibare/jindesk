// 스키마 1 → 2 (DECISIONS.md 47, MIGRATION.md 의 단계). 개념 다시 정리가 생겨 데이터에 새 모양이 생긴다.
// - library/moves.jsonl 의 단위 옮김 줄 (kind "unit", 자리는 "<개념 id>#<단위 id>")
// - records/concept-curation/<작업 id>/ 의 다시 정리 후보(proposal.json)와 결정(decision.json), plan.json 의 없앤 개념(retired)
// 이미 있는 데이터에는 그런 줄과 파일이 없으므로 바꿀 것이 없다. 판만 올린다.
import Foundation

struct Step_1_2: MigrationStep {
  let from = 1
  let kind = MigrationKind.code
  let summary = "개념 다시 정리: 단위 옮김 줄과 다시 정리 후보·결정 기록이 생긴다. 이미 있는 데이터는 바꾸지 않는다"

  func run(_ copy: DataFolder, _ context: MigrationContext) async throws {}
}
