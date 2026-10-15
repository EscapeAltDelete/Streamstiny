import Foundation

@main struct ResourceEfficiencyTests {
  static var checks = 0
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(condition(), message)
  }
  static func legacyCensored(_ text: String, words: String) -> String {
    var result = text
    for word in words.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }).prefix(100) {
      let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: String(word.prefix(100))) + "\\b"
      result = result.replacingOccurrences(of: pattern, with: String(repeating: "•", count: min(word.count, 100)), options: .regularExpression)
    }
    return result
  }
  static func main() {
    let messages = ["Alice hello", "@ALICE hello", "malice", "Alice_1", "Hi, Alice!", "éAlice", "😀 Alice", "@Alice@example.com", "nsfwish", "NSFW link", "[NSFL]", "FUCK shit, bullshit", "C++ c++ . *", "你好你好 HELLO", "", "a.b aXb", "@user[1] hello"]
    for nick in ["Alice", "user[1]", "a.b", "你好", ""] {
      let matcher = ChatMentionMatcher(nick)
      for message in messages {
        let legacy = message.range(of: "(?i)(?<![\\w])@?" + NSRegularExpression.escapedPattern(for: nick) + "(?![\\w])", options: .regularExpression) != nil
        expect(matcher.matches(message) == legacy, "Mention boundaries and escaping preserve behavior")
      }
    }
    for words in ["fuck, shit, cunt", " c++, a.b, .*, 你好 ", "", String(repeating: "a", count: 120), Array(repeating: "hello", count: 105).joined(separator: ",")] {
      for censor in [true, false] { for nsfw in [true, false] { for nsfl in [true, false] {
        let rules = ChatTextRules(.init(highlights: " ,ALICE, 你好, c++ , ", censoredWords: words, censorWords: censor, hideNSFW: nsfw, hideNSFL: nsfl))
        for message in messages {
          expect(rules.censored(message) == (censor ? legacyCensored(message, words: words) : message), "Cached censor patterns preserve sequential replacements")
          let sensitive = (nsfw && message.range(of: "(?i)\\bnsfw\\b", options: .regularExpression) != nil) || (nsfl && message.range(of: "(?i)\\bnsfl\\b", options: .regularExpression) != nil)
          expect(rules.sensitive(message) == sensitive, "Sensitive word boundaries preserve behavior")
          expect(rules.highlighted(message) == ["ALICE", "你好", "c++"].contains(where: { message.localizedCaseInsensitiveContains($0) }), "Custom highlights preserve locale-aware comparisons")
        }
      }}}
    }
    let manyHighlights = ChatTextRules(.init(highlights: (0..<40).map { "term\($0)" }.joined(separator: ",")))
    expect(manyHighlights.customHighlights.count == 32, "Highlight count remains bounded")
    expect(ChatTextRules(.init(highlights: String(repeating: "a", count: 200))).customHighlights[0].count == 100, "Highlight length remains bounded")

    for limit in [0, 1, 4, 16] {
      var queue = AssetDownloadQueue<Int>(limit: limit)
      var started: [Int] = []
      for key in 0..<1000 {
        started += queue.enqueue(key)
        expect(queue.enqueue(key).isEmpty, "Duplicate requests do not create work")
        expect(queue.active.count <= max(1, limit), "Active download/decode jobs stay bounded")
      }
      expect(started == Array(0..<max(1, limit)), "Initial jobs run immediately in request order")
      var finished = Set<Int>()
      while !queue.active.isEmpty {
        let key = queue.active.min()!
        finished.insert(key)
        started += queue.finish(key)
        expect(queue.finish(key).isEmpty, "Duplicate completion does not release another job")
        expect(queue.active.count <= max(1, limit), "Completing jobs respects concurrency budget")
      }
      expect(finished.count == 1000 && started == Array(0..<1000), "Every queued request completes exactly once in order")
      expect(queue.pendingCount == 0, "Draining leaves no pending work")
      _ = queue.enqueue(1001)
      _ = queue.enqueue(1002)
      queue.removeAll()
      expect(queue.active.isEmpty && queue.pendingCount == 0, "Suspension discards active and pending work")
      expect(queue.finish(1001).isEmpty, "Stale canceled completion cannot start old work")
      expect(queue.enqueue(1001) == [1001], "Resuming can request the same asset again")
    }
    let terms = "fuck, shit, cunt, spam, banana, noise, hello, alice"
    let rules = ChatTextRules(.init(censoredWords: terms, censorWords: true))
    let text = "Alice says hello, no spam or noise; banana. Fuck shit cunt."
    let iterations = 1000
    let clock = ContinuousClock()
    var oldCount = 0, newCount = 0
    let oldTime = clock.measure { for _ in 0..<iterations { oldCount += legacyCensored(text, words: terms).count } }
    let newTime = clock.measure { for _ in 0..<iterations { newCount += rules.censored(text).count } }
    expect(oldCount == newCount && newCount > 0, "Benchmark preserves output length")
    print("Passed \(checks) resource-efficiency assertions")
    print("1000 censor passes (legacy / cached): \(oldTime) / \(newTime)")
  }
}
