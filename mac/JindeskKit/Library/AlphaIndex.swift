// 모아 보기의 A–Z 인덱스 (DECISIONS.md 34): 이름의 첫 글자로 묶는다. 영어 A–Z, 숫자는 "#", 그 밖(그리스 문자, 한글 등)은 "•".
// 이름은 수식 구분자와 TeX 명령을 걷어 낸 글로 본다 (\(Q_1\) → Q).
import Foundation

public enum AlphaIndex {
  public static let letters = (65...90).map { String(UnicodeScalar($0)!) } + ["#", "•"]

  public static func letter(_ name: String) -> String {
    let plain = name.replacingOccurrences(of: #"\\[()\[\]]|\\[A-Za-z]+\{?|[{}$]"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    guard let ch = plain.unicodeScalars.first else { return "•" }
    let up = String(ch).uppercased()
    if up.count == 1, let s = up.unicodeScalars.first, (65...90).contains(s.value) { return up }
    if CharacterSet.decimalDigits.contains(ch) { return "#" }
    return "•"
  }

  // 글자마다 묶는다 (letters 차례). 묶음 안은 이름 차례(대소문자를 가리지 않는다)
  public static func sections<T>(_ items: [T], name: (T) -> String) -> [(letter: String, items: [T])] {
    var by: [String: [(String, T)]] = [:]
    for item in items {
      let n = name(item)
      by[letter(n), default: []].append((n, item))
    }
    return letters.compactMap { l in
      by[l].map { (l, $0.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }.map(\.1)) }
    }
  }
}
