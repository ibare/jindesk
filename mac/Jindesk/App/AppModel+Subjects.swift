import JindeskKit
import SwiftUI

// 사이드바에서 고른 것: 오늘, 모아 보기, 작업, 또는 과목 하나 (DECISIONS.md 39)
enum SidebarPick: Hashable {
  case section(SidebarSection)
  case subject(String)
}

// 과목 목록: 사이드바의 과목과 목록 칸의 스택 (과목 단계 → 단원 단계, DECISIONS.md 39)
extension AppModel {
  // 사이드바의 선택. 과목 화면이면 그 과목이다.
  var sidebarPick: SidebarPick? {
    get { section == .subjects ? currentSubject.map { .subject($0) } : .section(section) }
    set {
      switch newValue {
      case .subject(let id)?: pickSubject(id)
      case .section(let s)?: section = s
      case nil: break
      }
    }
  }

  // 목록 칸이 여는 과목. 고른 과목이 없어졌으면 첫 과목이다.
  var currentSubject: String? {
    if let subject, library.subjects.contains(where: { $0.id == subject }) { return subject }
    return library.subjects.first?.id
  }

  // 사이드바에서 과목을 고른다. 다른 과목이면 과목 단계에서 연다.
  // 고른 것이 이 과목의 것이 아니면(다른 과목, 모아 보기의 항목 등) 들어가 있던 단원의 개요로 바꾼다.
  func pickSubject(_ id: String) {
    section = .subjects
    if subject != id {
      subject = id
      openUnit = nil
    }
    guard Self.subject(of: selection) != id else { return }
    selection = openUnit.map { .unit(id, $0) }
  }

  // 단원 줄을 누르면 단원 단계로 들어가고 단원 개요를 연다
  func enterUnit(_ subject: String, _ key: String) {
    self.subject = subject
    openUnit = key
    selection = .unit(subject, key)
  }

  // 고른 것을 따라 목록 칸의 과목과 단원을 옮긴다 (앞뒤 개념, 개념 지도, 찾기, 오늘에서 열었을 때)
  func follow(_ s: SubjectSelection?) {
    switch s {
    case .concept(let id)?:
      guard let c = concept(id) else { return }
      subject = c.subject
      openUnit = SubjectUnits.key(c, syllabus: syllabi[c.subject])
    case .unit(let subject, let key)?:
      self.subject = subject
      openUnit = key
    case .map(let subject)?:
      self.subject = subject
      openUnit = nil
    default:
      break
    }
  }

  // 과목의 단원 (이름의 알파벳순)
  func units(_ subject: String) -> [SubjectUnit] {
    SubjectUnits.make(concepts[subject] ?? [], syllabus: syllabi[subject])
  }

  // 그 과목에 하루 안에 정리된 개념이 있다
  func hasNew(subject: String) -> Bool {
    (concepts[subject] ?? []).contains { $0.isNew() }
  }

  // 고른 것의 과목 (개념, 개념 지도, 단원 개요)
  static func subject(of s: SubjectSelection?) -> String? {
    switch s {
    case .concept(let id)?: ConceptID(id)?.subject
    case .map(let subject)?, .unit(let subject, _)?: subject
    default: nil
    }
  }
}
