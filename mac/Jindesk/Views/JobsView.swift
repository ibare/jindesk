import JindeskKit
import SwiftUI

// 작업 화면의 목록 칸: 진행 중, 대기열, 최근에 끝난 작업. 고른 작업의 기록은 내용 칸(JobDetail)에 보인다.
struct JobsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    let jobs = model.jobs
    let active = jobs?.active ?? []
    let queue = jobs?.queue ?? []
    let recent = model.history.map(\.snapshot).filter { s in !active.contains { $0.id == s.id } }
    List(selection: $model.selectedJob) {
      Section("진행 중") {
        if active.isEmpty { Text("쉬는 중").foregroundStyle(.secondary) }
        ForEach(active) { JobRow(snapshot: $0).tag($0.id) }
      }
      Section("대기열") {
        if queue.isEmpty { Text("비어 있습니다").foregroundStyle(.secondary) }
        ForEach(queue) { s in
          JobRow(snapshot: s, reason: jobs?.blocker(s.id).map(BlockerText.short)).tag(s.id)
        }
      }
      Section("최근") {
        if recent.isEmpty { Text("아직 끝난 작업이 없습니다").foregroundStyle(.secondary) }
        ForEach(recent.prefix(30)) { JobRow(snapshot: $0).tag($0.id) }
      }
    }
  }
}

struct JobRow: View {
  let snapshot: JobSnapshot
  var reason: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(snapshot.typeLabel).font(.callout.weight(.medium))
        Spacer()
        if snapshot.isActive {
          // 도는 작업: 단계, 지난 시간, 턴 수
          TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(activeLine(now: ctx.date)).font(.caption).foregroundStyle(color).monospacedDigit()
          }
        } else {
          Text(snapshot.phaseLabel).font(.caption).foregroundStyle(color)
        }
      }
      if snapshot.isActive, let kind = snapshot.kind {
        PhaseBar(kind: kind, phase: snapshot.phase, pulse: false).padding(.vertical, 2)
      }
      Text(snapshot.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      if let reason { Text(reason).font(.caption2).foregroundStyle(.tertiary) }
    }
    .padding(.vertical, 2)
  }

  private func activeLine(now: Date) -> String {
    var parts = [snapshot.phaseLabel]
    if let start = snapshot.startedAt.flatMap(Clock.parse) { parts.append(ActivityFormat.clock(now.timeIntervalSince(start))) }
    if let t = snapshot.shownTurns, t > 0 { parts.append("\(t)턴") }
    return parts.joined(separator: " · ")
  }

  private var color: Color {
    switch snapshot.phase {
    case "failed", "interrupted": .red
    case "done": .green
    case "cancelled": .secondary
    default: .accentColor
    }
  }
}

struct JobDetail: View {
  @Environment(AppModel.self) private var model
  let id: String?

  var body: some View {
    if let id, let jobs = model.jobs, let s = jobs.snapshot(id) ?? model.history.first(where: { $0.snapshot.id == id })?.snapshot {
      let logs = jobs.isActive(id) || jobs.snapshot(id) != nil ? jobs.logs(id) : (model.history.first { $0.snapshot.id == id }?.logs ?? [])
      VStack(alignment: .leading, spacing: 10) {
        Text("\(s.typeLabel) · \(s.title)").font(.title3.weight(.semibold))
        Text("\(s.phaseLabel) · \(s.id)").font(.callout).foregroundStyle(.secondary)
        if let error = s.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        HStack {
          if jobs.isActive(id) || jobs.queue.contains(where: { $0.id == id }) {
            Button("취소") { jobs.cancel(id) }
          }
          Button("작업 폴더 보기") { model.reveal(model.folders.workDir(id)) }
            .disabled(!FileOps.exists(model.folders.workDir(id)))
        }
        Divider()
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(logs) { entry in
              Text("\(entry.at.suffix(14).prefix(8)) \(entry.message)")
                .font(.caption.monospaced())
                .foregroundStyle(entry.kind == .error ? .red : entry.kind == .warn ? .orange : .primary)
                .textSelection(.enabled)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(16)
    } else {
      ContentUnavailableView("작업을 고르세요", systemImage: "gearshape.2")
    }
  }
}

enum BlockerText {
  static func short(_ b: JobBlocker) -> String {
    switch b {
    case .otherProcess: "다른 Jindesk 프로세스가 작업 중"
    case .held(let hold): hold.label
    case .exclusive: "마이그레이션이 혼자 돌아야 함"
    case .serial: "같은 대상의 작업이 끝나기를 기다림"
    case .usage(let w, threshold: let threshold):"사용량 \(w.percent)% (기준 \(threshold)%) · \(w.resetDate.formatted(date: .omitted, time: .shortened)) 에 다시 봄"
    case .slots(let lane, let n): "\(lane.label) 대기열 자리 \(n)개가 참"
    }
  }
}
