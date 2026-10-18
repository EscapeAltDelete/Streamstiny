import Foundation

private final class ChatAssetProtocol: URLProtocol, @unchecked Sendable {
  struct Reply { let status: Int; let data: Data; let delay: Double }
  private static let lock = NSLock()
  private static var handler: @Sendable (URLRequest) -> Reply = { _ in Reply(status: 404, data: Data(), delay: 0) }
  private static var requests: [URLRequest] = []
  private static var active = 0
  private static var maximum = 0
  private let state = NSLock()
  private var finished = false
  private var pending: DispatchWorkItem?
  static func prepare(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
    lock.withLock { self.handler = handler; requests = []; active = 0; maximum = 0 }
  }
  static var counts: (requests: Int, active: Int, maximum: Int) {
    lock.withLock { (requests.count, active, maximum) }
  }
  static var policies: [URLRequest.CachePolicy] { lock.withLock { requests.map(\.cachePolicy) } }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let reply = Self.lock.withLock {
      Self.requests.append(request); Self.active += 1; Self.maximum = max(Self.maximum, Self.active)
      return Self.handler(request)
    }
    let item = DispatchWorkItem { [weak self] in
      guard let self, markFinished() else { return }
      let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
        headerFields: ["Content-Type": "application/octet-stream", "Cache-Control": "no-store"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: reply.data)
      client?.urlProtocolDidFinishLoading(self)
    }
    pending = item
    DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: item)
  }
  private func markFinished() -> Bool {
    state.withLock {
      guard !finished else { return false }
      finished = true
      Self.lock.withLock { Self.active -= 1 }
      return true
    }
  }
  override func stopLoading() { pending?.cancel(); _ = markFinished() }
}

