import Foundation
import Testing
@testable import JindeskKit

// 실제 자료 버킷(개발용)으로 해 보는 시험. 환경 변수가 있을 때만 돈다 (SETUP.md 의 자료 버킷).
//   JINDESK_GCS_LIVE_BUCKET, JINDESK_GCS_LIVE_MAC_ID / _MAC_SECRET (쓰기용), JINDESK_GCS_LIVE_PHONE_ID / _PHONE_SECRET (읽기 전용)
// xcodebuild 로 돌릴 때는 이름 앞에 TEST_RUNNER_ 를 붙여 넘긴다. 올린 시험 객체는 test/ 와 지어낸 자료 id 아래에 남으므로 끝나고 지운다.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["JINDESK_GCS_LIVE_BUCKET"] != nil))
struct FileBucketLiveTests {
  let env = ProcessInfo.processInfo.environment
  var bucket: String { env["JINDESK_GCS_LIVE_BUCKET"] ?? "" }
  var mac: GCSClient { GCSClient(bucket: bucket, key: BucketKey(accessID: env["JINDESK_GCS_LIVE_MAC_ID"] ?? "", secret: env["JINDESK_GCS_LIVE_MAC_SECRET"] ?? "")) }
  var phone: GCSClient { GCSClient(bucket: bucket, key: BucketKey(accessID: env["JINDESK_GCS_LIVE_PHONE_ID"] ?? "", secret: env["JINDESK_GCS_LIVE_PHONE_SECRET"] ?? "")) }

  @Test func 맥_키로_올리고_묻고_받으며_폰_키는_읽기만_된다() async throws {
    let object = "test/live-\(UUID().uuidString.lowercased()).txt"
    let body = Data("자료 버킷 시험 \(Date())".utf8)
    try await mac.check()
    #expect(try await mac.exists(object) == false)
    try await mac.put(object, data: body, contentType: "text/plain; charset=utf-8")
    #expect(try await mac.exists(object))
    #expect(try await mac.get(object) == body)
    // 폰 키: 읽기는 되고 쓰기는 막힌다
    #expect(try await phone.get(object) == body)
    let denied = await #expect(throws: BucketError.self) { try await phone.put("test/phone-\(UUID().uuidString).txt", data: body, contentType: "text/plain") }
    #expect(denied?.status == 403)
  }

  @Test func 자료를_올리고_새_맥에서_원본과_쪽을_받는다() async throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let pdf = t.root.appending(path: "inbox/Live check.pdf")
    SampleFiles.pdf(pdf, [.text("Fabricated live check page one for the files bucket."), .text("Fabricated live check page two.")])
    let m = JobManager(data: t.data, folders: t.folders)
    let id = try await m.submit(config: testConfig) {
      try SourceIntake.prepare(IntakeRequest(files: [pdf], labels: SourceLabels(grade: "DP1", subject: "Physics", level: "HL"), memo: nil), $0)
    }
    #expect(await m.waitForEnd(id).phase == "done")
    let source = try #require(SourceLibrary.load(t.data).sources.first)

    let out = await SourceFiles.sync(SourceLibrary.load(t.data), folders: t.folders, client: mac)
    #expect(out.error == nil)
    #expect(out.uploaded == 3)
    // 폰이 받는 쪽 이미지
    let page = try await phone.get(BucketObject.page(source.id, 2))
    #expect(page == (try Data(contentsOf: SourcePages.viewImage(source.folder, page: 2, folders: t.folders))))
    // 새 맥: 원본이 없고 캐시도 비었다
    let original = try Data(contentsOf: source.folder.url.appending(path: "original.pdf"))
    FileOps.remove(source.folder.url.appending(path: "original.pdf"))
    let fresh = AppFolders(support: t.root.appending(path: "support2"), cache: t.root.appending(path: "cache2"))
    let restored = await SourceFiles.sync(SourceLibrary.load(t.data), folders: fresh, client: mac)
    #expect(restored.error == nil)
    #expect(restored.downloaded == 1)
    #expect(try Data(contentsOf: source.folder.url.appending(path: "original.pdf")) == original)
    print("올린 시험 자료: sources/\(source.id)/")
  }
}
