import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import JindeskKit

// 시험용 자료를 만든다. 실제 학교 자료는 쓰지 않는다.
enum SampleFiles {
  enum Page {
    // PDF 글자층이 있는 쪽
    case text(String)
    // 글자를 그림으로만 넣은 쪽 (글자층이 없다)
    case picture(String)
  }

  static func pdf(_ url: URL, _ pages: [Page]) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 720, height: 405)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    for page in pages {
      ctx.beginPDFPage(nil)
      switch page {
      case .text(let s):
        draw(s, in: ctx, rect: box.insetBy(dx: 30, dy: 30), size: 22)
      case .picture(let s):
        ctx.draw(picture(s, width: 1440, height: 810), in: box)
      }
      ctx.endPDFPage()
    }
    ctx.closePDF()
  }

  static func png(_ url: URL, _ text: String) throws {
    try write(picture(text, width: 1200, height: 800), to: url, type: .png)
  }

  static func heic(_ url: URL, _ text: String) throws {
    try write(picture(text, width: 1200, height: 800), to: url, type: .heic)
  }

  static func picture(_ text: String, width: Int, height: Int) -> CGImage {
    let ctx = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(text, in: ctx, rect: CGRect(x: 60, y: 60, width: width - 120, height: height - 120), size: 56)
    return ctx.makeImage()!
  }

  static func draw(_ text: String, in ctx: CGContext, rect: CGRect, size: CGFloat) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attributed = NSAttributedString(
      string: text, attributes: [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
    let setter = CTFramesetterCreateWithAttributedString(attributed)
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, ctx)
  }

  static func write(_ image: CGImage, to url: URL, type: UTType) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw ToolError("이미지를 쓰지 못했습니다") }
  }

  static let doNow = "Do Now: Solve each equation. Two to the power x equals sixty four. Five to the power x equals one hundred twenty five."
}

@Suite struct LabelTests {
  @Test func 적은_값을_이미_있는_값에_맞추고_공백을_정리한다() {
    let used = ["Extended Math", "DP1"]
    #expect(LabelMatch.canonical("extended  math", among: used) == "Extended Math")
    #expect(LabelMatch.canonical("  Physics   HL ", among: used) == "Physics HL")
    let labels = LabelMatch.canonical(SourceLabels(grade: "dp1", subject: "EXTENDED MATH", level: " Extended ")) { name in
      name == SourceLabels.level ? [] : used
    }
    #expect(labels == SourceLabels(grade: "DP1", subject: "Extended Math", level: "Extended"))
  }

  @Test func 과목_id_는_과목_꼬리표에서_만들고_수준을_넣지_않는다() {
    #expect(SubjectID.make("Physics") == "physics")
    #expect(SubjectID.make("Mathematics: Analysis and Approaches") == "mathematics-analysis-and-approaches")
    #expect(SubjectID.make("Extended Math") == "extended-math")
    // 영어가 아닌 이름은 해시로 만들고, 대소문자·공백만 다르면 같은 id 다
    let korean = SubjectID.make("한국어 문학")
    #expect(korean.hasPrefix("subject-") && korean.count == 16)
    #expect(SubjectID.make(" 한국어  문학") == korean)
    #expect(SourceLabels(grade: "DP1", subject: "Physics", level: "HL").subjectID == "physics")
  }

  @Test func 빈_값은_넣지_않고_제안은_이전_값_뒤에_준비한_값을_잇는다() {
    var labels = SourceLabels(grade: "DP1", subject: "  ", level: nil)
    #expect(labels.entries.map(\.name) == ["grade"])
    labels["unit"] = "Logarithm"
    #expect(labels.summary == "DP1 · Logarithm")
    let merged = LabelSuggestions.merged(used: ["Extended", "hl"], name: SourceLabels.level)
    #expect(merged == ["Extended", "hl", "SL", "Standard"])
  }

  @Test func 쪽을_조금씩_채워_가는_묶음을_찾는다() {
    let base = "Do Now: Solve each equation and show the steps clearly"
    let texts = [
      "Unit 6: Statistics", base, base + " Step one", base + " Step one Step two", "Today: Something else entirely different here ok",
      "Today: Something else entirely different here ok", "short", "short more",
    ]
    #expect(BuildUps.runs(texts) == [[2, 3, 4], [5, 6]])
    // 제목만 같고 내용이 다른 쪽은 묶지 않는다
    #expect(BuildUps.runs([base + " first problem here", base + " second problem here"]).isEmpty)
    // 빈칸에 답이 채워지는 쪽: 더한 낱말이 가운데에 끼어든다
    let blank = "Today: Exponent laws Product rule: x5 × x4 = Rule 1:"
    let filled = "Today: Exponent laws Product rule: x5 × x4 = x9 Criteria B: patterns Rule 1: an × am = an+m"
    #expect(BuildUps.runs([blank, filled]) == [[1, 2]])
  }
}

