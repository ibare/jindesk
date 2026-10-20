import JindeskKit
import SwiftUI

// 개념 다시 정리 후보의 대응표 (DECISIONS.md 47). 고른 개념마다 무엇이 되었는지 보고 반영하거나 버린다.
// 반영하면 개념을 쓰고, 없앤 개념을 지우고, 코멘트와 요구가 옮겨 간 단위를 따라간다. 버리면 데이터는 그대로다.
struct RecurationReview: View {
  @Environment(AppModel.self) private var model
  let proposal: Recuration.Proposal
  @State private var error: String?
  @State private var busy = false
  @State private var discarding = false

  var body: some View {
    let subject = model.library.subjects.first { $0.id == proposal.subject }?.name ?? proposal.subject
    let jobsBusy = model.jobs?.isBusy ?? false
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("\(subject) · 개념 다시 정리").font(.system(size: 12)).foregroundStyle(.secondary)
          Text("개념 \(proposal.before)개 → \(proposal.after)개").font(.system(size: 26, weight: .semibold, design: .serif))
          Text(proposal.held > 0 ? "보류한 엔트리 \(proposal.held)개 · 아직 반영하지 않았습니다" : "아직 반영하지 않았습니다")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
          GridRow {
            Text("지금").gridColumnAlignment(.leading)
            Text("됨")
            Text("다시 정리한 뒤")
          }
          .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
          Divider().gridCellUnsizedAxes(.horizontal)
          ForEach(Array(proposal.rows.enumerated()), id: \.offset) { _, row in
            GridRow {
              Text(row.concept.isEmpty ? "—" : row.title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
              ActionPill(action: row.action)
              Text(row.action == "새 개념" ? row.title + " (새)" : row.targets.isEmpty ? "—" : row.targets.joined(separator: "\n"))
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
        if let report = model.proposalReport(proposal.job), !report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          DisclosureGroup("정리 기록") {
            Text(report).font(.system(size: 12.5)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
          }
          .font(.system(size: 13))
        }
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
        HStack {
          Text(jobsBusy ? "작업이 끝나면 반영할 수 있습니다" : "반영하면 바뀐 개념의 페이지를 다시 만듭니다").font(.system(size: 12)).foregroundStyle(.secondary)
          Spacer()
          Button("버리기") { discarding = true }.disabled(busy)
          Button(busy ? "반영하는 중…" : "반영") {
            busy = true
            Task {
              do {
                try await model.applyRecuration(proposal.job)
              } catch {
                self.error = error.localizedDescription
              }
              busy = false
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(busy || jobsBusy)
        }
      }
      .padding(.horizontal, 32)
      .padding(.vertical, 28)
      .frame(maxWidth: 760, alignment: .leading)
    }
    .confirmationDialog("이 다시 정리를 버릴까요?", isPresented: $discarding) {
      Button("버리기", role: .destructive) {
        do { try model.discardRecuration(proposal.job) } catch { self.error = error.localizedDescription }
      }
      Button("취소", role: .cancel) {}
    } message: {
      Text("개념은 지금 그대로 둡니다. 다시 하려면 개념을 골라 다시 정리합니다.")
    }
  }
}

// 대응표의 "됨": 합침, 나눔, 없앰 같은 것을 색으로 가른다
struct ActionPill: View {
  let action: String

  var body: some View {
    Text(action)
      .font(.system(size: 11.5, weight: .semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .overlay(Capsule().stroke(color.opacity(0.7)))
      .fixedSize()
  }

  var color: Color {
    switch action {
    case "없앰": .red
    case "합침": .orange
    case "나눔", "새 개념": .green
    case "그대로": .secondary
    default: .accentColor
    }
  }
}
