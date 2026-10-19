import Foundation

// 작업 종류 (JOBS.md 의 표). 종류마다 jobs/<id>/INSTRUCTIONS.md 하나가 그 작업 에이전트의 지침이다.
public enum JobKind: String, CaseIterable, Sendable, Codable {
  case syllabusBuild = "syllabus-build"
  case sourceIntake = "source-intake"
  case sourceReading = "source-reading"
  case conceptCuration = "concept-curation"
  case pageBuild = "page-build"
  case translation
  case facets
  case ask
  case regen
  case practice
  case migration

  public var label: String {
    switch self {
    case .syllabusBuild: "목차 만들기"
    case .sourceIntake: "자료 넣기"
    case .sourceReading: "자료 읽기"
    case .conceptCuration: "개념 정리"
    case .pageBuild: "학습 페이지 만들기"
    case .translation: "번역"
    case .facets: "관점 붙이기"
    case .ask: "물어보기"
    case .regen: "부분 다시 만들기"
    case .practice: "확인 문제"
    case .migration: "마이그레이션"
    }
  }

  public var lane: JobLane {
    switch self {
    case .sourceIntake, .sourceReading: .sources
    case .syllabusBuild, .conceptCuration: .curation
    case .pageBuild, .translation, .facets: .pages
    case .ask, .regen, .practice: .conversation
    case .migration: .migration
    }
  }

  // 작업 종류마다 정한 단계 (대기·완료·실패·취소는 공통이라 넣지 않는다). 작업을 만들 때 채운다.
  public var phases: [JobPhase] {
    switch self {
    case .sourceIntake: [.init(id: "preparing", label: "입력 고정"), .init(id: "running", label: "넣기")]
    default:
      [
        .init(id: "preparing", label: "입력 고정"), .init(id: "running", label: "실행"), .init(id: "checking", label: "검사"),
        .init(id: "fixing", label: "고쳐 쓰기"), .init(id: "finalizing", label: "반영"),
      ]
    }
  }

  public func phaseLabel(_ phase: String) -> String {
    phases.first { $0.id == phase }?.label ?? JobSnapshot.commonPhaseLabels[phase] ?? phase
  }

  // 지침이 앱 번들에 있어야 하는 종류. 작업을 만들 때마다 더한다 (자료 넣기는 러너만 하므로 지침이 없다).
  public static let withInstructions: [JobKind] = [.syllabusBuild, .sourceReading, .conceptCuration, .pageBuild, .translation, .facets, .ask, .regen]
}

// 대기열 (JOBS.md 의 대기열 표). 대기열마다 함께 도는 수가 있고, 자리가 찬 대기열의 작업은 건너뛰고 뒤의 작업을 먼저 시작한다.
public enum JobLane: String, CaseIterable, Sendable {
  // 자료 넣기, 자료 읽기: 자료마다 서로 상관없다
  case sources
  // 목차 만들기, 개념 정리: 정리층의 내용을 정하는 일이라 하나씩 차례로
  case curation
  // 학습 페이지 만들기, 번역, 관점 붙이기: 작업 하나, 그 안에서 에이전트 셋
  case pages
  // 물어보기, 부분 다시 만들기: 학생이 기다린다. 다른 대기열보다 먼저 자리를 준다
  case conversation
  // 다른 대기열을 모두 멈추고 혼자 돈다
  case migration

  public var label: String {
    switch self {
    case .sources: "자료"
    case .curation: "정리"
    case .pages: "페이지"
    case .conversation: "대화"
    case .migration: "마이그레이션"
    }
  }

  public var defaultLimit: Int {
    switch self {
    case .sources, .conversation: 2
    case .curation, .pages, .migration: 1
    }
  }

  // 설정으로 함께 도는 수를 바꿀 수 있는 대기열
  public var adjustable: Bool { self == .sources || self == .conversation }

  // 자리를 줄 차례 (작을수록 먼저)
  var priority: Int {
    switch self {
    case .migration: 0
    case .conversation: 1
    case .sources: 2
    case .curation: 3
    case .pages: 4
    }
  }
}

public struct JobPhase: Sendable, Equatable {
  public let id: String
  public let label: String
}
