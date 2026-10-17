import Foundation
@preconcurrency import Network

// Only manifests cross loopback. Media, maps and keys stay on Twitch's CDN.
@MainActor final class TwitchPlaylistGateway {
  private let listener: NWListener
  private let session: TwitchPlaylistSession
  private var ready: CheckedContinuation<Void, Error>?
  private var requests: [UUID: Task<Void, Never>] = [:]
  private(set) var port: UInt16 = 0
  private(set) var waiting = false

  private init(source: StreamSource, variants: [HLSVariant], resolver: PlaybackResolver) throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    session = TwitchPlaylistSession(source: source, variants: variants, resolver: resolver)
  }
  static func start(source: StreamSource, variants: [HLSVariant], resolver: PlaybackResolver) async throws -> TwitchPlaylistGateway {
    let server = try TwitchPlaylistGateway(source: source, variants: variants, resolver: resolver)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        server.ready = continuation
        server.listener.stateUpdateHandler = { [weak server] state in
          Task { @MainActor in
            guard let server else { return }
            switch state {
            case .ready:
              guard let port = server.listener.port?.rawValue else { return }
              server.port = port
              server.ready?.resume(); server.ready = nil
            case .failed(let error): server.ready?.resume(throwing: error); server.ready = nil
            case .cancelled: server.ready?.resume(throwing: CancellationError()); server.ready = nil
            default: break
            }
          }
        }
        server.listener.newConnectionHandler = { [weak server] connection in
          Task { @MainActor in
            if let server { server.accept(connection) } else { connection.cancel() }
          }
        }
        server.listener.start(queue: DispatchQueue(label: "Streamstiny.TwitchPlaylists"))
      }
    } onCancel: { server.listener.cancel() }
    return server
  }
  func url(for remote: URL) async -> URL {
    await session.route(remote, port: port)
  }
  func waitForClean() async -> Bool {
    let clean = await session.waitForClean()
    waiting = await session.waiting
    return clean
  }
  func stop() {
    listener.cancel()
    for task in requests.values { task.cancel() }
    requests.removeAll()
    Task { await session.stop() }
  }
  private func accept(_ connection: NWConnection) {
    guard requests.count < 16 else { connection.cancel(); return }
    let id = UUID()
    connection.start(queue: DispatchQueue.global(qos: .userInitiated))
    requests[id] = Task { [weak self, session] in
      let timeout = Task {
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        connection.cancel()
      }
      defer { timeout.cancel(); connection.cancel(); self?.requests[id] = nil }
      await withTaskCancellationHandler {
        do {
          var request = Data()
          while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
              connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: URLError(complete ? .networkConnectionLost : .badServerResponse)) }
              }
            }
            request.append(chunk)
            guard request.count <= 8192 else { throw URLError(.badServerResponse) }
          }
          let fields = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
          guard fields.count == 3, fields[0] == "GET" || fields[0] == "HEAD", fields[2] == "HTTP/1.1" || fields[2] == "HTTP/1.0" else { throw URLError(.badServerResponse) }
          let result = await session.response(path: String(fields[1]))
          self?.waiting = await session.waiting
          let body = Data(result.text.utf8)
          var response = Data("HTTP/1.1 \(result.status) \(result.status == 200 ? "OK" : "Unavailable")\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
          if fields[0] == "GET" { response.append(body) }
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: response, completion: .contentProcessed { error in
              if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
          }
        } catch { }
      } onCancel: { connection.cancel() }
    }
  }
  deinit { listener.cancel() }
}

