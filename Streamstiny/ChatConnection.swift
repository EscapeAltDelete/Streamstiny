import Foundation

actor DestinySocket {
  private var socket: URLSessionWebSocketTask?
  private let session: URLSession
  private let url: URL

  init(url: URL = URL(string: "wss://chat.destiny.gg/ws")!) {
    self.url = url
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.httpCookieStorage = nil
    session = URLSession(configuration: config)
  }

  deinit { session.invalidateAndCancel() }

  func connect() {
    socket?.cancel(with: .goingAway, reason: nil)
    var request = URLRequest(url: url)
    request.httpShouldHandleCookies = false
    request.setValue("https://www.destiny.gg", forHTTPHeaderField: "Origin")
    if url.host == "chat.destiny.gg" {
      request.setValue(DestinyAccount.header(for: url), forHTTPHeaderField: "Cookie")
    }
    let task = session.webSocketTask(with: request)
    socket = task
    task.resume()
  }

  func receive() async throws -> ChatEvent {
    let frame = try await receiveText()
    return (try? ChatProtocol.decode(frame)) ?? .other
  }

  func receiveDirectory() async throws -> DirectoryEvent {
    let frame = try await receiveText()
    return (try? DirectoryEvent.decode(frame)) ?? .other
  }

  private func receiveText() async throws -> String {
    guard let socket else { throw ChatInputError.disconnected }
    let message = try await socket.receive()
    let text: String
    switch message {
    case .string(let value): text = value
    case .data(let value): text = String(decoding: value, as: UTF8.self)
    @unknown default: return ""
    }
    return text
  }

  func send(_ frame: String) async throws {
    guard let socket else { throw ChatInputError.disconnected }
    try await socket.send(.string(frame))
  }

  func disconnect() {
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
  }
}
