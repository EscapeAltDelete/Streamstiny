import Foundation

// Only application-generated markup enters WebKit; chat text is always escaped.
// These helpers are also exercised by the Foundation-only regression runner.
enum ChatHTML {
  static func escape(_ text: String) -> String {
    guard text.utf8.contains(where: { $0 == 38 || $0 == 60 || $0 == 62 || $0 == 34 || $0 == 39 }) else { return text }
    var result: [UInt8] = []
    result.reserveCapacity(text.utf8.count)
    for byte in text.utf8 {
      switch byte {
      case 38: result.append(contentsOf: "&amp;".utf8)
      case 60: result.append(contentsOf: "&lt;".utf8)
      case 62: result.append(contentsOf: "&gt;".utf8)
      case 34: result.append(contentsOf: "&quot;".utf8)
      case 39: result.append(contentsOf: "&#39;".utf8)
      default: result.append(byte)
      }
    }
    return String(decoding: result, as: UTF8.self)
  }
  private static let tokens = try! NSRegularExpression(pattern: #"\S+|\s+"#)
  static func body(_ text: String, links: Bool = true, emote: (String) -> URL?) -> String {
    tokens.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
      guard let range = Range(match.range, in: text) else { return nil }
      let word = String(text[range])
      if let url = emote(word), let resource = ChatAssetConfiguration.proxied(url) {
        let name = escape(word)
        return "<div title=\"\(name)\" class=\"emote \(name) not-visible\" data-resource=\"\(escape(resource.absoluteString))\">\(name) </div>"
      }
      guard links, !word.allSatisfy(\.isWhitespace) else { return escape(word) }
      var result = "", start = word.startIndex
      for match in ChatLinks.matches(in: word) {
        guard let span = Range(match.range, in: word), span.lowerBound >= start else { continue }
        result += escape(String(word[start..<span.lowerBound]))
        result += "<a class=\"externallink\" href=\"\(escape(match.url.absoluteString))\">\(escape(String(word[span])))</a>"
        start = span.upperBound
      }
      return result + escape(String(word[start...]))
    }.joined()
  }
  static func flair(_ flair: ChatFlair) -> String {
    guard !flair.hidden, let url = flair.image?.first?.url,
      let resource = ChatAssetConfiguration.proxied(url) else { return "" }
    return "<i data-flair=\"\(escape(flair.name))\" class=\"flair \(escape(flair.name)) not-visible\" title=\"\(escape(flair.label))\" aria-label=\"\(escape(flair.label))\" data-resource=\"\(escape(resource.absoluteString))\"></i> "
  }
}