actor TwitchPlaylistSession {
  private let source: StreamSource
  private let variants: [HLSVariant]
  private let resolver: PlaybackResolver
  private let network: URLSession
  private let force = UserDefaults.standard.bool(forKey: "twitchForceAdBlocking")
  private var routes: [String: URL] = [:]
  private var paths: [URL: String] = [:]
  private var port: UInt16 = 0
  private var timelines: [URL: TwitchAdTimeline] = [:]
  private var alternative: HLSVariant?
  private var nextProbe = Date.distantPast
  private var inFlight: [URL: Task<(Int, String), Never>] = [:]
  private var blocked: Set<URL> = []
  var waiting: Bool { !blocked.isEmpty }
  private static let uri = try! NSRegularExpression(pattern: #"URI="([^"]+)""#)

  init(source: StreamSource, variants: [HLSVariant], resolver: PlaybackResolver) {
    self.source = source; self.variants = variants; self.resolver = resolver
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 3
    config.httpMaximumConnectionsPerHost = 4
    config.httpAdditionalHeaders = TwitchResolver.mediaHeaders
    network = URLSession(configuration: config)
  }
  func route(_ url: URL, port: UInt16) -> URL {
    self.port = port
    if paths[url] == nil {
      let path = "/" + UUID().uuidString + ".m3u8"
      paths[url] = path; routes[path] = url
    }
    return URL(string: "http://127.0.0.1:\(port)" + paths[url]!)!
  }
  func response(path: String) async -> (status: Int, text: String) {
    guard let url = routes[path] else { return (404, "") }
    if let work = inFlight[url] { return await work.value }
    let work = Task { await self.process(url) }
    inFlight[url] = work
    let result = await work.value
    inFlight[url] = nil
    return result
  }
  private func fetch(_ url: URL) async throws -> (String, URL) {
    guard Self.allowed(url) else { throw URLError(.unsupportedURL) }
    let (data, response) = try await network.data(from: url)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      data.count <= 2 * 1024 * 1024, let final = http.url, Self.allowed(final) else { throw URLError(.badServerResponse) }
    let text = String(decoding: data, as: UTF8.self)
    guard text.hasPrefix("#EXTM3U") else { throw URLError(.cannotDecodeContentData) }
    return (text, final)
  }
  private static func allowed(_ url: URL) -> Bool {
    guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
    return ["ttvnw.net", "jtvnw.net", "twitchcdn.net"].contains { host == $0 || host.hasSuffix("." + $0) }
  }
  private func absolute(_ text: String, base: URL, localPlaylists: Bool) -> String {
    func address(_ value: String) -> String {
      guard let remote = URL(string: value, relativeTo: base)?.absoluteURL, Self.allowed(remote) else { return value }
      return localPlaylists && remote.pathExtension.lowercased() == "m3u8" ? route(remote, port: port).absoluteString : remote.absoluteString
    }
    return text.components(separatedBy: .newlines).map { line in
      if !line.isEmpty, !line.hasPrefix("#") { return address(line) }
      var result = line
      for match in Self.uri.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
        guard let range = Range(match.range(at: 1), in: line), let target = Range(match.range(at: 1), in: result) else { continue }
        result.replaceSubrange(target, with: address(String(line[range])))
      }
      return result
    }.joined(separator: "\n")
  }
  private func process(_ url: URL) async -> (Int, String) {
    do {
      let (text, base) = try await fetch(url)
      let resolved = absolute(text, base: base, localPlaylists: true)
      guard let variant = variants.first(where: { $0.url == url }), !variant.externalMedia,
        let primary = TwitchAdPlaylist(resolved),
        !primary.segments.contains(where: { $0.encrypted }) else {
          if force, resolved.components(separatedBy: .newlines).contains(where: {
            TwitchAdPlaylist.adTag($0) || (!$0.hasPrefix("#") && $0.contains("/adsquared/"))
          }) {
            blocked.insert(url); return (503, "")
          }
          blocked.remove(url)
          return (200, resolved)
        }
      var backup: TwitchAdPlaylist?, origin = "primary"
      if primary.hasAds && primary.cleanSuffix == nil {
        // Search all contexts before exposing a preroll. Each request remains bounded.
        let candidate = await withTaskGroup(of: (TwitchAdPlaylist, String)?.self) { group in
          group.addTask { await self.cleanAlternative(variant, fragmented: primary.segments.first?.map != nil) }
          group.addTask { try? await Task.sleep(for: .milliseconds(6500)); return nil }
          let value = await group.next() ?? nil
          group.cancelAll()
          return value
        }
        if let candidate { backup = candidate.0; origin = candidate.1 }
      }
      try Task.checkCancellation()
      var timeline = timelines[url] ?? TwitchAdTimeline()
      let result = timeline.render(primary, backup: backup, origin: origin, force: force)
      if timeline.waiting { blocked.insert(url) } else { blocked.remove(url) }
      timelines[url] = timeline
      return (200, result)
    } catch { return (502, "") }
  }
  private func cleanAlternative(_ variant: HLSVariant, fragmented: Bool) async -> (TwitchAdPlaylist, String)? {
    if let candidate = alternative,
      TwitchBackupSelection.compatible(candidate, with: variant),
      let playlist = await cleanPlaylist(candidate, fragmented: fragmented) {
      return (playlist, candidate.url.absoluteString)
    }
    alternative = nil
    guard !Task.isCancelled, Date() >= nextProbe else { return nil }
    nextProbe = Date().addingTimeInterval(5)
    // Failure in one playback context must not prevent trying the others.
    // Autoplay's Android grant often offers only 360p; prefer Source briefly.
    return await withTaskGroup(of: (TwitchAdPlaylist, HLSVariant)?.self) { group in
      for context in ["site", "popout", "mobile_web", "embed", "autoplay"] {
        group.addTask {
          do {
            if context == "autoplay" { try await Task.sleep(for: .milliseconds(600)) }
            let media = try await self.resolver.twitchAlternative(self.source, playerType: context)
            let candidates = TwitchBackupSelection.ranked(media.variants ?? [], for: variant)
            for candidate in candidates.prefix(3) {
              try Task.checkCancellation()
              if let playlist = await self.cleanPlaylist(candidate, fragmented: fragmented) {
                return (playlist, candidate)
              }
            }
          } catch { }
          return nil
        }
      }
      while let result = await group.next() {
        if let (playlist, candidate) = result, !Task.isCancelled {
          alternative = candidate
          group.cancelAll()
          return (playlist, candidate.url.absoluteString)
        }
      }
      return nil
    }
  }
  private func cleanPlaylist(_ candidate: HLSVariant, fragmented: Bool) async -> TwitchAdPlaylist? {
    do {
      let (text, base) = try await fetch(candidate.url)
      guard let playlist = TwitchAdPlaylist(absolute(text, base: base, localPlaylists: false))?.cleanSuffix,
        !playlist.segments.contains(where: { $0.encrypted }),
        playlist.segments.allSatisfy({ ($0.map != nil) == fragmented }) else { return nil }
      return playlist
    } catch { return nil }
  }
  func stop() {
    for work in inFlight.values { work.cancel() }
    inFlight.removeAll(); network.invalidateAndCancel()
  }
  func waitForClean() async -> Bool {
    while let url = blocked.first {
      do { try Task.checkCancellation(); try await Task.sleep(for: .seconds(2)) }
      catch { return false }
      let result = await response(path: paths[url]!)
      if result.0 != 200 && result.0 != 503 { blocked.remove(url); return false }
    }
    return !Task.isCancelled
  }
  deinit { network.invalidateAndCancel() }
}
