import JindeskKit
import SwiftUI

// 도구 막대 가운데의 진행 표시 (Assayer 의 활동 표시와 같다). 작업이 돌면 종류·단계, 지난 시간, 턴 수, 대기 수, 단계 막대를 보이고,
// 그 옆에 5시간·주간 사용량(마지막으로 받은 값)을 둔다. 누르면 작업 화면에서 그 작업을 연다.
struct ActivityStatus: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let active = model.jobs?.active ?? []
    let queue = model.jobs?.queue ?? []
    let usage = model.jobs?.usage
    if !active.isEmpty || !queue.isEmpty || usage != nil {
      Button {
        model.section = .jobs
        if let first = active.first ?? queue.first { model.selectedJob = first.id }
      } label: {
        HStack(spacing: 0) {
          if !active.isEmpty || !queue.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
              progress(active, queue: queue, now: ctx.date)
            }
            .padding(.horizontal, 12)
          }
          if let usage {
            if !active.isEmpty || !queue.isEmpty { Divider().frame(height: 26).padding(.trailing, 14) }
            UsageGauges(usage: usage, idle: active.isEmpty).padding(.trailing, active.isEmpty ? 0 : 4)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(help(active, queue: queue))
    }
  }

  @ViewBuilder private func progress(_ active: [JobSnapshot], queue: [JobSnapshot], now: Date) -> some View {
    let pulse = Int(now.timeIntervalSinceReferenceDate) % 2 == 0
    VStack(spacing: 5) {
      if active.count <= 1 {
        HStack(spacing: 6) {
          if let s = active.first {
            Text("\(s.typeLabel) · \(s.phaseLabel)").fontWeight(.medium)
            Group {
              Text(ActivityFormat.clock(s.startedAt.flatMap(Clock.parse).map { now.timeIntervalSince($0) } ?? 0))
              if let t = s.shownTurns, t > 0 { Text("·  \(t)턴") }
              if !queue.isEmpty { Text("·  대기 \(queue.count)") }
            }
            .foregroundStyle(.secondary)
          } else {
            // 돌고 있는 것은 없고 기다리는 것만 있다 (사용량이나 다른 작업 때문에 미뤄졌다)
            Text("대기 \(queue.count)").fontWeight(.medium)
            if let s = queue.first, let reason = model.jobs?.blocker(s.id).map(BlockerText.short) {
              Text("·  \(reason)").foregroundStyle(.secondary)
            }
          }
        }
        .font(.callout)
        .monospacedDigit()
        .lineLimit(1)
        if let s = active.first, let kind = s.kind {
          PhaseBar(kind: kind, phase: s.phase, pulse: pulse).frame(width: 240)
        }
      } else {
        HStack(spacing: 6) {
          Text("진행 \(active.count)").fontWeight(.medium)
          if !queue.isEmpty { Text("·  대기 \(queue.count)").foregroundStyle(.secondary) }
        }
        .font(.callout)
        .monospacedDigit()
        .lineLimit(1)
        // 작업마다 단계 막대 하나. 색은 작업의 대기열 색, 시작한 순서로 놓는다.
        HStack(spacing: 8) {
          ForEach(active) { s in
            if let kind = s.kind {
              PhaseBar(kind: kind, phase: s.phase, pulse: pulse, tint: ActivityFormat.color(kind))
                .frame(width: (240 - 8 * CGFloat(active.count - 1)) / CGFloat(active.count))
            }
          }
        }
      }
    }
  }

  private func help(_ active: [JobSnapshot], queue: [JobSnapshot]) -> String {
    let lines = active.map { "\($0.typeLabel) · \($0.phaseLabel) — \($0.title)" } + queue.map { "대기: \($0.typeLabel) — \($0.title)" }
    return lines.isEmpty ? "계정 사용량 (마지막으로 받은 값)" : lines.joined(separator: "\n")
  }
}

// 작업 종류의 단계마다 한 칸. 지난 단계는 채우고, 지금 단계는 깜빡이고, 남은 단계는 흐리다.
struct PhaseBar: View {
  let kind: JobKind
  let phase: String
  let pulse: Bool
  var tint = Color.accentColor

  var body: some View {
    let current = kind.phases.firstIndex { $0.id == phase }
    HStack(spacing: 3) {
      ForEach(Array(kind.phases.enumerated()), id: \.offset) { i, _ in
        Capsule()
          .fill(i == current ? tint.opacity(pulse ? 0.85 : 0.4) : current.map { i < $0 } == true ? tint : Color.secondary.opacity(0.22))
          .frame(height: 3)
      }
    }
    .animation(.easeInOut(duration: 0.9), value: pulse)
  }
}

// 5시간·주간 사용량
struct UsageGauges: View {
  let usage: UsageReading
  let idle: Bool

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { ctx in
      HStack(spacing: 12) {
        UsageMeter(title: "5시간", window: usage.fiveHour, now: ctx.date)
        UsageMeter(title: "주간", window: usage.sevenDay, now: ctx.date)
        if idle, let at = usage.receivedAt {
          Text("\(at.formatted(date: .omitted, time: .shortened)) 기준").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
        }
      }
      .opacity(idle ? 0.6 : 1)
    }
  }
}

struct UsageMeter: View {
  let title: String
  let window: UsageWindow?
  let now: Date

  var body: some View {
    // 초기화 시각이 지난 값은 지금 값이 아니라 모른다로 보인다
    let current = window.flatMap { $0.isCurrent(at: now) ? $0 : nil }
    let percent = current?.percent ?? 0
    let color: Color = percent >= 95 ? .red : percent >= 80 ? .orange : .secondary
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        Text(title).foregroundStyle(.secondary)
        Spacer(minLength: 2)
        Text(current.map { "\($0.percent)%" } ?? "—")
          .fontWeight(.semibold)
          .foregroundStyle(percent >= 80 ? color : Color.primary)
      }
      .font(.system(size: 11))
      .monospacedDigit()
      GeometryReader { g in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.secondary.opacity(0.22))
          Capsule().fill(color).frame(width: g.size.width * min(max(current?.utilization ?? 0, 0), 1))
        }
      }
      .frame(height: 3)
    }
    .frame(width: 66)
    .help(current.map { "\(title) \($0.percent)% · \($0.resetDate.formatted(date: .omitted, time: .shortened)) 에 초기화" } ?? "\(title): 지금 값을 모릅니다")
  }
}

enum ActivityFormat {
  // m:ss, 한 시간부터 h:mm:ss
  static func clock(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
  }

  static func color(_ kind: JobKind) -> Color {
    switch kind.lane {
    case .sources: .blue
    case .curation: .purple
    case .pages: .teal
    case .conversation: .orange
    case .migration: .gray
    }
  }
}
