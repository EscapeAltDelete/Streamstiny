import Foundation

@main struct ChatPresentationTests {
  static var checks = 0
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(condition(), message)
  }
  static func main() throws {
    for size in [CGSize(width: 390, height: 750), CGSize(width: 430, height: 850),
      CGSize(width: 768, height: 980), CGSize(width: 390, height: 300), .zero] {
      let expected = size.height - min(size.width * 9 / 16, size.height / 2)
      for fraction in [-1.0, 0.3, 0.36, 0.65, 2, .nan, .infinity] {
        let height = ChatSize.extent(size: size, fraction: fraction, landscape: false)
        expect(height == expected, "Portrait must ignore the landscape fraction")
        expect(height >= size.height / 2 && height <= size.height, "Portrait keeps room for chat")
      }
    }
    for fraction in [-1.0, 0.3, 0.65, 2, .nan, .infinity] {
      let width = ChatSize.extent(size: CGSize(width: 844, height: 390), fraction: fraction, landscape: true)
      expect(width.isFinite && width >= 220 && width <= 548.6, "Landscape limits remain valid")
    }
    expect(ChatSize.extent(size: CGSize(width: 844, height: 390), fraction: 0.4, landscape: true) == 337.6,
      "Landscape still respects the selected fraction")

    let source = StreamSource(provider: .twitch, key: "PietSmiet")
    let alice = ChatUser(["nick": "Alice", "watching": ["platform": "twitch", "id": "pietsmiet"]])
    let bob = ChatUser(["nick": "Bob", "watching": ["platform": "twitch", "id": "other"]])
    let message = ChatMessage(payload: ["nick": "Alice", "data": "Hello"])
    expect(ChatVisibility.watchingSame(message, users: ["alice": alice], selected: source), "Current watching metadata matches case-insensitive Twitch channels")
    expect(!ChatVisibility.watchingSame(message, users: ["alice": alice], selected: nil), "No selected stream does not match")
    expect(!ChatVisibility.watchingSame(message, users: ["alice": alice], selected: StreamSource(provider: .kick, key: "pietsmiet")), "Different providers do not match")
    let embedded = ChatMessage(payload: ["nick": "Alice", "watching": ["platform": "twitch", "id": "pietsmiet"]])
    expect(ChatVisibility.watchingSame(embedded, users: [:], selected: source), "Embedded watching metadata is a fallback")
    expect(!ChatVisibility.watchingSame(embedded, users: ["alice": ChatUser(["nick": "Alice"])], selected: source), "Updated user metadata clears stale matches")
    var combo = ChatMessage(payload: ["nick": "Bob", "data": "DGG"])
    combo.comboNicks = ["Bob", "ALICE"]
    expect(ChatVisibility.watchingSame(combo, users: ["alice": alice, "bob": bob], selected: source), "Any matching combo participant keeps the combo focused")
    expect(ChatVisibility.highlightedAuthor(combo, highlights: ["alice"]), "Highlighted combo participants are retained")
    expect(!ChatVisibility.highlightedAuthor(combo, highlights: ["charlie"]), "Unrelated highlights do not match")
    for hide in [false, true] { for focus in [false, true] {
      for same in [false, true] { for highlight in [false, true] {
        let included = ChatVisibility.includes(message, sameStream: same, highlighted: highlight, hideUnfocused: hide, watchingFocus: focus)
        expect(included == (!hide || focus || same || highlight), "Hide filter follows userscript precedence")
        for event in [ChatMessage(payload: [:], kind: "SYSTEM"), ChatMessage(payload: [:], kind: "BROADCAST"),
          ChatMessage(payload: [:], whisper: true, kind: "PRIVMSG")] {
          expect(ChatVisibility.includes(event, sameStream: same, highlighted: highlight, hideUnfocused: hide, watchingFocus: focus), "Events and whispers remain accessible")
        }
      }}
    }}

    let history = (0..<1000).map(String.init)
    expect(ChatScrollAnchor.surviving(visible: ["400", "401"], previous: history, current: Set(history)) == "400", "Unchanged history keeps first visible message")
    expect(ChatScrollAnchor.surviving(visible: ["400", "401"], previous: history, current: ["401", "402"]) == "401", "Filtering first visible row retains another visible row")
    expect(ChatScrollAnchor.surviving(visible: ["400", "401"], previous: history, current: ["399", "402"]) == "402", "Removing all visible rows anchors to next surviving message")
    expect(ChatScrollAnchor.surviving(visible: ["400", "401"], previous: history, current: ["398", "399"]) == "399", "Fallback to preceding message when later rows disappear")
    expect(ChatScrollAnchor.surviving(visible: ["400"], previous: history, current: []) == nil, "Empty filter has no anchor")
    expect(ChatScrollAnchor.surviving(visible: [], previous: history, current: Set(history)) == nil, "Empty viewport has no anchor")
    for cutoff in stride(from: 1, to: 999, by: 7) {
      let remaining = Set(history.dropFirst(cutoff))
      expect(ChatScrollAnchor.surviving(visible: ["0"], previous: history, current: remaining) == String(cutoff), "History eviction uses oldest surviving row")
    }
    let maximum = CGSize(width: 100, height: 36)
    for size in [CGSize(width: 28, height: 28), CGSize(width: 1200, height: 20), CGSize(width: 10, height: 1000), .zero, CGSize(width: CGFloat.infinity, height: 20)] {
      let fitted = ChatAttachmentSize.fitted(size, maximum: maximum)
      expect(fitted.width.isFinite && fitted.height.isFinite && fitted.width > 0 && fitted.height > 0, "Attachment dimensions are usable")
      expect(fitted.width <= 100 && fitted.height <= 36, "Attachment dimensions fit the row budget")
    }
    print("Passed \(checks) chat presentation assertions")
  }
}
