// 자료 → 엔트리 → 개념 → 학습 페이지 → 한국어의 흐름 (JOBS.md 의 뒤따르는 작업).
// 작업은 끝나면 다음 작업을 넣는다. 앱이 꺼지거나 토큰이 없어 흐름이 끊겼으면, 데이터 폴더를 보고 남은 일을 찾아 이어서 한다.
import Foundation

public struct PendingWork: Sendable, Equatable, Identifiable {
  public let kind: JobKind
  // 묶음 id (자료 읽기, 개념 정리) 또는 과목 id
  public let target: String
  public let label: String

  public var id: String { "\(kind.rawValue):\(target)" }
}

public enum Pipeline {
  // 남은 일. 읽기가 남은 묶음은 정리를 넣지 않고, 읽기나 정리가 남은 과목은 페이지 이후 단계를 넣지 않는다 (앞 단계가 끝나면 뒤따라 넣는다).
  public static func pending(_ data: DataFolder, instructions: InstructionSource) -> [PendingWork] {
    var out: [PendingWork] = []
    let library = SourceLibrary.load(data)
    let read = SourceReading.readSources(data)
    let bundles = BundleStore.all(data, library: library)
    var busySubjects: Set<String> = []
    var curation: [PendingWork] = []
    // 과목의 엔트리와 개념은 과목마다 한 번만 읽어 모든 묶음에 나눠 쓴다 (묶음마다 읽으면 묶음 수만큼 늘어난다)
    var entries: [String: ConceptCuration.SubjectEntries] = [:]
    for b in bundles.reversed() {
      guard let subject = BundleStore.subject(b, library: library) else { continue }
      let label = b.title ?? b.sources.first.flatMap { library.source($0)?.meta.original.name } ?? b.id
      if b.sources.contains(where: { read[$0] == nil }) {
        out.append(PendingWork(kind: .sourceReading, target: b.id, label: label))
        busySubjects.insert(subject)
        continue
      }
      let inSubject = entries[subject] ?? ConceptCuration.SubjectEntries(data, subject: subject)
      entries[subject] = inSubject
      if !ConceptCuration.pending(bundle: b, in: inSubject).isEmpty {
        curation.append(PendingWork(kind: .conceptCuration, target: b.id, label: label))
        busySubjects.insert(subject)
      }
    }
    let pageVersion = (try? Instructions.read(instructions, kind: .pageBuild))?.version
    let subjects = Set(EntryStore.subjects(data) + ConceptStore.subjects(data)).sorted()
    for d in Regen.pending(data) {
      out.append(PendingWork(kind: .regen, target: d.id, label: "\(d.op.label) · \(d.target.unit)"))
    }
    for c in Ask.unanswered(data) {
      out.append(PendingWork(kind: .ask, target: c.id, label: FileOps.prefix(c.text ?? "", 40)))
    }
    for s in library.subjects where SyllabusBuild.needed(data, subject: s.id, library: library) {
      out.append(PendingWork(kind: .syllabusBuild, target: s.id, label: s.name))
    }
    out += curation
    for subject in subjects where !busySubjects.contains(subject) {
      if !PageBuild.pending(data, subject: subject, version: pageVersion).isEmpty {
        out.append(PendingWork(kind: .pageBuild, target: subject, label: subject))
      } else if !Translation.pending(data, subject: subject).isEmpty {
        out.append(PendingWork(kind: .translation, target: subject, label: subject))
      } else if !Facets.pendingFacets(data, subject: subject).isEmpty || !Facets.pendingReferences(data, subject: subject).isEmpty {
        out.append(PendingWork(kind: .facets, target: subject, label: subject))
      }
    }
    return out
  }

  public static func prepare(_ work: PendingWork) -> @Sendable (PrepareContext) async throws -> PreparedJob {
    let target = work.target
    switch work.kind {
    case .sourceReading: return { try SourceReading.prepare(bundle: target, $0) }
    case .conceptCuration: return { try ConceptCuration.prepare(bundle: target, $0) }
    case .pageBuild: return { try PageBuild.prepare(subject: target, $0) }
    case .syllabusBuild: return { try SyllabusBuild.prepare(subject: target, $0) }
    case .ask: return { try Ask.prepare(commentID: target, $0) }
    case .regen: return { try Regen.prepare(directiveID: target, $0) }
    case .facets: return { try Facets.prepare(subject: target, $0) }
    default: return { try Translation.prepare(subject: target, $0) }
    }
  }
}
