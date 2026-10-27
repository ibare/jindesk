// 작업을 다시 준비하는 입력 (ARCHITECTURE.md 의 비정상 종료). 작업을 넣을 때 run.json 에 함께 남긴다.
// 앱이 끝나 멈춘 작업과 시작하지 못한 대기열은 다음에 켤 때 이것으로 다시 준비해 같은 차례로 넣는다.
import Foundation

public enum JobRecipe: Sendable, Codable, Equatable {
  case sourceIntake(IntakeRequest)
  case sourceSplit(bundle: String)
  case sourceReading(bundle: String, sources: [String]?)
  case conceptCuration(bundle: String)
  // 고른 개념 다시 정리 (DECISIONS.md 47)
  case recuration(subject: String, concepts: [String])
  case syllabusBuild(subject: String)
  case pageBuild(subject: String)
  // 고른 개념의 페이지를 지금 지침으로 다시 만든다 (DECISIONS.md 46)
  case pageRebuild(subject: String, concepts: [String])
  case translation(subject: String)
  case facets(subject: String)
  case ask(comment: String)
  case regen(directive: String)

  public func prepare(_ ctx: PrepareContext) throws -> PreparedJob {
    switch self {
    case .sourceIntake(let request): try SourceIntake.prepare(request, ctx)
    case .sourceSplit(let bundle): try SourceSplit.prepare(bundle: bundle, ctx)
    case .sourceReading(let bundle, let sources): try SourceReading.prepare(bundle: bundle, sources: sources, ctx)
    case .conceptCuration(let bundle): try ConceptCuration.prepare(bundle: bundle, ctx)
    case .recuration(let subject, let concepts): try Recuration.prepare(subject: subject, concepts: concepts, ctx)
    case .syllabusBuild(let subject): try SyllabusBuild.prepare(subject: subject, ctx)
    case .pageBuild(let subject): try PageBuild.prepare(subject: subject, ctx)
    case .pageRebuild(let subject, let concepts): try PageBuild.prepare(subject: subject, rebuild: concepts, ctx)
    case .translation(let subject): try Translation.prepare(subject: subject, ctx)
    case .facets(let subject): try Facets.prepare(subject: subject, ctx)
    case .ask(let comment): try Ask.prepare(commentID: comment, ctx)
    case .regen(let directive): try Regen.prepare(directiveID: directive, ctx)
    }
  }

  // 에이전트를 띄우는가 (자료 넣기는 러너만 한다)
  public var needsAgent: Bool {
    if case .sourceIntake = self { return false }
    return true
  }
}