@MainActor
@Suite struct SourceIntakeTests {
  func place() throws -> TempPlace {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    return t
  }

  func intake(_ t: TempPlace, _ request: IntakeRequest) async throws -> JobSnapshot {
    let m = JobManager(data: t.data, folders: t.folders)
    let id = try await m.submit(config: testConfig) { try SourceIntake.prepare(request, $0) }
    return await m.waitForEnd(id)
  }

  @Test func PDF_를_넣으면_자료_폴더와_쪽_이미지가_생긴다() async throws {
    let t = try place()
    let pdf = t.root.appending(path: "inbox/1._Intro_to_logs.pdf")
    SampleFiles.pdf(
      pdf,
      [
        .text(SampleFiles.doNow), .text(SampleFiles.doNow + " Answer: x equals six."), .text("Today: Intro to logarithms. Example 1: rearrange ten to the x equals fifty."),
        .picture("Worksheet 2 Venn Diagrams"),
      ])
    let end = try await intake(t, IntakeRequest(files: [pdf], labels: SourceLabels(grade: "MYP 5", subject: "Extended Math", level: "Extended"), memo: "오늘 수업"))
    #expect(end.phase == "done")
    #expect(end.counts?.map(\.count) == [1, 0])

    let library = SourceLibrary.load(t.data)
    let source = try #require(library.sources.first)
    #expect(SourceID.isValid(source.id))
    #expect(source.meta.pages == 4)
    #expect(source.meta.original.name == "1._Intro_to_logs.pdf" && source.meta.original.sha256.count == 16)
    #expect(source.meta.converted == nil)
    #expect(source.meta.buildUps == [[1, 2]])
    // 글자층이 없는 4쪽은 Vision 으로 읽는다
    #expect(source.meta.textLayer.ocrPages.contains(4))
    #expect(try FileOps.read(source.folder.pageText(4)).lowercased().contains("venn"))
    #expect(try FileOps.read(source.folder.pageText(1)).contains("Do Now"))
    #expect(source.labels.labels.summary == "MYP 5 · Extended Math · Extended")
    // 메모는 묶음에 붙는다 (DECISIONS.md 35)
    #expect(source.labels.memo == nil)
    let bundle = try #require(BundleStore.bundle(of: source.id, in: t.data))
    #expect(bundle.memo == "오늘 수업" && bundle.sources == [source.id] && bundle.title == nil && !bundle.implicit)
    #expect(try t.read("bundles/\(bundle.id).yaml").hasSuffix("sources: [\"\(source.id)\"]\nmemo: \"오늘 수업\"\ntitle: null\n"))
    // 파일 모양
    #expect(FileOps.list(source.folder.url).sorted() == ["index.md", "labels.yaml", "meta.yaml", "original.pdf", "pages"])
    #expect(
      try t.read("sources/\(source.id)/labels.yaml")
        == "kind: \"labels\"\nv: 1\nsource: \"\(source.id)\"\nlabels: { grade: \"MYP 5\", subject: \"Extended Math\", level: \"Extended\" }\nmemo: null\nsyllabus_basis: false\n")
    let index = try t.read("sources/\(source.id)/index.md")
    #expect(index.contains("| 1 |") && index.contains("2쪽으로 이어짐") && index.contains("마지막 모습"))
    // 쪽 이미지는 캐시에 둔다 (긴 변 1600px)
    let images = FileOps.list(t.folders.pageImages(source.id)).sorted()
    #expect(images == ["0001.png", "0002.png", "0003.png", "0004.png", "view"])
    // 맥과 폰이 보는 쪽 이미지 (HEIC, 긴 변 2000)
    #expect(FileOps.list(t.folders.viewImages(source.id)).sorted() == ["0001.heic", "0002.heic", "0003.heic", "0004.heic"])
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(t.folders.pageImages(source.id).appending(path: "0001.png") as CFURL, nil)!, 0, nil)!
    #expect(image.width == 1600 && image.height == 900)
    #expect(FileOps.list(t.data.sources).filter { $0.hasPrefix(".") }.isEmpty)
    // 과목은 꼬리표에서 모은다
    #expect(library.subjects.map(\.id) == ["extended-math"])
  }

  @Test func 같은_파일은_다시_넣지_않고_까닭을_보인다() async throws {
    let t = try place()
    let a = t.root.appending(path: "inbox/a.pdf")
    SampleFiles.pdf(a, [.text("Lesson notes about vectors and their magnitudes.")])
    let copy = t.root.appending(path: "inbox/a (1).pdf")
    try FileManager.default.copyItem(at: a, to: copy)
    let notes = t.root.appending(path: "inbox/notes.txt")
    try FileOps.write("텍스트", to: notes)

    let plan = SourceIntake.plan([a, copy, notes], library: SourceLibrary.load(t.data))
    #expect(plan.map(\.status) == [.new, .sameAs("a.pdf"), .unsupported("txt")])
    #expect(SourceIntake.plan([a], library: SourceLibrary.load(t.data), sizeLimit: 10).first?.status == .tooLarge(plan[0].bytes))

    let first = try await intake(t, IntakeRequest(files: [a, copy], labels: SourceLabels(grade: "DP1", subject: "Physics", level: "HL")))
    #expect(first.phase == "done" && first.counts?.map(\.count) == [1, 1])
    #expect(first.warnings?.first?.contains("a.pdf 와 내용이 같습니다") == true)
    let second = try await intake(t, IntakeRequest(files: [copy], labels: SourceLabels(grade: "DP1", subject: "physics", level: "HL")))
    #expect(second.counts?.map(\.count) == [0, 1])
    #expect(second.warnings?.first?.contains("이미 넣은 자료입니다") == true)
    #expect(SourceLibrary.load(t.data).sources.count == 1)
  }

  @Test func 사진과_HEIC_도_한_쪽_자료로_넣는다() async throws {
    let t = try place()
    let png = t.root.appending(path: "inbox/board.png")
    try SampleFiles.png(png, "Mean equals sum over n")
    let heic = t.root.appending(path: "inbox/board.heic")
    try SampleFiles.heic(heic, "Standard deviation")
    let end = try await intake(t, IntakeRequest(files: [png, heic], labels: SourceLabels(grade: "MYP 5", subject: "extended math", level: nil)))
    #expect(end.phase == "done" && end.counts?.first?.count == 2)
    let library = SourceLibrary.load(t.data)
    let byName = Dictionary(uniqueKeysWithValues: library.sources.map { ($0.meta.original.name, $0) })
    let photo = try #require(byName["board.png"])
    #expect(photo.meta.pages == 1 && photo.meta.textLayer.ocrPages == [1])
    #expect(try FileOps.read(photo.folder.pageText(1)).lowercased().contains("mean"))
    let converted = try #require(byName["board.heic"])
    #expect(converted.meta.converted == SourceMeta.Conversion(to: "source.jpg", by: "imageio", appVersion: nil))
    #expect(FileOps.exists(converted.folder.url.appending(path: "source.jpg")))
    #expect(converted.folder.renderable?.lastPathComponent == "source.jpg")
  }

  @Test func 이전에_쓴_꼬리표를_최근_것부터_모으고_과목마다_묶는다() async throws {
    let t = try place()
    let a = t.root.appending(path: "inbox/a.pdf")
    let b = t.root.appending(path: "inbox/b.pdf")
    let c = t.root.appending(path: "inbox/c.pdf")
    SampleFiles.pdf(a, [.text("First lesson about kinematics and projectiles.")])
    SampleFiles.pdf(b, [.text("Second lesson about probability and Venn diagrams.")])
    SampleFiles.pdf(c, [.text("Third lesson without any labels at all here.")])
    _ = try await intake(t, IntakeRequest(files: [a], labels: SourceLabels(grade: "DP1", subject: "Physics", level: "HL")))
    try await Task.sleep(for: .milliseconds(1100))
    _ = try await intake(t, IntakeRequest(files: [b], labels: SourceLabels(grade: "MYP 5", subject: "Extended Math", level: "Extended")))
    try await Task.sleep(for: .milliseconds(1100))
    _ = try await intake(t, IntakeRequest(files: [c], labels: SourceLabels()))
    let library = SourceLibrary.load(t.data)
    #expect(library.usedValues(SourceLabels.subject) == ["Extended Math", "Physics"])
    #expect(library.usedValues(SourceLabels.grade) == ["MYP 5", "DP1"])
    #expect(library.lastLabels.entries.isEmpty)
    #expect(library.subjects.map(\.id) == ["extended-math", "physics"])
    #expect(library.unlabeled.map(\.meta.original.name) == ["c.pdf"])
  }

  @Test func 넣다가_꺼져_남은_폴더를_지운다() throws {
    let t = try place()
    try FileOps.write("x", to: t.data.sources.appending(path: ".incoming-20261017-abcdef12/original.pdf"))
    #expect(SourceIntake.removeLeftovers(t.data) == [".incoming-20261017-abcdef12"])
    #expect(FileOps.list(t.data.sources).isEmpty)
  }
}
