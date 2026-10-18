import Foundation
import Observation
import OSLog

@MainActor @Observable final class EmoteStore {
  private(set) var catalog: [String: URL] = [:]
  private(set) var flairs: [ChatFlair] = []
  private(set) var snapshot: ChatAssetSnapshot?
  private(set) var stylesheet = ""
  private(set) var revision = 0
  private(set) var catalogRevision = 0
  private(set) var recoveryRevision = 0
  private(set) var status: String?
  private(set) var suspended = false
  private(set) var favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteEmotes") ?? [])
  @ObservationIgnored let assets: ChatAssetLoader
  @ObservationIgnored private var requirements: [String: Emote] = [:]
  @ObservationIgnored private var assetLoad: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var pendingCacheKey: String?
  @ObservationIgnored private var nextRefresh = Date.distantPast

  init(assets: ChatAssetLoader? = nil) {
    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Streamstiny/chat-assets.json")
    self.assets = assets ?? ChatAssetLoader(snapshotURL: cache)
  }
  func favorite(_ name: String) {
    if favorites.contains(name) { favorites.remove(name) } else { favorites.insert(name) }
    UserDefaults.standard.set(Array(favorites).sorted(), forKey: "favoriteEmotes")
  }
  func refreshPreferences() {
    favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteEmotes") ?? [])
    revision += 1
  }
  func canUse(_ word: String, user: ChatUser?) -> Bool { requirements[word]?.allows(user) == true }

  func combining(_ messages: [ChatMessage]) -> [ChatMessage] {
    if UserDefaults.standard.bool(forKey: "disableEmoteCombos") { return messages }
    var result: [ChatMessage] = []
    for message in messages {
      let word = message.text.hasPrefix("/me ") ? String(message.text.dropFirst(4)) : message.text
      guard message.kind == "MSG", !message.whisper, !message.removed, canUse(word, user: message.user) else {
        result.append(message); continue
      }
      if let last = result.last, last.kind == "MSG", !last.removed, last.text == message.text, !last.comboNicks.isEmpty {
        result[result.count - 1].comboNicks.append(message.nick)
      } else {
        var entry = message; entry.comboNicks = [message.nick]; result.append(entry)
      }
    }
    return result
  }
  func load(force: Bool = false, cacheKey: String? = nil) async {
    guard !suspended else { return }
    if let key = cacheKey, key == snapshot?.configuration.cacheKey { return }
    if let assetLoad {
      if let cacheKey { pendingCacheKey = cacheKey }
      await assetLoad.value
      return
    }
    guard force || cacheKey != nil || Date() >= nextRefresh else { return }
    let version = generation
    let work = Task { [weak self] in
      guard let self else { return }
      await self.refresh(cacheKey: cacheKey, generation: version)
    }
    assetLoad = work
    await work.value
    guard generation == version else { return }
    assetLoad = nil
    if let key = pendingCacheKey {
      pendingCacheKey = nil
      await load(force: true, cacheKey: key)
    }
  }
  private func refresh(cacheKey: String?, generation version: Int) async {
    do {
      if snapshot == nil, let cached = await assets.savedSnapshot(), generation == version, !suspended {
        apply(cached)
      }
      let discovered: ChatAssetConfiguration
      if cacheKey != nil, let current = snapshot?.configuration {
        discovered = current
      } else { discovered = try await assets.discover() }
      let configuration = ChatAssetConfiguration(base: discovered.base, cacheKey: cacheKey ?? discovered.cacheKey)
      let value: ChatAssetSnapshot
      if let current = snapshot, current.configuration == configuration { value = current }
      else { value = try await assets.snapshot(configuration) }
      try Task.checkCancellation()
      guard generation == version, !suspended else { return }
      apply(value)
      status = nil
      nextRefresh = Date().addingTimeInterval(1800)
    } catch {
      guard generation == version, !Task.isCancelled else { return }
      Logger(subsystem: "gg.streamstiny.app", category: "Chat assets").error("Asset refresh failed: \(String(describing: error), privacy: .public)")
      status = snapshot == nil ? "Chat assets could not be loaded. Reopen chat to retry." : "Using cached chat assets; updates are temporarily unavailable."
      nextRefresh = Date().addingTimeInterval(30)
    }
  }
  private func apply(_ value: ChatAssetSnapshot) {
    let changed = snapshot?.emotes != value.emotes || snapshot?.flairs != value.flairs || snapshot?.stylesheet != value.stylesheet
    snapshot = value
    guard changed else { return }
    requirements = Dictionary(value.emotes.map { ($0.prefix, $0) }, uniquingKeysWith: { _, new in new })
    catalog = Dictionary(value.emotes.compactMap { emote in
      emote.image.first?.url.flatMap { ChatAssetConfiguration.proxied($0) == nil ? nil : (emote.prefix, $0) }
    }, uniquingKeysWith: { _, new in new })
    flairs = value.flairs.sorted { $0.priority < $1.priority }
    stylesheet = value.stylesheet
    catalogRevision += 1
    revision += 1
  }
  func releaseMemory(suspend: Bool? = nil) {
    suspended = suspend ?? suspended
    if suspended {
      generation += 1
      assetLoad?.cancel(); assetLoad = nil
      pendingCacheKey = nil
    }
    Task { await assets.releaseMemory() }
    revision += 1
  }
  func resume() {
    guard suspended else { return }
    suspended = false
    recoverAssets()
  }
  func recoverAssets() {
    recoveryRevision += 1
    revision += 1
  }
}
