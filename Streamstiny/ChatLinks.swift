import Foundation

enum ChatLinks {
  private static let detector = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue)
  private static let shortcuts = try? NSRegularExpression(pattern: #"(?<![\w/])#[\w.-]+/[\w/-]+"#)
  static func matches(in text: String) -> [(range: NSRange, url: URL)] {
    let range = NSRange(text.startIndex..., in: text)
    let detected = detector?.matches(in: text, range: range) ?? []
    var result: [(NSRange, URL)] = []
    for match in shortcuts?.matches(in: text, range: range) ?? [] {
      guard
        !detected.contains(where: {
          $0.range.location < match.range.location
            && NSIntersectionRange($0.range, match.range).length > 0
        }),
        let substring = Range(match.range, in: text),
        let source = try? StreamSource.parse(String(text[substring])), source.provider != .direct,
        let url = URL(
          string: "https://www.destiny.gg/bigscreen#\(source.provider.platform)/\(source.key)")
      else { continue }
      result.append((match.range, url))
    }
    for match in detected {
      guard let url = match.url, ["https", "http"].contains(url.scheme),
        !result.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 })
      else { continue }
      result.append((match.range, url))
    }
    return result.sorted { $0.0.location < $1.0.location }
  }

  static func stream(at url: URL) -> StreamSource? {
    guard ["destiny.gg", "www.destiny.gg"].contains(url.host?.lowercased() ?? ""),
      url.fragment != nil
    else { return nil }
    return try? StreamSource.parse(url.absoluteString)
  }
}
