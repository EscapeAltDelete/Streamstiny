import Foundation

// Same-stream is message metadata, not a visible badge. Like the DGG userscript,
// fade focus takes precedence over hiding; highlights and non-chat events remain.
enum ChatVisibility {
  static func watchingSame(_ message: ChatMessage, users: [String: ChatUser], selected: StreamSource?) -> Bool {
    if (users[message.nick.lowercased()] ?? message.user).watching?.matches(selected) == true { return true }
    return message.comboNicks.contains { users[$0.lowercased()]?.watching?.matches(selected) == true }
  }
  static func highlightedAuthor(_ message: ChatMessage, highlights: Set<String>) -> Bool {
    highlights.contains(message.nick.lowercased()) || message.comboNicks.contains { highlights.contains($0.lowercased()) }
  }

  static func includes(_ message: ChatMessage, sameStream: @autoclosure () -> Bool, highlighted: @autoclosure () -> Bool,
    hideUnfocused: Bool, watchingFocus: Bool) -> Bool {
    !hideUnfocused || watchingFocus || message.kind != "MSG" || message.whisper
      || sameStream() || highlighted()
  }
}
