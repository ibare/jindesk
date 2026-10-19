import JindeskKit
import SwiftUI

// 묶음 보기 (PAGES.md, DECISIONS.md 35): 묶음 이름과 꼬리표, 단계(읽기 · 정리 · 페이지 · 한국어), 자료, 정리된 개념, 보류된 엔트리, 메모.
// 자료 더하기, 자료를 다른 묶음으로 옮기기, 다른 묶음과 합치기, 메모 고치기를 여기서 한다.
struct BundleDetailView: View {
  @Environment(AppModel.self) private var model
  let bundle: SourceBundle
  @State private var memo = ""
  @State private var error: String?

  var body: some View {
    let members = model.members(bundle)
    let progress = model.progress(bundle)
    let concepts = model.concepts(fromBundle: bundle)
    let held = model.heldEntries(bundle)
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header(members)
        if let error { Text(error).font(.callout).foregroundStyle(.red) }
        Grid(horizontalSpacing: 8, verticalSpacing: 0) {
          GridRow {
            ForEach(Array(progress.stages.enumerated()), id: \.offset) { _, stage in
              StageCell(name: stage.name, state: stage.state)
            }
          }
        }
        HStack(alignment: .top, spacing: 18) {
          VStack(alignment: .leading, spacing: 8) {
            ListLabel(text: "자료", trailing: "\(members.count)")
            ForEach(members) { SourceInBundleRow(source: $0, bundle: bundle) }
            ListLabel(text: "메모", trailing: nil).padding(.top, 8)
            HStack {
              TextField("메모 (적지 않아도 됩니다)", text: $memo).textFieldStyle(.roundedBorder)
              if memo != (bundle.memo ?? "") { Button("저장") { save { try model.setBundleMemo(bundle.id, memo: memo) } } }
            }
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          VStack(alignment: .leading, spacing: 8) {
            ListLabel(text: "이 묶음에서 정리된 개념 · 배우는 순서", trailing: "\(concepts.count)")
            if concepts.isEmpty {
              Text(progress.summary).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(concepts) { c in
              let state = model.pageState(c)
              Button {
                model.selection = .concept(c.id)
              } label: {
                HStack(spacing: 8) {
                  ConceptNames(title: c.title, titleKo: state.titleKo)
                  Spacer(minLength: 4)
                  Text(state.hasPage ? (state.note ?? "페이지 있음") : "페이지 만드는 중").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(8)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .card()
            }
            if !held.isEmpty {
              ListLabel(text: "보류된 엔트리 · 관련 자료가 들어오면 보충합니다", trailing: "\(held.count)").padding(.top, 8)
              ForEach(held, id: \.entry.id) { h in
                VStack(alignment: .leading, spacing: 2) {
                  Text(h.entry.title).font(.system(size: 12.5, weight: .semibold))
                  Text(h.reason).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .card()
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
      .padding(.horizontal, 28)
      .padding(.vertical, 24)
      .frame(maxWidth: 980, alignment: .leading)
    }
    .onAppear { memo = bundle.memo ?? "" }
    .onChange(of: bundle.memo) { memo = bundle.memo ?? "" }
  }

  func header(_ members: [SourceSummary]) -> some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Text("묶음").font(.system(size: 11.5, weight: .bold)).foregroundStyle(Color.accentColor)
        Text(model.bundleTitle(bundle)).font(.system(size: 26, weight: .semibold, design: .serif)).textSelection(.enabled)
        Text(meta(members)).font(.system(size: 12.5)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Button("자료 더하기…") {
        model.intakeBundle = bundle.id
        model.showIntake = true
      }
      Menu("묶음") {
        let others = model.bundles.filter { $0.id != bundle.id && BundleStore.subject($0, library: model.library) == BundleStore.subject(bundle, library: model.library) }
        Menu("다른 묶음과 합치기") {
          ForEach(others.prefix(30)) { o in
            Button(model.bundleTitle(o)) { save { try model.mergeBundle(bundle.id, into: o.id) } }
          }
        }
        .disabled(others.isEmpty)
      }
      .fixedSize()
    }
  }

  // "Extended Mathematics · MYP 5 · Extended · 10월 19일에 넣음"
  func meta(_ members: [SourceSummary]) -> String {
    let labels = members.first?.labels.labels
    let date = Clock.parse(bundle.created).map { $0.formatted(.dateTime.month().day().locale(SourceRow.korean)) + "에 넣음" }
    return [labels?.subject, labels?.grade, labels?.level, date].compactMap { $0 }.joined(separator: " · ")
  }

  func save(_ action: () throws -> Void) {
    do {
      try action()
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

// 단계 한 칸: 이름, 막대, 상태
struct StageCell: View {
  let name: String
  let state: AppModel.StageState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Capsule().fill(color).frame(height: 4)
      Text(name).font(.system(size: 13, weight: .semibold))
      Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 11)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
  }

  var color: Color {
    switch state {
    case .done: Color.accentColor
    case .active: Color.accentColor.opacity(0.45)
    case .failed: Color.red.opacity(0.7)
    case .waiting, .none: Color.primary.opacity(0.15)
    }
  }

  var label: String {
    switch state {
    case .none: "앞 단계 다음"
    case .waiting(let s): s.isEmpty ? "남음" : s
    case .active(let s): "도는 중 · \(s)"
    case .done(let s): s.isEmpty ? "끝" : "끝 · \(s)"
    case .failed(let s): "실패 · \(s)"
    }
  }
}

// 묶음 안의 자료 한 줄: 읽기가 알아낸 제목과 종류, 쪽 수, 원본 파일 이름. 고르면 쪽이 열린다.
struct SourceInBundleRow: View {
  @Environment(AppModel.self) private var model
  let source: SourceSummary
  let bundle: SourceBundle

  var body: some View {
    let note = model.data.flatMap { SourceReading.material($0, source: source.id, read: model.readSources) }
    HStack(spacing: 10) {
      SourceThumb()
      VStack(alignment: .leading, spacing: 2) {
        Text(note?.title ?? SourceRow.title(source)).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
        Text([note?.kind, "\(source.meta.pages)쪽", source.meta.original.name].compactMap { $0 }.joined(separator: " · "))
          .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        ReadingBadge(source: source).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Menu {
        Button("새 묶음으로 옮기기") { move(nil) }
        let others = model.bundles.filter { $0.id != bundle.id && BundleStore.subject($0, library: model.library) == source.labels.labels.subjectID }
        Menu("다른 묶음으로 옮기기") {
          ForEach(others.prefix(30)) { o in Button(model.bundleTitle(o)) { move(o.id) } }
        }
        .disabled(others.isEmpty)
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("자료 메뉴")
    }
    .padding(8)
    .contentShape(Rectangle())
    .onTapGesture { model.selection = .source(source.id) }
    .rowHighlight(model.selection == .source(source.id))
    .card()
  }

  func move(_ target: String?) {
    try? model.moveSource(source.id, to: target)
  }
}
