// 공통 검사 가운데 글에 하는 것 (JOBS.md 의 공통 검사).
// - 학습 내용(영어 칸)에 한글이 섞이면 실패다. 한국어 칸은 한국어여야 한다.
// - 한자와 일본어는 어느 칸에도 쓰지 않는다.
// - "slide 3", "see the diagram above"처럼 원래 자료가 있어야만 통하는 말을 찾는다.
import Foundation

public enum TextChecks {
  public static func hasHangul(_ s: String) -> Bool {
    s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) }
  }

  // 한자(통합 한자, 확장 A, 호환 한자, 확장 B 이후)와 가나
  public static func hasHanOrKana(_ s: String) -> Bool {
    s.unicodeScalars.contains {
      let v = $0.value
      return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v) || (0x20000...0x2FA1F).contains(v)
        || (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) || (0xFF66...0xFF9D).contains(v)
    }
  }

  static let materialPatterns: [NSRegularExpression] = [
    #"\b(?:slides?|pages?|worksheets?|handouts?|questions?)\s*#?\d+"#,
    #"\b(?:see|look at|refer to)\s+(?:the\s+)?(?:diagram|figure|picture|graph|table|image|slide|worksheet|example)s?\s+(?:above|below|on the)"#,
    #"\bas shown (?:on|in|above|below)\b"#,
    #"\b(?:the\s+)?(?:diagram|figure|picture|graph|table|image)s?\s+(?:above|below)\b"#,
    #"\b(?:previous|next|this|that)\s+(?:slide|page|worksheet|handout)\b"#,
  ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

  // 원래 자료가 있어야만 통하는 말
  public static func materialPhrases(_ s: String) -> [String] {
    let plain = TexText.strip(s)
    var out: [String] = []
    for p in materialPatterns {
      for m in p.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
        if let r = Range(m.range, in: plain) { out.append(String(plain[r])) }
      }
    }
    return out
  }

  // 영어 칸: 한글, 한자, 일본어가 없어야 한다
  public static func englishProblems(_ s: String, field: String) -> [String] {
    var out: [String] = []
    if hasHangul(s) { out.append("\(field): 영어로 써야 하는데 한글이 섞였습니다") }
    if hasHanOrKana(s) { out.append("\(field): 한자나 일본어가 섞였습니다") }
    return out
  }

  // 한국어 칸: 한글이 있어야 하고 한자, 일본어가 없어야 한다
  public static func koreanProblems(_ s: String, field: String) -> [String] {
    var out: [String] = []
    if !hasHangul(s) { out.append("\(field): 한국어로 써야 합니다") }
    if hasHanOrKana(s) { out.append("\(field): 한자나 일본어가 섞였습니다") }
    return out
  }

  // 기록용 글(리포트): 한자, 일본어만 본다
  public static func recordProblems(_ s: String, field: String) -> [String] {
    hasHanOrKana(s) ? ["\(field): 한자나 일본어가 섞였습니다"] : []
  }
}

// 글 속의 TeX: 줄 안 수식 \( … \)와 따로 선 수식 \[ … \]
public enum TexText {
  public struct Segment: Sendable, Equatable {
    public let tex: String
    public let display: Bool
  }

  public static func segments(_ s: String) -> [Segment] {
    var out: [Segment] = []
    var rest = s[...]
    while let open = rest.range(of: #"\\[(\[]"#, options: .regularExpression) {
      let display = rest[open].hasSuffix("[")
      let closer = display ? "\\]" : "\\)"
      guard let close = rest.range(of: closer, range: open.upperBound..<rest.endIndex) else { break }
      out.append(Segment(tex: String(rest[open.upperBound..<close.lowerBound]), display: display))
      rest = rest[close.upperBound...]
    }
    return out
  }

  // 수식을 뺀 글
  public static func strip(_ s: String) -> String {
    var out = ""
    var rest = s[...]
    while let open = rest.range(of: #"\\[(\[]"#, options: .regularExpression) {
      let closer = rest[open].hasSuffix("[") ? "\\]" : "\\)"
      guard let close = rest.range(of: closer, range: open.upperBound..<rest.endIndex) else { break }
      out += rest[..<open.lowerBound] + " "
      rest = rest[close.upperBound...]
    }
    return out + rest
  }