enum ChatAssetsTests {
  @MainActor static func run() async throws {
    let html = #"<script data-cdn="https://r2cdn.destiny.gg" data-cache-key="one"></script>"#
    let configuration = try ChatAssetConfiguration.discover(in: html)
    precondition(configuration.base.host == "r2cdn.destiny.gg")
    precondition(configuration.url("emotes/emotes.json").absoluteString == "https://r2cdn.destiny.gg/emotes/emotes.json?_=one")
    for source in [html.replacingOccurrences(of: "r2cdn.destiny.gg", with: "destiny.gg.evil.test"),
      html.replacingOccurrences(of: "https:", with: "http:"), html.replacingOccurrences(of: "r2cdn.destiny.gg", with: "user@r2cdn.destiny.gg"), ""] {
      do { _ = try ChatAssetConfiguration.discover(in: source); preconditionFailure("Reject invalid discovery configuration") }
      catch {}
    }
    let css = #".emote.PepoPunch {width:47px;background:url('image.png');animation:frames 1s steps(8) 3 -.5s} @keyframes frames {100%{background-position:-448px}} .x{mask:url(#mask);background:url(data:image/png;base64,AAAA)}"#
    let routed = ChatAssetConfiguration.stylesheet(css, relativeTo: configuration.url("emotes/emotes.css"))
    precondition(routed.contains("dgg-asset://r2cdn.destiny.gg/emotes/image.png"))
    precondition(routed.contains("animation:frames 1s steps(8) 3 -.5s") && routed.contains("background-position:-448px"))
    precondition(routed.contains("url(#mask)") && routed.contains("url(data:image/png;base64,AAAA)"))
    let url = URL(string: "https://r2cdn.destiny.gg/emotes/image.png?x=1&y=2")!
    precondition(ChatAssetConfiguration.original(ChatAssetConfiguration.proxied(url)!) == url)
    precondition(ChatAssetConfiguration.original(URL(string: "dgg-asset://r2cdn.destiny.gg/emotes/image.png?x=1&y=2&__streamstiny_retry=3")!) == url)
    precondition(ChatAssetConfiguration.proxied(URL(string: "javascript:alert(1)")!) == nil)
    let hiddenFlair = try JSONDecoder().decode(ChatFlair.self, from: Data(#"{"name":"flair25","label":"Hidden","priority":50,"hidden":true,"image":[{"url":null,"width":0,"height":0}]}"#.utf8))
    precondition(ChatHTML.flair(hiddenFlair).isEmpty, "Native hidden flairs can legitimately have no image URL")
    let emote = try JSONDecoder().decode(Emote.self, from: Data(#"{"prefix":"Member","image":[{"url":"https://r2cdn.destiny.gg/emotes/member.png"}],"minimumSubTier":0,"patreonOnly":true}"#.utf8))
    precondition(!emote.allows(nil) && !emote.allows(ChatUser(["subscription": ["tier": 5]])))
    precondition(emote.allows(ChatUser(["patreonMember": true])) && emote.allows(ChatUser(["roles": ["PROTECTED"]])))
    precondition(ChatUser(["subscription": ["tier": 4], "features": []]).tier == 4)
    precondition(ChatUser(["features": ["flair42"], "subscription": NSNull()]).tier == 0, "Cosmetic badges do not grant subscription rights")
    precondition(!ChatUser(["features": ["moderator"]]).privileged)
    let formatted = ChatHTML.body("<script>alert('x')</script> Listening Listening,", emote: { $0 == "Listening" ? url : nil })
    precondition(!formatted.contains("<script>") && formatted.contains("&lt;script&gt;"))
    precondition(formatted.components(separatedBy: "class=\"emote Listening").count == 2)
    precondition(formatted.contains("Listening,"), "Emotes match complete, case-sensitive tokens")
    if case .reloadAssets(let key) = try ChatProtocol.decode(#"REFRESHCHATASSETS {"cacheKey":"two"}"#) { precondition(key == "two") }
    else { preconditionFailure("Retain authoritative cache key") }
    if case .reload = try ChatProtocol.decode("RELOAD") {} else { preconditionFailure("Handle bodyless control commands") }
    _ = try? ChatProtocol.decode("")

    let session = URLSessionConfiguration.ephemeral
    session.protocolClasses = [ChatAssetProtocol.self]
    let loader = ChatAssetLoader(configuration: session)
    ChatAssetProtocol.prepare { _ in .init(status: 200, data: Data([0, 1, 2, 255]), delay: 0.1) }
    let copies = try await withThrowingTaskGroup(of: Data.self, returning: [Data].self) { group in
      for _ in 0..<8 { group.addTask { try await loader.resource(url).data } }
      var results: [Data] = []; for try await data in group { results.append(data) }; return results
    }
    precondition(copies.count == 8 && copies.allSatisfy { $0 == Data([0, 1, 2, 255]) })
    precondition(ChatAssetProtocol.counts.requests == 1, "Deduplicate concurrent consumers")
    let measured = await loader.metrics
    precondition(measured.deduplicated == 7)
    precondition(ChatAssetProtocol.policies == [.useProtocolCachePolicy])

    ChatAssetProtocol.prepare { _ in .init(status: 200, data: Data([42]), delay: 0.05) }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<12 { group.addTask { _ = try await loader.resource(URL(string: "https://r2cdn.destiny.gg/emotes/\(index).png")!) } }
      try await group.waitForAll()
    }
    precondition(ChatAssetProtocol.counts.requests == 12 && ChatAssetProtocol.counts.maximum <= 4)
    ChatAssetProtocol.prepare { _ in .init(status: 200, data: Data([7]), delay: 0.15) }
    let first = Task { try await loader.resource(url) }, second = Task { try await loader.resource(url) }
    try await Task.sleep(for: .milliseconds(20)); first.cancel()
    do { _ = try await first.value; preconditionFailure("Canceled consumer must stop waiting") } catch is CancellationError {}
    let remaining = try await second.value
    precondition(remaining.data == Data([7]) && ChatAssetProtocol.counts.requests == 1, "One cancellation must not cancel another consumer")
    ChatAssetProtocol.prepare { _ in .init(status: 200, data: Data(), delay: 2) }
    let abandoned = (0..<8).map { index in Task { try await loader.resource(URL(string: "https://r2cdn.destiny.gg/emotes/cancel-\(index).png")!) } }
    try await Task.sleep(for: .milliseconds(20)); abandoned.forEach { $0.cancel() }
    for task in abandoned { do { _ = try await task.value; preconditionFailure("Cancel queued and active work") } catch {} }
    try await Task.sleep(for: .milliseconds(50))
    precondition(ChatAssetProtocol.counts.active == 0)
    ChatAssetProtocol.prepare { _ in .init(status: 200, data: Data(repeating: 42, count: 3 * 1024 * 1024), delay: 0) }
    let large = try await loader.resource(url)
    precondition(large.data.count == 3 * 1024 * 1024, "Do not truncate image data or reject formats by frame count")
    _ = try await loader.resource(url, cachePolicy: .reloadIgnoringLocalCacheData)
    precondition(ChatAssetProtocol.policies.last == .reloadIgnoringLocalCacheData, "Failed-image recovery must bypass a corrupt cached body, not accept a 304 for it")

    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("snapshot.json")
    defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }
    let savedLoader = ChatAssetLoader(configuration: session, snapshotURL: temp)
    ChatAssetProtocol.prepare { request in
      let path = request.url!.path
      if path == "/embed/chat" { return .init(status: 200, data: Data(html.utf8), delay: 0.02) }
      let broken = request.url!.query?.contains("broken") == true
      let bytes: String
      switch path {
      case "/emotes/emotes.json": bytes = #"[{"prefix":"Free","image":[{"url":"https://r2cdn.destiny.gg/emotes/free.png","width":32,"height":30}],"minimumSubTier":0}]"#
      case "/flairs/flairs.json": bytes = #"[{"name":"flair127","label":"Blue Wave Supporter","priority":50,"hidden":false,"image":[{"url":"https://r2cdn.destiny.gg/flairs/badge.png","width":18,"height":18}]}]"#
      case "/emotes/emotes.css": bytes = ".emote.Free {background-image:url('free.png');width:32px;height:30px}"
      default: bytes = ".flair.flair127 {background-image:url('badge.png');width:18px;height:18px}"
      }
      return .init(status: broken ? 404 : 200, data: Data(bytes.utf8), delay: 0.02)
    }
    let store = EmoteStore(assets: savedLoader)
    let loading = Task { await store.load(force: true) }
    try await Task.sleep(for: .milliseconds(10))
    let update = Task { await store.load(force: true, cacheKey: "two") }
    await loading.value; await update.value
    precondition(store.snapshot?.configuration.cacheKey == "two", "Asset event during loading must not get lost")
    precondition(store.catalog["Free"] != nil && store.flairs.contains { $0.name == "flair127" })
    let revision = store.catalogRevision, count = ChatAssetProtocol.counts.requests
    await store.load(force: true, cacheKey: "two")
    precondition(ChatAssetProtocol.counts.requests == count, "Repeated asset versions must not refetch")
    await store.load(force: true, cacheKey: "three")
    precondition(store.catalogRevision == revision, "A version-only change must not remount unchanged animations")
    await store.load(force: true, cacheKey: "broken")
    precondition(store.snapshot?.configuration.cacheKey == "three" && store.catalog["Free"] != nil && store.status != nil)
    let saved = await savedLoader.savedSnapshot()
    precondition(saved?.configuration.cacheKey == "three", "Failed refresh must not replace the last valid on-disk snapshot")
    ChatAssetProtocol.prepare { request in
      precondition(request.url?.path == "/embed/chat", "A matching authoritative version must reuse the coherent cached catalog")
      return .init(status: 200, data: Data(html.replacingOccurrences(of: "one", with: "three").utf8), delay: 0)
    }
    let warmStore = EmoteStore(assets: savedLoader)
    await warmStore.load(force: true)
    precondition(warmStore.catalog["Free"] != nil && warmStore.status == nil && ChatAssetProtocol.counts.requests == 1)
    ChatAssetProtocol.prepare { _ in .init(status: 404, data: Data(), delay: 0) }
    let offline = EmoteStore(assets: savedLoader)
    await offline.load(force: true)
    precondition(offline.catalog["Free"] != nil && offline.status != nil)
    print("Passed chat asset discovery, native CSS transport, permissions, escaping, deduplication, concurrency, cancellation, updates, and offline-cache regressions")
  }
}
