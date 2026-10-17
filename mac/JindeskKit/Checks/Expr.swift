// 풀이 블록의 계산 검사에 쓰는 작은 수식 계산기 (PAGES.md 의 글 블록: derivation).
// 에이전트가 단계마다 TeX 과 함께 계산할 수 있는 식(expr)을 주면, 이웃 단계를 정의역의 표본 값에 넣어 같은 값인지 본다.
// 식: 수, 변수, + - * / ^, 괄호, 함수 sqrt ln log(x) log(x, b) exp abs sin cos tan asin acos atan, 상수 pi e. 곱하기는 * 로 적는다.
import Foundation

public indirect enum Expr: Sendable, Equatable {
  case number(Double)
  case variable(String)
  case unary(Character, Expr)
  case binary(Character, Expr, Expr)
  case call(String, [Expr])

  public struct ParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
  }

  static let functions: [String: ClosedRange<Int>] = [
    "sqrt": 1...1, "ln": 1...1, "log": 1...2, "exp": 1...1, "abs": 1...1, "sin": 1...1, "cos": 1...1, "tan": 1...1, "asin": 1...1,
    "acos": 1...1, "atan": 1...1,
  ]

  public static func parse(_ text: String) throws -> Expr {
    var p = Parser(Array(text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "÷", with: "/")))
    let e = try p.expression()
    p.skip()
    guard p.i == p.s.count else { throw ParseError(message: "식을 끝까지 읽지 못했습니다: \(text)") }
    return e
  }

  public var variables: Set<String> {
    switch self {
    case .number: []
    case .variable(let v): [v]
    case .unary(_, let e): e.variables
    case .binary(_, let a, let b): a.variables.union(b.variables)
    case .call(_, let args): args.reduce(into: Set<String>()) { $0.formUnion($1.variables) }
    }
  }

  public func value(_ env: [String: Double]) -> Double {
    switch self {
    case .number(let n): return n
    case .variable(let v):
      switch v {
      case "pi": return .pi
      case "e": return M_E
      default: return env[v] ?? .nan
      }
    case .unary(let op, let e): return op == "-" ? -e.value(env) : e.value(env)
    case .binary(let op, let a, let b):
      let x = a.value(env)
      let y = b.value(env)
      switch op {
      case "+": return x + y
      case "-": return x - y
      case "*": return x * y
      case "/": return y == 0 ? .nan : x / y
      default: return pow(x, y)
      }
    case .call(let f, let args):
      let a = args.map { $0.value(env) }
      switch f {
      case "sqrt": return a[0] < 0 ? .nan : a[0].squareRoot()
      case "ln": return a[0] <= 0 ? .nan : Foundation.log(a[0])
      case "log":
        if a.count == 2 { return a[0] <= 0 || a[1] <= 0 || a[1] == 1 ? .nan : Foundation.log(a[0]) / Foundation.log(a[1]) }
        return a[0] <= 0 ? .nan : log10(a[0])
      case "exp": return Foundation.exp(a[0])
      case "abs": return Swift.abs(a[0])
      case "sin": return Foundation.sin(a[0])
      case "cos": return Foundation.cos(a[0])
      case "tan": return Foundation.tan(a[0])
      case "asin": return Foundation.asin(a[0])
      case "acos": return Foundation.acos(a[0])
      default: return Foundation.atan(a[0])
      }
    }
  }

  struct Parser {
    let s: [Character]
    var i = 0

    init(_ s: [Character]) { self.s = s }

    mutating func skip() { while i < s.count, s[i].isWhitespace { i += 1 } }

    mutating func peek() -> Character? {
      skip()
      return i < s.count ? s[i] : nil
    }

    mutating func expression() throws -> Expr {
      var left = try term()
      while let c = peek(), c == "+" || c == "-" {
        i += 1
        left = .binary(c, left, try term())
      }
      return left
    }

    mutating func term() throws -> Expr {
      var left = try unary()
      while let c = peek(), c == "*" || c == "/" {
        i += 1
        left = .binary(c, left, try unary())
      }
      return left
    }

    mutating func unary() throws -> Expr {
      if let c = peek(), c == "-" || c == "+" {
        i += 1
        return .unary(c, try unary())
      }
      return try power()
    }

    mutating func power() throws -> Expr {
      let base = try primary()
      if peek() == "^" {
        i += 1
        return .binary("^", base, try unary())
      }
      return base
    }

    mutating func primary() throws -> Expr {
      guard let c = peek() else { throw ParseError(message: "식이 덜 끝났습니다") }
      if c == "(" {
        i += 1
        let e = try expression()
        guard peek() == ")" else { throw ParseError(message: "괄호가 닫히지 않았습니다") }
        i += 1
        return e
      }
      if c.isNumber || c == "." {
        var t = ""
        while i < s.count, s[i].isNumber || s[i] == "." { t.append(s[i]); i += 1 }
        if i < s.count, s[i] == "e" || s[i] == "E", i + 1 < s.count, s[i + 1].isNumber || s[i + 1] == "-" || s[i + 1] == "+" {
          t.append("e")
          i += 1
          if s[i] == "-" || s[i] == "+" { t.append(s[i]); i += 1 }
          while i < s.count, s[i].isNumber { t.append(s[i]); i += 1 }
        }
        guard let n = Double(t) else { throw ParseError(message: "수를 읽지 못했습니다: \(t)") }
        return .number(n)
      }
      if c.isLetter {
        var name = ""
        while i < s.count, s[i].isLetter || s[i].isNumber || s[i] == "_" { name.append(s[i]); i += 1 }
        if let arity = Expr.functions[name] {
          guard peek() == "(" else { throw ParseError(message: "\(name) 뒤에 괄호가 있어야 합니다") }
          i += 1
          var args = [try expression()]
          while peek() == "," {
            i += 1
            args.append(try expression())
          }
          guard peek() == ")" else { throw ParseError(message: "\(name)( 의 괄호가 닫히지 않았습니다") }
          i += 1
          guard arity.contains(args.count) else { throw ParseError(message: "\(name) 에 넣는 값의 수가 맞지 않습니다") }
          return .call(name, args)
        }
        return .variable(name)
      }
      throw ParseError(message: "읽을 수 없는 글자입니다: \(c)")
    }
  }
}

