import Foundation
import Testing
@testable import JindeskKit

private let terms = ["김민준", "민준", "Seoul Intl School"]

private func check(_ tool: String, _ input: [String: String]) -> String? {
  ExternalCallCheck.blockReason(tool: tool, input: .object(input.mapValues(JSONValue.string)), terms: terms)
}

@Suite struct ExternalCallCheckTests {
  @Test func 일반_학습_용어_검색은_통과시킨다() {
    #expect(check("WebSearch", ["query": "projectile motion complementary angles same range"]) == nil)
  }

  @Test func 검색어에_금지어가_있으면_대소문자와_관계없이_막는다() {
    #expect(check("WebSearch", ["query": "seoul intl school physics syllabus"])?.contains("Seoul Intl School") == true)
    #expect(check("WebSearch", ["query": "김민준 학생 물리"])?.contains("김민준") == true)
    // 두 글자 이름도 막는다
    #expect(check("WebSearch", ["query": "민준 IB 수학"]) != nil)
  }

  @Test func 조회_주소에_퍼센트_인코딩된_금지어가_있어도_막는다() {
    #expect(check("WebFetch", ["url": "https://example.com/search?q=%EA%B9%80%EB%AF%BC%EC%A4%80"]) != nil)
  }

  @Test(arguments: [
    "http://127.0.0.1:4477/api", "http://localhost:3000", "http://10.0.0.5/", "http://192.168.1.2", "http://172.20.0.1",
    "http://169.254.169.254/latest", "http://[::1]:8080", "http://intranet.internal", "file:///etc/passwd", "http://2130706433/",
    "http://0x7f.1/", "http://[::ffff:127.0.0.1]/", "http://printer.local/", "http://[fe80::1%25en0]/", "http://100.100.100.100/",
  ])
  func 로컬_사설망_주소와_http가_아닌_주소는_막는다(url: String) {
    #expect(check("WebFetch", ["url": url]) != nil)
  }

  @Test func 공개_주소_조회는_통과시킨다() {
    #expect(check("WebFetch", ["url": "https://www.ibo.org/programmes/diploma-programme/"]) == nil)
    #expect(check("WebFetch", ["url": "https://8.8.8.8/"]) == nil)
    #expect(check("WebFetch", ["url": "https://[2606:4700:4700::1111]/"]) == nil)
  }

  @Test func 외부로_나가지_않는_도구는_검사하지_않는다() {
    #expect(check("Read", ["file_path": "/x/김민준"]) == nil)
  }
}

@Suite struct GuardHookTests {
  let dir = NSTemporaryDirectory() + "jindesk-guard-\(UUID().uuidString)"

