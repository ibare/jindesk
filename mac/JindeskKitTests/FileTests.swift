import Foundation
import Testing
@testable import JindeskKit

@Suite struct FileOpsTests {
  @Test func 원자적으로_쓰면_임시_파일이_남지_않고_내용이_바뀐다() throws {
    let t = TempPlace()
    let file = t.data.url.appending(path: "meta/a.yaml")
    try FileOps.writeAtomic("하나\n", to: file)
    try FileOps.writeAtomic("둘\n", to: file)
    #expect(try FileOps.read(file) == "둘\n")
    #expect(FileOps.list(file.deletingLastPathComponent()) == ["a.yaml"])
  }

  @Test func 새_파일로만_쓰면_있는_파일을_덮어쓰지_않는다() throws {
    let t = TempPlace()
    let file = t.data.url.appending(path: "records/x.json")
    try FileOps.writeNew("1", to: file)
    #expect(throws: FileOps.AlreadyExists.self) { try FileOps.writeNew("2", to: file) }
    #expect(try FileOps.read(file) == "1")
  }

  @Test func JSONL_은_줄마다_덧붙인다() throws {
    let t = TempPlace()
    let file = t.data.learner.appending(path: "comments.jsonl")
    try FileOps.appendLine(#"{"v":1,"id":"a"}"#, to: file)
    try FileOps.appendLine(#"{"v":1,"id":"b"}"#, to: file)
    let read = try JSONLines.read(file)
    #expect(read.values.map { $0["id"]?.stringValue } == ["a", "b"])
    #expect(read.warning == nil)
  }

  @Test func 쓰다_꺼진_마지막_줄은_버리고_경고하며_가운데가_깨졌으면_오류다() throws {
    let tail = try JSONLines.parse("{\"id\":\"a\"}\n{\"id\":\"b\"}\n{\"id\":", name: "c.jsonl")
    #expect(tail.values.count == 2)
    #expect(tail.warning?.contains("마지막 줄") == true)
    #expect(throws: JSONLines.BrokenLine.self) { try JSONLines.parse("{\"id\":\"a\"}\n{깨짐\n{\"id\":\"b\"}\n", name: "c.jsonl") }
  }

  @Test func 큰_파일도_조각으로_해시한다() throws {
    let t = TempPlace()
    let file = t.root.appending(path: "big.bin")
    let data = Data(repeating: 7, count: 3 * 1024 * 1024 + 5)
    try FileOps.write(data, to: file)
    #expect(try Hash.file(file) == Hash.sha256(data))
    #expect(Hash.short(Data("a".utf8)) == "ca978112ca1bbdca")
  }
}

@Suite struct DataFolderTests {
  @Test func 없는_폴더와_빈_폴더와_Jindesk_폴더는_쓸_수_있다() throws {
    let t = TempPlace()
    #expect(t.data.issues().filter(\.isError).isEmpty)
    try FileOps.makeDirectory(t.data.url)
    try FileOps.write(Data(), to: t.data.url.appending(path: ".DS_Store"))
    #expect(t.data.issues().filter(\.isError).isEmpty)
    try t.data.initialize(app: testApp)
    try FileOps.write("내 파일", to: t.data.url.appending(path: "자료.txt"))
    #expect(t.data.issues().filter(\.isError).isEmpty)
  }

  @Test func 다른_파일이_든_폴더와_앱_번들_안과_파일은_쓸_수_없다() throws {
    let t = TempPlace()
    try t.write("문서.txt", "다른 파일")
    #expect(t.data.issues().contains { $0.isError && $0.message.contains("다른 파일") })
    #expect(DataFolder(t.root.appending(path: "Jindesk.app/Contents/Data")).issues().contains { $0.isError && $0.message.contains("앱 번들") })
    #expect(DataFolder(t.data.url.appending(path: "문서.txt")).issues().contains { $0.isError })
  }

  @Test func 처음_쓸_때_폴더와_meta_schema_yaml_을_만든다() throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp, now: Date(timeIntervalSince1970: 1_790_000_000))
    #expect(FileOps.list(t.data.url).sorted() == ["bundles", "learner", "library", "meta", "records", "sources", "syllabus"])
    let file = try SchemaFile.read(t.data)
    #expect(file.schema == CurrentSchema.version && file.lastOpenedBy == testApp && file.history.isEmpty)
    #expect(try t.read("meta/schema.yaml").hasPrefix("kind: \"schema\"\nv: 1\nschema: \(CurrentSchema.version)\n"))
    // 이미 있으면 바꾸지 않는다
    let before = try t.read("meta/schema.yaml")
    try t.data.initialize(app: AppVersion(app: "9", build: "9"))
    #expect(try t.read("meta/schema.yaml") == before)
  }

  @Test func 잠금은_한_곳만_잡고_프로세스_id_를_적는다() throws {
    let t = TempPlace()
    try t.data.initialize(app: testApp)
    let a = DataLock(t.data)
    let b = DataLock(t.data)
    #expect(a.tryAcquire())
    #expect(!b.tryAcquire())
    #expect(try t.read("meta/.lock") == "\(getpid())\n")
    a.release()
    #expect(b.tryAcquire())
    b.release()
  }
}
