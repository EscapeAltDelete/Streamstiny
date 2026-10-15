import Foundation
import Observation
import SwiftUI
import WebKit

struct TwitchCredentials: Sendable {
  let token: String?
  let deviceID: String
  let integrity: String?
  var clientID: String = TwitchResolver.clientID
}

@MainActor @Observable final class TwitchAccount {
  static let shared = TwitchAccount()
  private static let service = "gg.streamstiny.twitch"
  private(set) var login: String?
  private(set) var linked: Bool
  private(set) var message: String?
  private var token: String?
  private var proof: (value: String, expires: Date)?
  private var deviceID: String
  private var generation = 0
  private var authorization: Task<TwitchCredentials?, Never>?
  private let websiteData = WKWebsiteDataStore.nonPersistent()

  private init() {
    let storedToken = TokenStore.read(service: Self.service)
    token = storedToken
    linked = storedToken != nil
    login = UserDefaults.standard.string(forKey: "twitchLogin")
    deviceID = UserDefaults.standard.string(forKey: "twitchDeviceID")
      ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    UserDefaults.standard.set(deviceID, forKey: "twitchDeviceID")
  }

  func credentials() -> TwitchCredentials {
    TwitchCredentials(token: token, deviceID: deviceID,
      integrity: proof.flatMap { $0.expires > Date().addingTimeInterval(30) ? $0.value : nil },
      clientID: token == nil ? TwitchResolver.clientID : (UserDefaults.standard.string(forKey: "twitchClientID") ?? TwitchResolver.clientID))
  }
  fileprivate func loginFailed(_ description: String) { message = description }

  func link(_ candidate: String, device: String?) async -> Bool {
    guard (20...256).contains(candidate.count), candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
      message = "Twitch did not return a valid sign-in token."; return false
    }
    let version = generation
    do {
      var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
      request.timeoutInterval = 15
      request.setValue("OAuth " + candidate, forHTTPHeaderField: "Authorization")
      let configuration = URLSessionConfiguration.ephemeral
      let session = URLSession(configuration: configuration)
      defer { session.invalidateAndCancel() }
      let (bytes, response) = try await session.data(for: request)
      try Task.checkCancellation()
      guard generation == version else { return false }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard status == 200 else { throw PlaybackFailure.http(status) }
      guard bytes.count <= 64 * 1024,
        let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        let clientID = json["client_id"] as? String, !clientID.isEmpty,
        let name = json["login"] as? String, !name.isEmpty
      else { throw TwitchFailure.signIn }
      try TokenStore.save(candidate, service: Self.service)
      generation += 1
      authorization?.cancel()
      authorization = nil
      proof = nil
      token = candidate
      if let device, !device.isEmpty {
        deviceID = device
        UserDefaults.standard.set(device, forKey: "twitchDeviceID")
      }
      linked = true
      login = name
      UserDefaults.standard.set(clientID, forKey: "twitchClientID")
      UserDefaults.standard.set(name, forKey: "twitchLogin")
      message = nil
      NotificationCenter.default.post(name: .twitchAccountChanged, object: nil)
      return true
    } catch is CancellationError { return false } catch {
      if generation == version { message = "Couldn’t link Twitch: " + error.localizedDescription }
      return false
    }
  }

  func signOut() async {
    do {
      try TokenStore.save("", service: Self.service)
      generation += 1
      authorization?.cancel()
      authorization = nil
      proof = nil
      token = nil
      login = nil
      linked = false
      UserDefaults.standard.removeObject(forKey: "twitchLogin")
      message = nil
      await websiteData.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
      NotificationCenter.default.post(name: .twitchAccountChanged, object: nil)
    } catch { message = error.localizedDescription }
  }

  func invalidate(_ expired: String?) async {
    guard token == expired else { return }
    // Guest playback can continue after expiration; never discard a newer login.
    do {
      try TokenStore.save("", service: Self.service)
      generation += 1
      authorization?.cancel()
      authorization = nil
      token = nil
      proof = nil
      login = nil
      linked = false
      UserDefaults.standard.removeObject(forKey: "twitchLogin")
      message = "Your Twitch session expired. Sign in again to restore account benefits."
      await websiteData.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    } catch { message = error.localizedDescription }
  }

  func refreshIntegrity() async -> TwitchCredentials? {
    if let authorization { return await authorization.value }
    let version = generation
    let work = Task { @MainActor [weak self] () -> TwitchCredentials? in
      guard let self else { return nil }
      let browser = TwitchAuthorization(dataStore: websiteData, credentials: credentials())
      let result = await browser.run()
      guard generation == version, !Task.isCancelled else { return nil }
      guard let result else {
        message = "Twitch could not authorize playback. Sign out and sign back in under Accounts."
        return nil
      }
      proof = (result.value, result.expires)
      deviceID = result.deviceID
      UserDefaults.standard.set(deviceID, forKey: "twitchDeviceID")
      message = nil
      return credentials()
    }
    authorization = work
    let result = await work.value
    if generation == version {
      authorization = nil
    }
    return result
  }

  fileprivate static func restoreCookies(_ credentials: TwitchCredentials, in store: WKWebsiteDataStore) async {
    var values = ["unique_id": credentials.deviceID]
    if let token = credentials.token { values["auth-token"] = token }
    for (name, value) in values {
      if let cookie = HTTPCookie(properties: [
        .domain: ".twitch.tv", .path: "/", .name: name, .value: value, .secure: "TRUE",
      ]) { await store.httpCookieStore.setCookie(cookie) }
    }
  }
}