// 등식 "왼쪽 = 오른쪽" 은 (왼쪽) - (오른쪽) 으로 본다
public struct Relation: Sendable, Equatable {
  public let lhs: Expr
  public let rhs: Expr

  public static func parse(_ text: String) throws -> Relation {
    let parts = text.split(separator: "=", omittingEmptySubsequences: false)
    guard parts.count == 2 else { throw Expr.ParseError(message: "등식에는 = 가 하나 있어야 합니다: \(text)") }
    return Relation(lhs: try Expr.parse(String(parts[0])), rhs: try Expr.parse(String(parts[1])))
  }
}

public enum DerivationCheck {
  public struct Step: Sendable {
    public let expr: String?
    // ≈ 로 이어진 단계 (반올림한 값)
    public let approx: Bool

    public init(expr: String?, approx: Bool) {
      self.expr = expr
      self.approx = approx
    }
  }

  // 정의역 안의 표본 값 (늘 같은 값이 나오게 고정한 차례)
  static func samples(_ vars: [String: ClosedRange<Double>], count: Int = 7) -> [[String: Double]] {
    let fractions = [0.13, 0.37, 0.61, 0.83, 0.29, 0.71, 0.47, 0.91, 0.07]
    return (0..<count).map { k in
      var env: [String: Double] = [:]
      for (j, (name, range)) in vars.sorted(by: { $0.key < $1.key }).enumerated() {
        let f = fractions[(k + j * 3) % fractions.count]
        env[name] = range.lowerBound + (range.upperBound - range.lowerBound) * f
      }
      return env
    }
  }

