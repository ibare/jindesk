import Foundation
import Testing
@testable import JindeskKit

// 언어 습득 과목을 위한 갈래(DECISIONS.md 44)가 다른 과목에 새지 않는지 묶어 둔다.
// 언어 과목이 아니면 작업 요청과 판정자의 글이 그 전(021dab5)과 글자 그대로여야 한다. 일부러 바꾸면 여기의 기준 글도 함께 고친다.
@Suite struct SubjectNeutralTests {
  @Test func 언어_습득_표시가_없는_과목_이름은_언어_과목으로_보지_않는다() {
    let marked: Set = ["Language B", "Language Acquisition"]
    for name in LabelSuggestions.subjects where !marked.contains(name) {
      #expect(LanguageAcquisition.target(of: name) == nil, "\(name)")
    }
    for name in marked { #expect(LanguageAcquisition.target(of: name) == LanguageAcquisition.unnamed, "\(name)") }
    for name in ["Extended Mathematics", "Physics", "Science", "English", "extended-mathematics", "physics"] {
      #expect(LanguageAcquisition.target(of: name) == nil, "\(name)")
    }
  }

  @Test func 언어_과목이_아니면_판정자_글이_예전과_같다() {
    let level = "an IB student in MYP 5"
    let reader = ReaderTest.prompt([ReaderTest.Item(key: "u1", text: "Force equals mass times acceleration.")], level: level, subject: "Physics")
    #expect(
      reader == """
        너는 an IB student in MYP 5 이다. 과목은 Physics 다. 영어로 수업을 듣는다. 아래 글을 처음 읽는다. 수업 자료나 다른 글은 볼 수 없다.
        그 학년에서 이미 배운 것(앞 단원의 기초 용어와 계산)은 안다고 가정한다. 수식은 TeX 로 적혀 있다.

        단위(unit)마다 판정한다.
        - verdict: 이 글만 읽고 무엇을 말하는지 이해할 수 있으면 pass, 아니면 fail. 다음이 있으면 fail 이다:
          - 수업 자료를 봐야만 통하는 말 ("slide 3", "the diagram above", "as in the worksheet", "the teacher's example")
          - 정의하지 않은 기호나 그 학년에서 모를 용어를 설명 없이 쓴다
          - 앞뒤가 이어지지 않거나, 무엇을 가리키는지 알 수 없는 "this", "it"
        - unclear: 이해하지 못한 표현이나 기호를 모두. 없으면 빈 목록.
        - reason: 판정 이유 한 문장 (한국어).
        엄격하되, 그 학년 학생이 보통 아는 것까지 문제 삼지는 않는다.

        <unit key="u1">
        Force equals mass times acceleration.
        </unit>
        """)

    let goals = [OutcomeTest.Goal(key: "o1", text: "Can calculate the resultant force.")]
    let outcome = OutcomeTest.prompt(text: "# Newton's second law\n\nF = ma", goals: goals, level: level, subject: "Physics", others: ["Momentum"])
    #expect(
      outcome == """
        너는 an IB student in MYP 5 이다. 과목은 Physics 다. 영어로 수업을 듣는다. 아래 학습 글만 읽었다. 수업 자료나 다른 글은 볼 수 없다.
        그 학년에서 이미 배운 것(앞 단원의 기초 용어와 계산)은 안다고 가정한다. 수식은 TeX 로 적혀 있다.
        선생님이 이 수업의 학습 목표를 밝혀 두었다. 목표마다 판정한다.

        - applies: 이 글의 개념이 이 목표에 속하면 true. 다른 개념에 대한 목표면 false 이고, 그때 met 과 practiced 는 true 로 둔다.
          목표가 여러 개념을 묶어 말하면(여러 통계값을 나열하거나, 분류·계산·적용을 함께 말하는 목표), 이 글의 개념이 맡는 부분이 있을 때만 true 이고
          met 과 practiced 는 그 부분으로만 판정한다. 아래 "같은 과목의 다른 개념"이 맡는 부분은 이 글에 없어도 된다. 그것을 빠졌다고 하지 않는다.
        - met: 이 글만 읽고 그 목표를 해낼 수 있으면 true. 목표의 동사를 따른다. calculate 나 classify 는 글의 절차대로 따라 할 수 있는가.
          interpret, compare, make inferences, explain 은 결과가 무엇을 뜻하는지, 왜 그런지, 자료가 바뀌면 어떻게 되는지를 글에 근거해 말할 수 있는가.
          글이 계산만 보이고 그 뜻이나 까닭을 말하지 않으면 false 다.
        - practiced: 그 목표를 연습하는 확인 문제(Check)가 글에 있으면 true. 목표가 해석·비교·설명을 요구하는데 계산 문제만 있으면 false 다.
          글에 확인 문제가 하나도 없으면(개념 원문만 받은 경우) true 로 둔다.
        - missing: met 이나 practiced 가 false 면 무엇이 빠졌는지 한국어 한두 문장. 목표의 범위 안에서, 이 개념이 맡는 부분만 말한다.
          그 학년 수업을 넘는 내용이나, 다른 개념이 맡는 내용을 요구하지 않는다.

        학습 목표:
        - o1: Can calculate the resultant force.

        같은 과목의 다른 개념 (각자 자기 페이지가 있다):
        - Momentum

        <text>
        # Newton's second law

        F = ma
        </text>
        """)

