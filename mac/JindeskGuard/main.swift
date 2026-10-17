// 외부 호출 검사 훅. claude 가 WebSearch/WebFetch 직전에 실행한다.
// 사용: jindesk-guard [<log.jsonl>]   (stdin 으로 훅 입력 JSON 을 받는다)
// 종료 코드 2 는 호출을 막고 stderr 를 에이전트에게 돌려준다.
import Foundation
import JindeskKit

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data(message.utf8))
  exit(2)
}

// 훅이 멈춰 작업 전체를 붙잡지 않도록 상한을 둔다. 상한을 넘으면 막는 쪽으로 끝낸다.
DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
  fail("외부 호출 검사가 10초 안에 끝나지 않아 막았다.")
}

let logFile = CommandLine.arguments.dropFirst().first

let input = FileHandle.standardInput.readDataToEndOfFile()
let outcome = GuardHook.run(logFile: logFile, input: input)
if let message = outcome.message { FileHandle.standardError.write(Data(message.utf8)) }
exit(outcome.exitCode)
