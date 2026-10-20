// 찾기의 질의 (DECISIONS.md 48). 따옴표로 묶은 것은 구절 하나, 나머지는 빈칸으로 나눈 낱말이다.
// 한 글 안에 모든 낱말이 들어 있어야 맞는다. 대소문자와 악센트는 가리지 않는다. 한국어 조사는 떼지 않는다.
// 맥의 색인, 용어·기호 찾기, 폰의 찾기가 함께 쓴다. 학습 페이지 안 찾기(renderer/page.js 의 find)도 같은 규칙으로 나눈다.
import Foundation

public struct SearchQuery: Sendable, Equatable {
  // 친 말 (앞뒤 빈칸을 걷은 것)
  public let text: String
  // 낱말과 구절 (따옴표를 뗀 것)
  public let terms: [String]

  public init(_ text: String) {
    self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var terms: [String] = []
    var current = ""
    var quoted = false
    func flush() {
      let t = current.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      if !t.isEmpty && !terms.contains(where: { Self.same($0, t) }) { terms.append(t) }
      current = ""
    }
    for ch in self.text {
      if ch == "\"" || ch == "“" || ch == "”" {
        flush()
        quoted.toggle()
      } else if ch.isWhitespace && !quoted {
        flush()
      } else {
        current.append(ch)
      }
    }
    flush()
    self.terms = terms
  }

  public var isEmpty: Bool { terms.isEmpty }

  static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

  static func same(_ a: String, _ b: String) -> Bool { a.compare(b, options: options) == .orderedSame }

  // trigram 색인으로 찾는 낱말 (세 글자 이상)과 글 전체에서 찾는 짧은 낱말
  var long: [String] { terms.filter { $0.count >= 3 } }
  var short: [String] { terms.filter { $0.count < 3 } }

  // FTS5 MATCH 글: "a" AND "b"
  var match: String? {
    long.isEmpty ? nil : long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
  }

  // 낱말들을 빈칸 하나로 이은 것. 이것이 그대로 든 글이 순위에서 앞선다
  var phrase: String { terms.joined(separator: " ") }

  // 이 낱말이 글에 드는가 (대소문자, 악센트 무시)
  public static func contains(_ text: String, _ term: String) -> Bool { text.range(of: term, options: options) != nil }

  // 이 낱말이 낱말 첫머리에서 드는가: 바로 앞 글자가 문자가 아니다 (숫자는 된다. "2x" 의 x).
  // 순위에만 쓴다. "using" 안의 "sin", "블로그" 안의 "로그"는 맞되 뒤로 간다. "로그의", "laws"는 첫머리다
  public static func startsWord(_ text: String, _ term: String) -> Bool {
    var from = text.startIndex
    while from < text.endIndex, let r = text.range(of: term, options: options, range: from..<text.endIndex) {
      if r.lowerBound == text.startIndex || !text[text.index(before: r.lowerBound)].isLetter { return true }
      from = text.index(after: r.lowerBound)
    }
    return false
  }

  // 모든 낱말이 이 글들 가운데 어딘가의 낱말 첫머리에 드는가
  func startsWords(_ fields: [String]) -> Bool {
    !terms.isEmpty && terms.allSatisfy { t in fields.contains { Self.startsWord($0, t) } }
  }

  // 모든 낱말이 이 글들 가운데 어딘가에 드는가 (용어의 이름들, 기호와 뜻처럼 여러 칸을 함께 볼 때)
  public func matches(_ fields: [String]) -> Bool {
    !terms.isEmpty && terms.allSatisfy { t in fields.contains { Self.contains($0, t) } }
  }

  public func matches(_ text: String) -> Bool { matches([text]) }

  // 찾은 말 표시: 모든 낱말의 모든 곳을 SearchMark.open … close 로 감싼다 (겹치면 합친다)
  public func mark(_ s: String) -> String {
    var ranges: [Range<String.Index>] = []
    for t in terms {
      var from = s.startIndex
      while from < s.endIndex, let r = s.range(of: t, options: Self.options, range: from..<s.endIndex) {
        ranges.append(r)
        from = r.upperBound > r.lowerBound ? r.upperBound : s.index(after: r.lowerBound)
      }
    }
    guard !ranges.isEmpty else { return s }
    ranges.sort { $0.lowerBound < $1.lowerBound }
    var merged: [Range<String.Index>] = []
    for r in ranges {
      if let last = merged.last, r.lowerBound <= last.upperBound {
        merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
      } else {
        merged.append(r)
      }
    }
    var out = ""
    var at = s.startIndex
    for r in merged {
      out += s[at..<r.lowerBound] + String(SearchMark.open) + s[r] + String(SearchMark.close)
      at = r.upperBound
    }
    return out + s[at...]
  }
}

// 찾은 말 표시와 앞뒤 글 자르기
public enum SearchMark {
  public static let open: Character = "\u{1}"
  public static let close: Character = "\u{2}"

  // 표시된 글에서 첫 표시 앞 before 글자부터 모두 length 글자를 자른다
  public static func excerpt(_ marked: String, before: Int = 50, length: Int = 180) -> String {
    let chars = Array(marked)
    guard let first = chars.firstIndex(of: open) else { return String(chars.prefix(length)) + (chars.count > length ? "…" : "") }
    var start = max(0, first - before)
    // 낱말 가운데서 자르지 않는다
    while start > 0, start < first, !chars[start - 1].isWhitespace { start += 1 }
    let end = min(chars.count, start + length)
    var out = String(chars[start..<end])
    // 잘려 닫히지 않은 표시를 닫는다
    if out.filter({ $0 == open }).count > out.filter({ $0 == close }).count { out.append(close) }
    return (start > 0 ? "…" : "") + out + (end < chars.count ? "…" : "")
  }

  // 표시를 뗀 글
  public static func plain(_ marked: String) -> String { marked.filter { $0 != open && $0 != close } }
}
