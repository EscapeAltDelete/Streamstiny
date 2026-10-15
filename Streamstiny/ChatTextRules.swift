import Foundation

// Reuse compiled patterns while the preference strings remain unchanged.
struct ChatTextRules {
  struct Configuration: Equatable {
    var highlights = ""
    var censoredWords = "fuck, shit, cunt"
    var censorWords = false
    var hideNSFW = false
    var hideNSFL = false
  }
  let configuration: Configuration
  let customHighlights: [String]
  private let replacements: [(pattern: NSRegularExpression, replacement: String)]
  private static let nsfw = try! NSRegularExpression(pattern: #"\bnsfw\b"#, options: .caseInsensitive)
  private static let nsfl = try! NSRegularExpression(pattern: #"\bnsfl\b"#, options: .caseInsensitive)

  init(_ configuration: Configuration) {
    self.configuration = configuration
    customHighlights = configuration.highlights.components(separatedBy: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      .prefix(32).map { String($0.prefix(100)) }
    replacements = configuration.censorWords ? configuration.censoredWords.components(separatedBy: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      .prefix(100).compactMap { word in
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: String(word.prefix(100))) + #"\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        return (expression, String(repeating: "•", count: min(word.count, 100)))
      } : []
  }
  func highlighted(_ text: String) -> Bool {
    customHighlights.contains { text.localizedCaseInsensitiveContains($0) }
  }
  func sensitive(_ text: String) -> Bool {
    guard configuration.hideNSFW || configuration.hideNSFL else { return false }
    let range = NSRange(text.startIndex..., in: text)
    return (configuration.hideNSFW && Self.nsfw.firstMatch(in: text, range: range) != nil)
      || (configuration.hideNSFL && Self.nsfl.firstMatch(in: text, range: range) != nil)
  }
  func censored(_ text: String) -> String {
    replacements.reduce(text) { result, rule in
      rule.pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
        withTemplate: rule.replacement)
    }
  }
}

struct ChatMentionMatcher {
  let nick: String
  private let pattern: NSRegularExpression?
  init(_ nick: String) {
    self.nick = nick
    pattern = try? NSRegularExpression(pattern: #"(?<![\w])@?"#
      + NSRegularExpression.escapedPattern(for: nick) + #"(?![\w])"#, options: .caseInsensitive)
  }
  func matches(_ text: String) -> Bool {
    pattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }
}