extension Notification.Name {
  static let twitchAccountChanged = Notification.Name("StreamstinyTwitchAccountChanged")
}

// Short-lived browser authorization only. No website video is used for playback.
@MainActor private final class TwitchAuthorization: NSObject, WKNavigationDelegate {
  struct Proof { let value: String; let expires: Date; let deviceID: String }
  private let dataStore: WKWebsiteDataStore
  private let credentials: TwitchCredentials
  private var webView: WKWebView?
  private var continuation: CheckedContinuation<Proof?, Never>?
  private var timeout: Task<Void, Never>?
  private var request: Task<Void, Never>?
  init(dataStore: WKWebsiteDataStore, credentials: TwitchCredentials) {
    self.dataStore = dataStore
    self.credentials = credentials
  }

  func run() async -> Proof? {
    await TwitchAccount.restoreCookies(credentials, in: dataStore)
    guard !Task.isCancelled else { return nil }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.customUserAgent = TwitchResolver.userAgent
        browser.navigationDelegate = self
        webView = browser
        timeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(25)) } catch { return }
          self?.finish(nil)
        }
        browser.load(URLRequest(url: URL(string: "https://www.twitch.tv/directory")!))
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(nil) }
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard request == nil, continuation != nil else { return }
    request = Task { [weak self, weak webView] in
      do {
        try await Task.sleep(for: .seconds(2))
        guard let self, let webView, !Task.isCancelled else { return }
        let script = """
          const controller = new AbortController();
          const timer = setTimeout(() => controller.abort(), 10000);
          try {
            const deviceId = (document.cookie.match(/(?:^|; )unique_id=([^;]+)/) || [])[1] || device;
            const headers = {'Client-ID': client, 'X-Device-Id': deviceId};
            if (auth) headers['Authorization'] = 'OAuth ' + auth;
            const response = await fetch('https://gql.twitch.tv/integrity', {
              method: 'POST', headers, signal: controller.signal
            });
            if (!response.ok) return null;
            const result = await response.json();
            return {token: result.token, expiration: result.expiration, deviceId};
          } finally { clearTimeout(timer); }
          """
        let value = try await webView.callAsyncJavaScript(script,
          arguments: ["client": credentials.clientID, "auth": credentials.token ?? "", "device": credentials.deviceID],
          in: nil, contentWorld: .page)
        guard !Task.isCancelled, let json = value as? [String: Any],
          let token = json["token"] as? String, !token.isEmpty,
          let expiry = json["expiration"] as? Double, expiry.isFinite,
          let device = json["deviceId"] as? String, !device.isEmpty
        else { finish(nil); return }
        let date = Date(timeIntervalSince1970: expiry / 1000)
        finish(date > Date() ? Proof(value: token, expires: date, deviceID: device) : nil)
      } catch { self?.finish(nil) }
    }
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(nil) }
  private func finish(_ result: Proof?) {
    let pending = continuation
    continuation = nil
    timeout?.cancel()
    timeout = nil
    request?.cancel()
    request = nil
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView = nil
    pending?.resume(returning: result)
  }
}