  // TeX 밖에 글자로 쓴 수식 (7^(-1), log_7, sqrt(8)). 학습 페이지의 글에서는 \( \) 안에 TeX 로 써야 그려진다.
  public static func asciiMath(_ s: String, field: String) -> [String] {
    let plain = strip(s).replacingOccurrences(of: #"`[^`]*`"#, with: " ", options: .regularExpression)
    let pattern = #"[A-Za-z0-9)\]]\^[-+({A-Za-z0-9]|\blog_[A-Za-z0-9({]|\bsqrt\("#
    guard let r = plain.range(of: pattern, options: .regularExpression) else { return [] }
    let from = plain.index(r.lowerBound, offsetBy: -12, limitedBy: plain.startIndex) ?? plain.startIndex
    let to = plain.index(r.upperBound, offsetBy: 12, limitedBy: plain.endIndex) ?? plain.endIndex
    return ["\(field): 수식을 TeX 밖에 글자로 썼습니다 (…\(plain[from..<to])…). 수식은 \\( \\) 안에 TeX 로 쓴다"]
  }

  // 목록과 찾기 결과에 보일 글: 수식 구분자와 마크다운 표시를 걷고 흔한 TeX 명령을 읽을 수 있게 바꾼다
  public static func plain(_ s: String) -> String {
    var t = s
    for (a, b) in [(#"\\\(|\\\)|\\\[|\\\]"#, ""), (#"\\(?:dfrac|tfrac|frac)\{([^{}]*)\}\{([^{}]*)\}"#, "$1/$2"),
      (#"\\(?:left|right|displaystyle)\b"#, ""), (#"\\(?:,|;|!|quad\b|qquad\b)"#, " "), (#"\\times\b"#, "×"), (#"\\cdot\b"#, "·"),
      (#"\\div\b"#, "÷"), (#"\\approx\b"#, "≈"), (#"\\(?:neq|ne)\b"#, "≠"), (#"\\(?:leq|le)\b"#, "≤"), (#"\\(?:geq|ge)\b"#, "≥"),
      (#"\\pm\b"#, "±"), (#"\\infty\b"#, "∞"), (#"\\sqrt\b"#, "√"), (#"\\text\{([^{}]*)\}"#, "$1"), (#"\\([A-Za-z]+)"#, "$1"),
      (#"[{}]"#, ""), (#"\*\*|__|`"#, ""), (#"\s+"#, " ")]
    {
      t = t.replacingOccurrences(of: a, with: b, options: .regularExpression)
    }
    return t.trimmingCharacters(in: .whitespaces)
  }

  // 목록에 보일 글 (DECISIONS.md 32): plain 에 더해 숫자 아래첨자와 위첨자를 글자로 바꾼다 (Q_1 → Q₁, x^2 → x², 10^-3 → 10⁻³).
  // 찾기 색인은 plain 을 쓴다 (Q1 이나 x^2 로 찾을 수 있게).
  public static func display(_ s: String) -> String {
    var out = plain(s)
    for (mark, map) in [("_", "₀₁₂₃₄₅₆₇₈₉"), ("^", "⁰¹²³⁴⁵⁶⁷⁸⁹")] {
      let minus: Character = mark == "_" ? "₋" : "⁻"
      let regex = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: mark) + #"(-?\d+)"#)
      for m in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
        guard let whole = Range(m.range, in: out), let digits = Range(m.range(at: 1), in: out) else { continue }
        let glyphs = Array(map)
        let converted = String(out[digits].map { $0 == "-" ? minus : glyphs[Int(String($0))!] })
        out.replaceSubrange(whole, with: converted)
      }
    }
    return out
  }

  // 수식 밖의 숫자 (번역 대조용). 1,000 과 1000 은 같게 본다.
  public static func numbers(_ s: String) -> [String] {
    let plain = strip(s)
    let regex = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)*"#)
    return regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).compactMap { m in
      Range(m.range, in: plain).map { String(plain[$0]).replacingOccurrences(of: ",", with: "") }
    }
  }

  // 수식을 견줄 때: 공백을 뺀다
  public static func key(_ tex: String) -> String { String(tex.filter { !$0.isWhitespace }) }
}
