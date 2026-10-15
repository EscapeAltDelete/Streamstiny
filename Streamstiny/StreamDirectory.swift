import Foundation
import Observation

struct DirectoryItem: Identifiable, Equatable, Sendable {
  let source: StreamSource
  let name: String
  let live: Bool
  var viewers: Int? = nil
  var dggViewers: Int? = nil
  var id: String { source.id }
}

enum DirectoryEvent: Sendable {
  case embeds([DirectoryItem])
  case streams([DirectoryItem])
  case hosting(DirectoryItem?)
  case banned([String: String])
  case other
  private static func count(_ value: Any?) -> Int? {
    guard let count = value as? Int, count >= 0 else { return nil }
    return count
  }

  static func decode(_ text: String) throws -> Self {
    guard let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { return .other }
    switch frame["type"] as? String {
    case "dggApi:embeds":
      let rows = frame["data"] as? [[String: Any]] ?? []
      return .embeds(
        rows.compactMap { row in
          let media = row["mediaItem"] as? [String: Any] ?? [:]
          let identifier = media["identifier"] as? [String: Any] ?? [:]
          let metadata = media["metadata"] as? [String: Any] ?? [:]
          guard let platform = identifier["platform"] as? String ?? row["platform"] as? String,
            let provider = StreamSource.Provider.platform(platform),
            let key = identifier["mediaId"] as? String ?? row["id"] as? String,
            let source = try? StreamSource.parse(key, provider: provider)
          else { return nil }
          return DirectoryItem(
            source: source, name: metadata["displayName"] as? String ?? key,
            live: metadata["live"] as? Bool ?? false,
            viewers: Self.count(metadata["viewers"]), dggViewers: Self.count(row["count"]))
        })
    case "dggApi:streamInfo":
      let data = frame["data"] as? [String: Any] ?? [:]
      let streams = data["streams"] as? [String: Any] ?? [:]
      return .streams(
        streams.compactMap { platform, entry in
          guard let value = entry as? [String: Any], value["live"] as? Bool == true,
            let provider = StreamSource.Provider.platform(platform),
            let key = value["id"] as? String,
            let source = try? StreamSource.parse(key, provider: provider)
          else { return nil }
          return DirectoryItem(
            source: source, name: "Destiny",
            live: true, viewers: Self.count(value["viewers"]))
        })
    case "dggApi:hosting":
      guard let value = frame["data"] as? [String: Any],
        let platform = value["platform"] as? String,
        let provider = StreamSource.Provider.platform(platform), let key = value["id"] as? String,
        let source = try? StreamSource.parse(key, provider: provider)
      else { return .hosting(nil) }
      return .hosting(
        DirectoryItem(
          source: source, name: value["displayName"] as? String ?? key,
          live: true, viewers: Self.count(value["viewers"])))
    case "dggApi:bannedEmbeds":
      let rows = frame["data"] as? [[String: Any]] ?? []
      return .banned(
        Dictionary(
          rows.compactMap { row in
            guard let platform = row["platform"] as? String,
              let provider = StreamSource.Provider.platform(platform),
              let key = row["name"] as? String
            else { return nil }
            return (
              StreamSource(provider: provider, key: key).id,
              row["reason"] as? String ?? "Blocked by Destiny.gg"
            )
          }, uniquingKeysWith: { _, latest in latest }))
    default: return .other
    }
  }
}

@MainActor @Observable final class StreamLibrary {
  private(set) var selected: StreamSource
  private(set) var embeds: [DirectoryItem] = []
  private(set) var streams: [DirectoryItem] = []
  private(set) var hosting: DirectoryItem?
  private(set) var banned: [String: String] = [:]
  private(set) var connected = false
  private(set) var directory: [DirectoryItem] = []
  private let connection = DestinySocket(url: URL(string: "wss://live.destiny.gg")!)
  private var worker: Task<Void, Never>?
  private var stopping = false
  private var desiredActive = false
  private var chooseInitialLive: Bool
  private let defaults: UserDefaults
  private func updateDirectory() {
    var seen: Set<String> = []
    let items = (streams + (hosting.map { [$0] } ?? []) + embeds).filter {
      seen.insert($0.id).inserted && banned[$0.id] == nil
    }
    if directory != items { directory = items }
  }
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let last = defaults.data(forKey: "selectedSourceData")
      .flatMap { try? JSONDecoder().decode(StreamSource.self, from: $0) }
    selected = last ?? StreamSource.initial
    chooseInitialLive = last == nil

  }
  func dggViewerCount(for source: StreamSource) -> Int? {
    guard connected else { return nil }
    return embeds.first { $0.id == source.id }?.dggViewers
  }

  func viewerCount(for source: StreamSource) -> Int? {
    guard connected else { return nil }
    if streams.contains(where: { $0.id == source.id }) {
      let counts = streams.compactMap(\.viewers)
      return counts.isEmpty ? nil : counts.reduce(0, +)
    }
    return embeds.first { $0.id == source.id }?.viewers
      ?? (hosting?.id == source.id ? hosting?.viewers : nil)
  }

  func select(_ source: StreamSource) {
    chooseInitialLive = false
    selected = source
    if let data = try? JSONEncoder().encode(source) {
      defaults.set(data, forKey: "selectedSourceData")
    }
  }
  func start() {
    desiredActive = true
    guard worker == nil, !stopping else { return }
    worker = Task { [weak self] in
      var failures = 0
      while !Task.isCancelled {
        guard let connection = self?.connection else { return }
        await connection.connect()
        let opened = Date()
        do {
          while !Task.isCancelled {
            let event = try await connection.receiveDirectory()
            guard !Task.isCancelled else { break }
            if self?.connected != true { self?.connected = true }
            self?.consume(event)
            if Date().timeIntervalSince(opened) > 5 { failures = 0 }
          }
        } catch {
          // Reconnect with bounded backoff below.
        }
        self?.connected = false
        await connection.disconnect()
        guard !Task.isCancelled else { break }
        failures = min(failures + 1, 6)
        do {
          try await Task.sleep(
            for: .seconds(min(60, pow(2, Double(failures))) + Double.random(in: 0...1)))
        } catch { break }
      }
    }
  }
  func stop() async {
    desiredActive = false
    guard !stopping else { return }
    stopping = true
    worker?.cancel()
    await connection.disconnect()
    await worker?.value
    worker = nil
    connected = false
    stopping = false
    if desiredActive { start() }
  }
  private func consume(_ event: DirectoryEvent) {
    switch event {
    case .embeds(let items):
      guard embeds != items else { return }
      embeds = items
    case .streams(let items):
      guard streams != items else { return }
      streams = items
    case .hosting(let item):
      guard hosting != item else { return }
      hosting = item
    case .banned(let items):
      guard banned != items else { return }
      banned = items
    case .other: return
    }
    updateDirectory()
    if chooseInitialLive,
      let first = directory.first(where: {
        $0.live && ![.twitch, .twitchVod, .twitchClip].contains($0.source.provider)
      })
    {
      select(first.source)
    }
  }
}