struct TwitchLoginView: View {
  let completed: () -> Void
  @State private var browser = WKWebView(frame: .zero, configuration: {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    return configuration
  }())
  @State private var checking = false
  var body: some View {
    VStack(spacing: 0) {
      TwitchLoginBrowser(browser: browser, completed: completed)
      if let message = TwitchAccount.shared.message { Text(message).font(.caption).padding(8) }
      Button(checking ? "Checking sign-in…" : "Use this account") {
        checking = true
        Task {
          defer { checking = false }
          let cookies = await browser.configuration.websiteDataStore.httpCookieStore.allCookies()
          guard let token = cookies.first(where: {
            $0.name == "auth-token" && [".twitch.tv", "twitch.tv", "www.twitch.tv", ".www.twitch.tv"].contains($0.domain.lowercased())
          })?.value else { TwitchAccount.shared.loginFailed("Complete the Twitch website sign-in first."); return }
          let device = cookies.first { $0.name == "unique_id" && [".twitch.tv", "twitch.tv", "www.twitch.tv", ".www.twitch.tv"].contains($0.domain.lowercased()) }?.value
          if await TwitchAccount.shared.link(token, device: device) { completed() }
        }
      }.buttonStyle(.borderedProminent).disabled(checking).padding(8)
    }
  }
}

private struct TwitchLoginBrowser: UIViewRepresentable {
  let browser: WKWebView
  let completed: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(completed: completed) }
  func makeUIView(context: Context) -> WKWebView {
    browser.customUserAgent = TwitchResolver.userAgent
    browser.navigationDelegate = context.coordinator
    browser.uiDelegate = context.coordinator
    browser.configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
    browser.load(URLRequest(url: URL(string: "https://www.twitch.tv/login")!))
    return browser
  }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
  static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
    coordinator.active = false
    coordinator.linking?.cancel()
    uiView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
    uiView.navigationDelegate = nil
    uiView.uiDelegate = nil
    uiView.stopLoading()
  }
  @MainActor final class Coordinator: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate, WKUIDelegate {
    let completed: () -> Void
    var active = true
    var linking: Task<Void, Never>?
    private var candidate: String?
    init(completed: @escaping () -> Void) { self.completed = completed }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
      guard linking == nil else { return }
      linking = Task { [weak self] in
        defer { self?.linking = nil }
        let cookies = await cookieStore.allCookies()
        guard let self, active, !Task.isCancelled,
          let token = cookies.first(where: {
            $0.name == "auth-token" && [".twitch.tv", "twitch.tv", "www.twitch.tv", ".www.twitch.tv"].contains($0.domain.lowercased())
          })?.value, token != candidate
        else { return }
        let device = cookies.first { $0.name == "unique_id" && [".twitch.tv", "twitch.tv", "www.twitch.tv", ".www.twitch.tv"].contains($0.domain.lowercased()) }?.value
        if await TwitchAccount.shared.link(token, device: device), active, !Task.isCancelled {
          candidate = token; completed()
        }
      }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      cookiesDidChange(in: webView.configuration.websiteDataStore.httpCookieStore)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
      if navigationAction.request.url?.scheme == "https" { webView.load(navigationAction.request) }
      return nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      if (error as NSError).code != NSURLErrorCancelled { TwitchAccount.shared.loginFailed(error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
      guard let url = navigationAction.request.url, url.scheme == "https"
      else { decisionHandler(.cancel); return }
      decisionHandler(.allow)
    }
  }
}
