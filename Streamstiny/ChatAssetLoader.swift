import Foundation

// Both WebKit surfaces and metadata use this one bounded, cancellable loader.
// URLSession/URLCache retain HTTP validation and expiration semantics.
actor ChatAssetLoader {
  struct Resource: Sendable {
    let data: Data
    let response: HTTPURLResponse
  }
  struct Metrics: Codable, Sendable {
    var requests = 0
    var bytes = 0
    var cacheHits = 0
    var failures = 0
    var deduplicated = 0
    var peakActive = 0
  }
  private struct Work {
    let id = UUID()
    let request: URLRequest
    var waiters: [UUID: CheckedContinuation<Resource, Error>] = [:]
    var task: Task<Void, Never>?
  }
  private let session: URLSession
  private let snapshotURL: URL?
  private var work: [URL: Work] = [:]
  private var queue = AssetDownloadQueue<URL>()
  private(set) var metrics = Metrics()

  init(configuration: URLSessionConfiguration = .default, snapshotURL: URL? = nil) {
    configuration.httpMaximumConnectionsPerHost = 4
    configuration.timeoutIntervalForRequest = 15
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpAdditionalHeaders = ["User-Agent": PlaybackResolver.userAgent]
    configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024)
    session = URLSession(configuration: configuration)
    self.snapshotURL = snapshotURL
  }
  deinit { session.invalidateAndCancel() }

  func resource(_ url: URL, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) async throws -> Resource {
    try Task.checkCancellation()
    guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw URLError(.unsupportedURL) }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if work[url] == nil {
          work[url] = Work(request: URLRequest(url: url, cachePolicy: cachePolicy))
        } else { metrics.deduplicated += 1 }
        work[url]?.waiters[id] = continuation
        for ready in queue.enqueue(url) { start(ready) }
      }
    } onCancel: {
      Task { await self.cancel(url, waiter: id) }
    }
  }
  private func start(_ url: URL) {
    guard let item = work[url] else { return }
    metrics.peakActive = max(metrics.peakActive, queue.active.count)
    let session = session
    work[url]?.task = Task {
      do {
        var resource: Resource?
        for attempt in 0...1 {
          try Task.checkCancellation()
          let probe = RequestMetrics()
          metrics.requests += 1
          do {
            let (data, response) = try await session.data(for: item.request, delegate: probe)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let sample = probe.sample
            metrics.bytes += sample.bytes
            metrics.cacheHits += sample.cached ? 1 : 0
            if response.statusCode == 200 {
              resource = Resource(data: ChatImageFormat.normalized(data), response: response)
              break
            }
            guard attempt == 0, [408, 429, 500, 502, 503, 504].contains(response.statusCode) else {
              throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(response.statusCode) for \(url.absoluteString)"])
            }
            let delay = min(15, max(0.5, Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0.5))
            try await Task.sleep(for: .seconds(delay))
          } catch {
            guard attempt == 0, !Task.isCancelled, (error as? URLError)?.code != .badServerResponse else { throw error }
            try await Task.sleep(for: .milliseconds(500))
          }
        }
        guard let resource else { throw URLError(.badServerResponse) }
        complete(url, id: item.id, result: .success(resource))
      } catch { complete(url, id: item.id, result: .failure(error)) }
    }
  }
  private func complete(_ url: URL, id: UUID, result: Result<Resource, Error>) {
    guard let item = work[url], item.id == id else { return }
    work.removeValue(forKey: url)
    if case .failure = result { metrics.failures += 1 }
    for waiter in item.waiters.values { waiter.resume(with: result) }
    for ready in queue.finish(url) { start(ready) }
  }
  private func cancel(_ url: URL, waiter: UUID) {
    guard let continuation = work[url]?.waiters.removeValue(forKey: waiter) else { return }
    continuation.resume(throwing: CancellationError())
    if work[url]?.waiters.isEmpty == true {
      work.removeValue(forKey: url)?.task?.cancel()
      for ready in queue.remove(url) { start(ready) }
    }
  }

  func discover() async throws -> ChatAssetConfiguration {
    let resource = try await resource(URL(string: "https://www.destiny.gg/embed/chat")!, cachePolicy: .reloadRevalidatingCacheData)
    guard resource.data.count < 2 * 1024 * 1024, let html = String(data: resource.data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
    return try ChatAssetConfiguration.discover(in: html)
  }
  func snapshot(_ configuration: ChatAssetConfiguration) async throws -> ChatAssetSnapshot {
    async let emotes = resource(configuration.url("emotes/emotes.json"), cachePolicy: .reloadRevalidatingCacheData)
    async let flairs = resource(configuration.url("flairs/flairs.json"), cachePolicy: .reloadRevalidatingCacheData)
    async let emoteCSS = resource(configuration.url("emotes/emotes.css"), cachePolicy: .reloadRevalidatingCacheData)
    async let flairCSS = resource(configuration.url("flairs/flairs.css"), cachePolicy: .reloadRevalidatingCacheData)
    let values = try await [emotes, flairs, emoteCSS, flairCSS]
    try Task.checkCancellation()
    guard values.allSatisfy({ $0.data.count <= 2 * 1024 * 1024 }),
      let style = String(data: values[2].data, encoding: .utf8),
      let badges = String(data: values[3].data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
    let result = try ChatAssetSnapshot(configuration: configuration,
      emotes: JSONDecoder().decode([Emote].self, from: values[0].data),
      flairs: JSONDecoder().decode([ChatFlair].self, from: values[1].data), emoteCSS: style, flairCSS: badges)
    guard !result.emotes.isEmpty, !result.flairs.isEmpty,
      result.emotes.contains(where: { !$0.prefix.isEmpty && $0.image.contains(where: { $0.url.flatMap(ChatAssetConfiguration.proxied) != nil }) }),
      style.contains(".emote"), badges.contains(".flair"),
      !style.lowercased().contains("<html"), !badges.lowercased().contains("<html") else { throw URLError(.cannotDecodeContentData) }
    if let snapshotURL {
      try? FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? JSONEncoder().encode(result).write(to: snapshotURL, options: .atomic)
    }
    return result
  }
  func savedSnapshot() -> ChatAssetSnapshot? {
    guard let snapshotURL, let data = try? Data(contentsOf: snapshotURL), data.count < 5 * 1024 * 1024,
      let snapshot = try? JSONDecoder().decode(ChatAssetSnapshot.self, from: data),
      !snapshot.emotes.isEmpty, !snapshot.flairs.isEmpty,
      snapshot.stylesheet.contains(".emote"), snapshot.stylesheet.contains(".flair"),
      !snapshot.stylesheet.lowercased().contains("<html"),
      snapshot.configuration.base.scheme == "https",
      snapshot.configuration.base.host?.hasSuffix(".destiny.gg") == true else { return nil }
    return snapshot
  }
  func releaseMemory() {
    let cache = session.configuration.urlCache
    cache?.memoryCapacity = 0
    cache?.memoryCapacity = 8 * 1024 * 1024
  }
}

private final class RequestMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var value = (bytes: 0, cached: false)
  var sample: (bytes: Int, cached: Bool) { lock.withLock { value } }
  func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
    lock.withLock {
      value = (metrics.transactionMetrics.reduce(0) { $0 + Int($1.countOfResponseBodyBytesReceived) },
        metrics.transactionMetrics.contains { $0.resourceFetchType == .localCache })
    }
  }
}
