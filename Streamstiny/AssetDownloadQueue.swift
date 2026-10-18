import Foundation

// Pending images occupy queue entries, not suspended tasks or decoder workers.
struct AssetDownloadQueue<Key: Hashable> {
  let limit: Int
  private(set) var active: Set<Key> = []
  private var pending: [Key] = []
  private var queued: Set<Key> = []
  init(limit: Int = 4) { self.limit = max(1, limit) }
  mutating func enqueue(_ key: Key) -> [Key] {
    guard !active.contains(key), queued.insert(key).inserted else { return [] }
    pending.append(key)
    return startAvailable()
  }
  mutating func finish(_ key: Key) -> [Key] {
    guard active.remove(key) != nil else { return [] }
    return startAvailable()
  }
  mutating func remove(_ key: Key) -> [Key] {
    active.remove(key)
    queued.remove(key)
    pending.removeAll { $0 == key }
    return startAvailable()
  }
  private mutating func startAvailable() -> [Key] {
    let count = min(max(0, limit - active.count), pending.count)
    guard count > 0 else { return [] }
    let ready = Array(pending.prefix(count))
    pending.removeFirst(count)
    for key in ready { queued.remove(key); active.insert(key) }
    return ready
  }
}