  @Test func 막은_호출은_종료_코드_2와_이유를_돌려주고_기록에_남긴다() throws {
    let guardFiles = try ExternalGuard.prepare(directory: dir, terms: ["김민준", "김", " 김민준 "])
    let saved = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: guardFiles.termsFile)))
    #expect(saved == .array([.string("김민준")]))

    let blocked = GuardHook.run(
      termsFile: guardFiles.termsFile, logFile: guardFiles.logFile, input: Data(#"{"tool_name":"WebSearch","tool_input":{"query":"김민준 물리"}}"#.utf8))
    #expect(blocked.exitCode == 2)
    #expect(blocked.message?.contains("김민준") == true)

    let allowed = GuardHook.run(
      termsFile: guardFiles.termsFile, logFile: guardFiles.logFile,
      input: Data(#"{"tool_name":"WebFetch","tool_input":{"url":"https://example.com/a/b"}}"#.utf8))
    #expect(allowed == GuardHook.Outcome(exitCode: 0, message: nil))

    let lines = try JSONLines.read(URL(fileURLWithPath: guardFiles.logFile)).values
    #expect(lines.count == 2)
    #expect(lines[0]["tool"] == .string("WebSearch"))
    #expect(lines[0]["blocked"]?.stringValue?.contains("김민준") == true)
    #expect(lines[1]["blocked"] == .null)
    #expect(lines[1]["input"]?["url"] == .string("https://example.com/a/b"))
  }

  @Test func 금지어_파일을_읽지_못하면_막는다() {
    let outcome = GuardHook.run(termsFile: dir + "/없음.json", logFile: nil, input: Data("{}".utf8))
    #expect(outcome.exitCode == 2)
  }

  @Test func 훅_명령의_경로를_셸_따옴표로_감싸고_훅이_뜨지_못해도_막는다() {
    let g = ExternalGuard(termsFile: "/a b/terms.json", logFile: "/it's/log.jsonl")
    let hook = g.hooks(helperPath: "/Applications/Jindesk.app/Contents/MacOS/jindesk-guard")["PreToolUse"]?.arrayValue?.first?["hooks"]?.arrayValue?.first
    #expect(hook?["command"]?.stringValue == #"'/Applications/Jindesk.app/Contents/MacOS/jindesk-guard' '/a b/terms.json' '/it'\''s/log.jsonl'"#)
    #expect(hook?["onFailure"] == .string("block"))
  }

  @Test func 에이전트_설정은_out_과_work_에만_쓰고_웹은_검사_훅이_있을_때만_연다() {
    let plain = JSONText.stringify(AgentRunner.settings(nil, helper: "/h"))
    #expect(plain == #"{"permissions":{"allow":["Read","Grep","Glob","Write(./out/**)","Edit(./out/**)","Write(./work/**)","Edit(./work/**)"]}}"#)
    let web = AgentRunner.settings(ExternalGuard(termsFile: "/t", logFile: "/l"), helper: "/h")
    #expect(web["permissions"]?["allow"]?.strings.contains("WebFetch") == true)
    #expect(web["hooks"]?["PreToolUse"] != nil)
  }
}

@Suite struct ClaudeVersionTests {
  @Test func 버전을_읽고_견준다() {
    #expect(ClaudeVersion.parse("2.1.301 (Claude Code)") == [2, 1, 301])
    #expect(ClaudeVersion.parse("2.1.301\n") == [2, 1, 301])
    #expect(ClaudeVersion.parse("이상한 출력") == nil)
    #expect(ClaudeVersion.atLeast([2, 1, 296], [2, 1, 295]))
    #expect(ClaudeVersion.atLeast([2, 1, 295], [2, 1, 295]))
    #expect(!ClaudeVersion.atLeast([2, 1, 294], [2, 1, 295]))
    #expect(ClaudeVersion.atLeast([3, 0], [2, 1, 295]))
  }
}

@Suite struct InstructionsTests {
  @Test func 빌드_기록의_커밋과_미커밋_변경_여부를_쓰고_지침_버전을_읽는다() throws {
    let t = TempPlace()
    let jobs = t.root.appending(path: "jobs")
    try FileOps.write("# 자료 읽기\n\n지침 버전: `0.2`\n", to: jobs.appending(path: "source-reading/INSTRUCTIONS.md"))
    try FileOps.write("# 번역\n\n지침 버전: `0.1`\n", to: jobs.appending(path: "translation/INSTRUCTIONS.md"))
    try FileOps.write(#"{"source-reading":{"commit":"abc","dirty":false}}"#, to: jobs.appending(path: "build.json"))
    let source = InstructionSource(jobs)
    #expect(source.missing([.sourceReading, .translation, .pageBuild]) == [.pageBuild])
    #expect(
      try Instructions.read(source, kind: .sourceReading)
        == Instructions(text: "# 자료 읽기\n\n지침 버전: `0.2`\n", version: "0.2", commit: "abc", dirty: false))
    let translation = try Instructions.read(source, kind: .translation)
    #expect(translation.commit == "uncommitted" && translation.dirty)
    #expect(YAML.stringify(translation.provenance(.translation)) == "kind: \"translation\"\nversion: \"0.1\"\ncommit: \"uncommitted\"\ndirty: true\n")
    try FileOps.write("버전 없음\n", to: jobs.appending(path: "page-build/INSTRUCTIONS.md"))
    #expect(throws: ToolError.self) { try Instructions.read(source, kind: .pageBuild) }
  }

  @Test func 이_리포의_지침은_있어야_할_것이_모두_있다() {
    #expect(repoInstructions.missing().isEmpty)
  }
}
