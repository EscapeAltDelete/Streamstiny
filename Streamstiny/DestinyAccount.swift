import Foundation
import SwiftUI
import WebKit

// Only Destiny.gg cookies are retained, in device-only Keychain storage.
enum DestinyAccount {
  private static let service = "gg.streamstiny.session"
  static var hasSession: Bool { !cookies.isEmpty }
  static var cookies: [HTTPCookie] {
    guard let encoded = TokenStore.read(service: service), let data = Data(base64Encoded: encoded),
      let records = try? JSONDecoder().decode([SavedCookie].self, from: data) else { return [] }
    return records.compactMap { $0.cookie }
  }
  static func header(for url: URL) -> String? {
    guard url.scheme == "https" || url.scheme == "wss",
      let host = url.host, ["www.destiny.gg", "destiny.gg", "chat.destiny.gg"].contains(host)
    else { return nil }
    let eligible = cookies.filter { cookie in
      // The chat server authenticates the same website sid, although the
      // website issues it for www.destiny.gg rather than its chat subdomain.
      if host == "chat.destiny.gg" { return cookie.name == "sid" }
      let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
      return host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))
    }
    return eligible.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: eligible)["Cookie"]
  }
  static func save(_ incoming: [HTTPCookie]) throws {
    let records = incoming.filter {
      ["sid", "rememberme"].contains($0.name)
        && ["destiny.gg", ".destiny.gg", "www.destiny.gg", ".www.destiny.gg"].contains($0.domain.lowercased())
        && ($0.expiresDate == nil || $0.expiresDate! > Date())
    }.map(SavedCookie.init)
    guard records.contains(where: { $0.name == "sid" }) else {
      throw ChatInputError.invalidCommand("Finish signing in to Destiny.gg before linking your account.")
    }
    try TokenStore.save(try JSONEncoder().encode(records).base64EncodedString(), service: service)
  }
  static func signOut() throws {
    try TokenStore.save("", service: service)
    UserDefaults.standard.removeObject(forKey: "destinyLogin")
  }
  static func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
    guard path.hasPrefix("/api/"), !path.hasPrefix("//"),
      let url = URL(string: "https://www.destiny.gg" + path), url.host == "www.destiny.gg"
    else { throw SourceError.invalid }
    let config = URLSessionConfiguration.ephemeral
    let originalSession = TokenStore.read(service: service)
    let storage = config.httpCookieStorage
    for cookie in cookies { storage?.setCookie(cookie) }
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.httpMethod = method
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(PlaybackResolver.userAgent, forHTTPHeaderField: "User-Agent")
    if method != "GET" {
      request.setValue("YEE", forHTTPHeaderField: "X-CSRF-Guard")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("https://www.destiny.gg", forHTTPHeaderField: "Origin")
    }
    let (data, response) = try await session.data(for: request)
    guard TokenStore.read(service: service) == originalSession else { throw CancellationError() }
    guard let response = response as? HTTPURLResponse,
      response.url?.host == "www.destiny.gg", response.url?.path.hasPrefix("/api/") == true,
      (response.statusCode == 200 || response.statusCode == 204), data.count <= 2 * 1024 * 1024
    else { throw ChatInputError.invalidCommand("Destiny.gg could not complete this request. Check your website sign-in.") }
    // Keep rotated session cookies; do not persist unrelated provider cookies.
    if hasSession { try save(storage?.cookies ?? cookies) }
    return data
  }
  private struct SavedCookie: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Date?
    init(_ cookie: HTTPCookie) {
      name = cookie.name; value = cookie.value; domain = cookie.domain
      path = cookie.path; expires = cookie.expiresDate
    }
    var cookie: HTTPCookie? {
      guard ["sid", "rememberme"].contains(name),
        ["destiny.gg", ".destiny.gg", "www.destiny.gg", ".www.destiny.gg"].contains(domain),
        expires == nil || expires! > Date() else { return nil }
      var properties: [HTTPCookiePropertyKey: Any] = [
        .name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE",
      ]
      if let expires { properties[.expires] = expires }
      return HTTPCookie(properties: properties)
    }
  }
}

struct DestinyLoginView: View {
  let chat: ChatStore
  @Environment(\.dismiss) private var dismiss
  @State private var browser = WKWebView(frame: .zero, configuration: {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    return config
  }())
  @State private var linking = false
  @State private var error: String?
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        DestinyLoginBrowser(browser: browser) { Task { await link(automatic: true) } }
        if let error { Text(error).font(.caption).foregroundStyle(.red).padding() }
        Button(linking ? "Checking sign-in…" : "Use this account") { Task { await link() } }
          .buttonStyle(.borderedProminent).disabled(linking).padding()
      }
      .navigationTitle("Destiny.gg sign-in").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
  }
  @MainActor private func link(automatic: Bool = false) async {
    guard !linking else { return }
    linking = true
    defer { linking = false }
    do {
      guard browser.url?.host == "www.destiny.gg" else { throw ChatInputError.loginRequired }
      // Validate inside the browser that actually completed OAuth, preserving
      // its cookies and browser challenge state.
      let value = try await browser.callAsyncJavaScript("""
        const response = await fetch('/api/chat/me', {credentials: 'include'});
        if (!response.ok) return null;
        return await response.json();
        """, arguments: [:], in: nil, contentWorld: .page)
      guard let payload = value as? [String: Any], !ChatUser(payload).nick.isEmpty else {
        throw ChatInputError.loginRequired
      }
      try DestinyAccount.save(await browser.configuration.websiteDataStore.httpCookieStore.allCookies())
      UserDefaults.standard.set(ChatUser(payload).nick, forKey: "destinyLogin")
      await chat.restart()
      dismiss()
    } catch { if !automatic { self.error = error.localizedDescription } }
  }
}

private struct DestinyLoginBrowser: UIViewRepresentable {
  let browser: WKWebView
  let completed: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(completed: completed) }
  func makeUIView(context: Context) -> WKWebView {
    browser.navigationDelegate = context.coordinator
    browser.uiDelegate = context.coordinator
    browser.customUserAgent = TwitchResolver.userAgent
    browser.load(URLRequest(url: URL(string: "https://www.destiny.gg/login")!))
    return browser
  }
  func updateUIView(_ view: WKWebView, context: Context) {}
  static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
  }
  @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let completed: () -> Void
    init(completed: @escaping () -> Void) { self.completed = completed }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      if webView.url?.host == "www.destiny.gg" { completed() }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
      decisionHandler(navigationAction.request.url?.scheme == "https" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
      if navigationAction.request.url?.scheme == "https" { webView.load(navigationAction.request) }
      return nil
    }
  }
}