    let verdicts = [OutcomeTest.Verdict(key: "o1", applies: true, met: false, practiced: false, missing: "합력이 없다.")]
    // 과목을 주지 않아도, 내용 과목을 주어도 문제 줄이 예전과 같다
    for subject in ["", "Physics"] {
      #expect(
        OutcomeTest.unmet(verdicts, goals: goals, subject: subject) == [
          "학습 목표 \"Can calculate the resultant force.\"에서 이 개념이 맡는 부분을 이 글만 읽고 해낼 수 없다: 합력이 없다. 자료의 수준 안에서 그 부분을 해낼 수 있게 설명한다(자료에 없는 설명은 보충으로). 새 개념이나 공식을 더하지 않고, 다른 개념이 맡는 내용은 다시 쓰지 않는다."
        ])
      #expect(
        OutcomeTest.unpracticed(verdicts, goals: goals, subject: subject) == [
          "학습 목표 \"Can calculate the resultant force.\"에서 이 개념이 맡는 부분을 연습하는 확인 문제가 없다: 합력이 없다. 그 부분을 묻는 확인 문제를 더한다(해석·비교·설명을 요구하면 계산만 시키지 않는다). 다른 개념이 맡는 내용은 묻지 않는다."
        ])
    }
  }

  @Test func 언어_과목이_아니면_자료_읽기_요청이_예전과_같다() {
    let t = TempPlace()
    let meta = SourceMeta(
      id: "20261020-aaaa0000", original: .init(name: "Forces.pdf", bytes: 1, sha256: "s"), received: "r", converted: nil, pages: 3,
      textLayer: .init(by: "pdfkit", pagesWithText: 3, ocrPages: []), buildUps: [])
    let lead = SourceSummary(
      folder: SourceFolder(id: meta.id, in: t.data), meta: meta,
      labels: SourceLabelsFile(source: meta.id, labels: SourceLabels(grade: "MYP 5", subject: "Physics", level: nil), memo: nil, syllabusBasis: false))
    let request = SourceReading.requestMarkdown(
      SourceBundle(id: "20261020-bbbb0000", created: "r", sources: [meta.id]), targets: [lead], earlier: [], earlierEntries: [])
    #expect(
      request == """
        # 자료 읽기 요청

        - 묶음 id: 20261020-bbbb0000
        - 꼬리표: 학년 MYP 5 · 과목 Physics

        ## 읽을 자료

        | 자료 id | 원본 파일 | 쪽 | 목차의 근거 | 메모 |
        |---|---|---|---|---|
        | 20261020-aaaa0000 | Forces.pdf | 3 | 아니오 |  |

        """)
  }
}