  // 반올림한 단계의 허용 오차: 식에 든 수 가운데 소수점 아래 자리가 가장 긴 것의 반 자리
  static func tolerance(_ expr: String, approx: Bool) -> (absolute: Double, relative: Double) {
    guard approx else { return (1e-9, 1e-9) }
    let decimals = (try? NSRegularExpression(pattern: #"\d+\.(\d+)"#))?.matches(in: expr, range: NSRange(expr.startIndex..., in: expr)).compactMap {
      Range($0.range(at: 1), in: expr).map { expr[$0].count }
    }.max() ?? 0
    return (0.5 * pow(10, -Double(decimals)) * 1.0001, 1e-9)
  }

  static func close(_ a: Double, _ b: Double, _ tol: (absolute: Double, relative: Double)) -> Bool {
    abs(a - b) <= max(tol.absolute, tol.relative * max(1, abs(a), abs(b)))
  }

  // 단계의 식과 마지막 대입 검사의 문제를 돌려준다. 없으면 빈 목록.
  public static func problems(
    steps: [Step], vars: [String: ClosedRange<Double>], equation: String?, solution: [String: String], field: String
  ) -> [String] {
    var out: [String] = []
    var parsed: [(index: Int, expr: Expr, text: String, approx: Bool)] = []
    for (i, step) in steps.enumerated() {
      guard let text = step.expr?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
      do {
        let e = try Expr.parse(text)
        let unknown = e.variables.subtracting(["pi", "e"]).subtracting(vars.keys)
        if !unknown.isEmpty { out.append("\(field).steps[\(i)].expr: vars 에 없는 변수입니다 (\(unknown.sorted().joined(separator: ", ")))") }
        parsed.append((i, e, text, step.approx))
      } catch {
        out.append("\(field).steps[\(i)].expr: \(error)")
      }
    }
    guard out.isEmpty else { return out }
    let envs = samples(vars)
    for (a, b) in zip(parsed, parsed.dropFirst()) {
      let tol = tolerance(b.text, approx: b.approx)
      var compared = 0
      for env in envs {
        let x = a.expr.value(env)
        let y = b.expr.value(env)
        guard x.isFinite, y.isFinite else { continue }
        compared += 1
        if !close(x, y, tol) {
          let at = env.sorted { $0.key < $1.key }.map { "\($0.key)=\(YAML.formatNumber($0.value))" }.joined(separator: ", ")
          out.append(
            "\(field).steps[\(a.index)] 와 steps[\(b.index)] 의 값이 다릅니다 (\(at.isEmpty ? "" : at + " 에서 ")\(YAML.formatNumber(x)) ≠ \(YAML.formatNumber(y)))")
          break
        }
      }
      if compared == 0 { out.append("\(field).steps[\(a.index)] 와 steps[\(b.index)] 를 정의역 안에서 계산할 수 없습니다. vars 의 범위를 본다") }
    }
    if let equation = equation?.nilIfBlank {
      do {
        let r = try Relation.parse(equation)
        var env: [String: Double] = [:]
        var approx = false
        for (name, valueText) in solution {
          let e = try Expr.parse(valueText)
          env[name] = e.value([:])
          if valueText.range(of: #"\d\.\d"#, options: .regularExpression) != nil && e.variables.isEmpty { approx = true }
        }
        let l = r.lhs.value(env)
        let rv = r.rhs.value(env)
        let tol: (absolute: Double, relative: Double) = approx ? (0, 0.01) : (1e-9, 1e-9)
        if !l.isFinite || !rv.isFinite || !close(l, rv, tol) {
          out.append("\(field).check: 답을 넣으면 등식이 성립하지 않습니다 (\(YAML.formatNumber(l)) ≠ \(YAML.formatNumber(rv)))")
        }
      } catch {
        out.append("\(field).check: \(error)")
      }
    }
    return out
  }
}
