// IB command terms 의 정의 (DECISIONS.md 34). IB 과목 가이드의 command terms 용어집을 옮긴 것이다. 맥과 폰, 학습 페이지가 함께 쓴다.
// 관점 붙이기가 고르는 명령어 목록(FacetVocabulary.commandTerms)과 같은 말을 모두 담는다. 한국어는 뜻을 잡는 짧은 풀이다.
import Foundation

public struct CommandTerm: Sendable, Equatable {
  public let term: String
  public let definition: String
  public let ko: String
}

public enum CommandTerms {
  public static let all: [CommandTerm] = [
    .init(term: "Analyse", definition: "Break down in order to bring out the essential elements or structure.", ko: "분석하라"),
    .init(term: "Annotate", definition: "Add brief notes to a diagram or graph.", ko: "주석을 달아라"),
    .init(term: "Apply", definition: "Use an idea, equation, principle, theory or law in relation to a given problem or issue.", ko: "적용하라"),
    .init(term: "Calculate", definition: "Obtain a numerical answer showing the relevant stages in the working.", ko: "계산하라 (과정을 보인다)"),
    .init(term: "Classify", definition: "Arrange or order by class or category.", ko: "분류하라"),
    .init(term: "Comment", definition: "Give a judgment based on a given statement or result of a calculation.", ko: "논평하라"),
    .init(
      term: "Compare", definition: "Give an account of the similarities between two (or more) items or situations, referring to both (all) of them throughout.",
      ko: "비교하라 (비슷한 점)"),
    .init(
      term: "Compare and contrast",
      definition: "Give an account of similarities and differences between two (or more) items or situations, referring to both (all) of them throughout.",
      ko: "비교하고 대조하라 (같은 점과 다른 점)"),
    .init(term: "Construct", definition: "Display information in a diagrammatic or logical form.", ko: "구성하라"),
    .init(
      term: "Contrast", definition: "Give an account of the differences between two (or more) items or situations, referring to both (all) of them throughout.",
      ko: "대조하라 (다른 점)"),
    .init(term: "Deduce", definition: "Reach a conclusion from the information given.", ko: "추론하라"),
    .init(term: "Define", definition: "Give the precise meaning of a word, phrase, concept or physical quantity.", ko: "정의하라"),
    .init(term: "Demonstrate", definition: "Make clear by reasoning or evidence, illustrating with examples or practical application.", ko: "보여라 (예나 근거로)"),
    .init(term: "Derive", definition: "Manipulate a mathematical relationship to give a new equation or relationship.", ko: "유도하라"),
    .init(term: "Describe", definition: "Give a detailed account.", ko: "서술하라"),
    .init(term: "Design", definition: "Produce a plan, simulation or model.", ko: "설계하라"),
    .init(term: "Determine", definition: "Obtain the only possible answer.", ko: "구하라 (답이 하나)"),
    .init(
      term: "Discuss",
      definition:
        "Offer a considered and balanced review that includes a range of arguments, factors or hypotheses. Opinions or conclusions should be presented clearly and supported by appropriate evidence.",
      ko: "논의하라"),
    .init(term: "Distinguish", definition: "Make clear the differences between two or more concepts or items.", ko: "구별하라"),
    .init(
      term: "Draw",
      definition:
        "Represent by means of a labelled, accurate diagram or graph, using a pencil. A ruler (straight edge) should be used for straight lines. Diagrams should be drawn to scale. Graphs should have points correctly plotted (if appropriate) and joined in a straight line or smooth curve.",
      ko: "그려라 (정확하게)"),
    .init(term: "Estimate", definition: "Obtain an approximate value.", ko: "어림하라"),
    .init(term: "Evaluate", definition: "Make an appraisal by weighing up the strengths and limitations.", ko: "평가하라"),
    .init(
      term: "Examine", definition: "Consider an argument or concept in a way that uncovers the assumptions and interrelationships of the issue.", ko: "검토하라"),
    .init(term: "Explain", definition: "Give a detailed account including reasons or causes.", ko: "설명하라 (까닭까지)"),
    .init(term: "Explore", definition: "Undertake a systematic process of discovery.", ko: "탐구하라"),
    .init(term: "Formulate", definition: "Express precisely and systematically the relevant concept(s) or argument(s).", ko: "정식화하라"),
    .init(term: "Hence", definition: "Use the preceding work to obtain the required result.", ko: "그러므로 (앞의 결과를 써서)"),
    .init(
      term: "Hence or otherwise", definition: "It is suggested that the preceding work is used, but other methods could also receive credit.",
      ko: "앞의 결과를 쓰거나 다른 방법으로"),
    .init(term: "Identify", definition: "Provide an answer from a number of possibilities.", ko: "찾아내라"),
    .init(term: "Integrate", definition: "Obtain the integral of a function.", ko: "적분하라"),
    .init(
      term: "Interpret", definition: "Use knowledge and understanding to recognize trends and draw conclusions from given information.", ko: "해석하라"),
    .init(
      term: "Investigate", definition: "Observe, study, or make a detailed and systematic examination, in order to establish facts and reach new conclusions.",
      ko: "조사하라"),
    .init(term: "Justify", definition: "Give valid reasons or evidence to support an answer or conclusion.", ko: "근거를 대라"),
    .init(term: "Label", definition: "Add labels to a diagram.", ko: "이름을 달아라"),
    .init(term: "List", definition: "Give a sequence of brief answers with no explanation.", ko: "나열하라"),
    .init(term: "Measure", definition: "Obtain a value for a quantity.", ko: "재라"),
    .init(term: "Outline", definition: "Give a brief account or summary.", ko: "개요를 말하라"),
    .init(term: "Plot", definition: "Mark the position of points on a diagram.", ko: "점을 찍어라"),
    .init(term: "Predict", definition: "Give an expected result.", ko: "예측하라"),
    .init(term: "Prove", definition: "Use a sequence of logical steps to obtain the required result in a formal way.", ko: "증명하라"),
    .init(term: "Show", definition: "Give the steps in a calculation or derivation.", ko: "과정을 보여라"),
    .init(
      term: "Show that",
      definition:
        "Obtain the required result (possibly using information given) without the formality of proof. \"Show that\" questions do not generally require the use of a calculator.",
      ko: "~임을 보여라"),
    .init(
      term: "Sketch",
      definition:
        "Represent by means of a diagram or graph (labelled as appropriate). The sketch should give a general idea of the required shape or relationship, and should include relevant features.",
      ko: "개형을 그려라"),
    .init(term: "Solve", definition: "Obtain the answer(s) using algebraic and/or numerical and/or graphical methods.", ko: "풀어라"),
    .init(term: "State", definition: "Give a specific name, value or other brief answer without explanation or calculation.", ko: "말하라 (설명 없이)"),
    .init(term: "Suggest", definition: "Propose a solution, hypothesis or other possible answer.", ko: "제안하라"),
    .init(term: "Summarize", definition: "Abstract a general theme or major point(s).", ko: "요약하라"),
    .init(
      term: "To what extent",
      definition:
        "Consider the merits or otherwise of an argument or concept. Opinions and conclusions should be presented clearly and supported with appropriate evidence and sound argument.",
      ko: "어느 정도까지인가"),
    .init(term: "Verify", definition: "Provide evidence that validates the result.", ko: "확인하라"),
    .init(
      term: "Write down", definition: "Obtain the answer(s), usually by extracting information. Little or no calculation is required. Working does not need to be shown.",
      ko: "써라 (계산 거의 없이)"),
  ]

  static let byKey = Dictionary(all.map { ($0.term.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })

  public static func lookup(_ term: String) -> CommandTerm? { byKey[term.lowercased()] }
}
