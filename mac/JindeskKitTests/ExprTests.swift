import Foundation
import Testing
@testable import JindeskKit

@Suite struct ExprTests {
  @Test func 식을_읽고_계산한다() throws {
    #expect(try Expr.parse("2^3^2").value([:]) == 512)
    #expect(try Expr.parse("-2^2").value([:]) == -4)
    #expect(try Expr.parse("log(1000)").value([:]) == 3)
    #expect(abs(try Expr.parse("log(17, 2)").value([:]) - 4.08746) < 1e-4)
    #expect(try Expr.parse("(x+h)^2 - x^2").value(["x": 2, "h": 1]) == 5)
    #expect(try Expr.parse("sqrt(-1)").value([:]).isNaN)
    #expect(throws: Expr.ParseError.self) { try Expr.parse("2x") }
    #expect(throws: Expr.ParseError.self) { try Expr.parse("log(") }
    #expect(try Expr.parse("2*pi").variables == ["pi"])
  }

  @Test func 이웃_단계가_같은_값인지_표본_값으로_본다() {
    let ok = DerivationCheck.problems(
      steps: [.init(expr: "(x+h)^2 - x^2", approx: false), .init(expr: "2*x*h + h^2", approx: false), .init(expr: nil, approx: false)],
      vars: ["x": -3...3, "h": 0.1...1], equation: nil, solution: [:], field: "b")
    #expect(ok.isEmpty)
    let wrong = DerivationCheck.problems(
      steps: [.init(expr: "(x+h)^2 - x^2", approx: false), .init(expr: "2*x*h", approx: false)], vars: ["x": -3...3, "h": 0.1...1], equation: nil,
      solution: [:], field: "b")
    #expect(wrong.count == 1)
    // 반올림한 단계는 적힌 자리 수 안에서 같으면 된다
    #expect(DerivationCheck.problems(steps: [.init(expr: "log(17)/log(2)", approx: false), .init(expr: "4.09", approx: true)], vars: [:], equation: nil, solution: [:], field: "b").isEmpty)
    #expect(DerivationCheck.problems(steps: [.init(expr: "log(17)/log(2)", approx: false), .init(expr: "4.1", approx: true)], vars: [:], equation: nil, solution: [:], field: "b").isEmpty)
    #expect(DerivationCheck.problems(steps: [.init(expr: "log(17)/log(2)", approx: false), .init(expr: "4.2", approx: true)], vars: [:], equation: nil, solution: [:], field: "b").count == 1)
  }

  @Test func 답을_넣어_등식이_성립하는지_본다() {
    #expect(DerivationCheck.problems(steps: [], vars: [:], equation: "2^x = 17", solution: ["x": "log(17, 2)"], field: "b").isEmpty)
    #expect(DerivationCheck.problems(steps: [], vars: [:], equation: "2^x = 17", solution: ["x": "4.09"], field: "b").isEmpty)
    #expect(DerivationCheck.problems(steps: [], vars: [:], equation: "2^x = 17", solution: ["x": "4"], field: "b").count == 1)
    #expect(DerivationCheck.problems(steps: [], vars: [:], equation: "log(x + 1, 5) = 2", solution: ["x": "24"], field: "b").isEmpty)
  }
}
