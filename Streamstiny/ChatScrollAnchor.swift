import Foundation

enum ChatScrollAnchor {
  static func surviving(visible: [String], previous: [String], current: Set<String>) -> String? {
    if let retained = visible.first(where: { current.contains($0) }) { return retained }
    guard let first = visible.first, let index = previous.firstIndex(of: first) else { return nil }
    return previous.dropFirst(index).first(where: { current.contains($0) })
      ?? previous.prefix(index).last(where: { current.contains($0) })
  }
}
