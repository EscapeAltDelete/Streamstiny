import SwiftUI
import WebKit
import OSLog

@MainActor class ChatWebCoordinator: NSObject, WKScriptMessageHandler, WKURLSchemeHandler, WKNavigationDelegate, UIEditMenuInteractionDelegate {
  let emotes: EmoteStore
  weak var webView: WKWebView?
  private var downloads: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var editMenu: UIEditMenuInteraction?
  private var menuRequest: [String: Any] = [:]
  private var sentCatalog = -1
  private var sentManifest = -1
  private(set) var ready = false
  init(emotes: EmoteStore) { self.emotes = emotes }

  func makeWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(self, forURLScheme: "dgg-asset")
    configuration.userContentController.add(self, name: "chat")
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = self
    view.isOpaque = false
    view.backgroundColor = .clear
    view.scrollView.backgroundColor = .clear
    view.scrollView.contentInsetAdjustmentBehavior = .never
    view.scrollView.keyboardDismissMode = .interactive
    view.allowsLinkPreview = false
    let interaction = UIEditMenuInteraction(delegate: self)
    view.addInteraction(interaction); editMenu = interaction
    webView = view
    loadDocument()
    return view
  }
  func stop() {
    for task in downloads.values { task.cancel() }
    downloads.removeAll()
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "chat")
    webView?.stopLoading()
    ready = false
  }
  private func loadDocument() {
    ready = false; sentCatalog = -1; sentManifest = -1
    guard let url = Bundle.main.url(forResource: "ChatRenderer", withExtension: "js"),
      let script = try? String(contentsOf: url, encoding: .utf8) else {
      webView?.loadHTMLString("Chat renderer could not be loaded.", baseURL: nil)
      return
    }
    let nonce = UUID().uuidString
    let document = """
      <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src dgg-asset: data:; base-uri 'none'; form-action 'none';">
      <style>
      :root {color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,sans-serif;-webkit-text-size-adjust:100%;overflow-anchor:none}
      body {margin:0;font-size:16px;background:transparent;color:CanvasText}
      * {box-sizing:border-box} [hidden] {display:none!important}
      .msg-chat {position:relative;padding:6px 12px;line-height:1.65;overflow-wrap:anywhere;white-space:pre-wrap}
      .time {font-size:.8em;color:GrayText;margin-right:5px}
      .features {display:inline-flex;vertical-align:text-top;align-items:center;gap:3px}
      .flair {display:inline-block;flex-shrink:0;text-indent:-999em;overflow:hidden}
      .user {font-weight:600;color:#59aeea;text-decoration:none}
      .ctrl {white-space:pre} .action .text {font-style:italic}
      .announcement {width:1em;height:1em;vertical-align:middle} .removed .text {color:GrayText}
      .text {white-space:pre-wrap} .green .text {color:#38a34a}
      a[href] {color:LinkText} .tag {margin:0 4px;font-size:.85em}
      .emote {display:inline-block;position:relative;overflow:hidden;text-indent:-999em;white-space:nowrap}
      .not-visible,.not-visible::before,.not-visible::after {background-image:none!important;animation-play-state:paused!important}
      .paused .emote,.paused .emote::before,.paused .emote::after {animation-play-state:paused!important}
      .paused .user,.static-emotes .user {animation-play-state:paused!important}
      .static-emotes .emote,.static-emotes .emote::before,.static-emotes .emote::after {animation:none!important}
      .static-emotes .emote {background-image:none!important}
      .emote canvas {position:absolute;left:0;top:0;text-indent:0}
      .hide-badges .features {display:none}
      .missing-asset {background-image:none!important;text-indent:0!important;color:GrayText;min-width:1em;overflow:visible!important;width:auto!important}
      .missing-asset,.missing-asset::before,.missing-asset::after {background-image:none!important;animation-play-state:paused!important}
      .combo {color:#eb942d;font-size:.85em} .preview {display:block;max-width:200px;max-height:120px;object-fit:contain}
      .picker {padding:8px} h2 {font-size:.8125em;font-weight:500;color:GrayText;margin:10px 4px}
      .emote-group {display:grid;grid-template-columns:repeat(auto-fill,minmax(90px,1fr));gap:4px}
      .emote-item {display:flex;min-width:0;height:78px;align-items:center;justify-content:center;flex-direction:column;gap:6px;background:none;border:0;color:inherit;-webkit-touch-callout:none}
      .emote-item:disabled {opacity:.5} .emote-label {font-size:.75em;max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .badges {font-size:.9375em} .badge-detail {padding:7px 0;display:flex;align-items:center;gap:10px}
      .badge-detail .description {font-size:.8em;color:GrayText;margin-top:3px}
      </style><style id="native-styles"></style></head><body><main id="content"></main>
      <script nonce="\(nonce)">\(script)</script></body></html>
      """
    webView?.loadHTMLString(document, baseURL: URL(string: "https://chat.streamstiny.invalid"))
  }
  func refresh() {}
  func reset() {}
  func handle(_ message: [String: Any]) {}
  func actions(_ message: [String: Any]) -> [UIMenuElement] { [] }
  func commonPayload(mode: String) -> [String: Any] {
    var payload: [String: Any] = ["mode": mode, "active": !emotes.suspended,
      "fontSize": UIFontMetrics.default.scaledValue(for: 16),
      "recovery": emotes.recoveryRevision,
      "account": ["animate": !UserDefaults.standard.bool(forKey: "disableEmoteAnimations")],
      "hideBadges": UserDefaults.standard.bool(forKey: "hideFlairIcons")]
    if sentCatalog != emotes.catalogRevision {
      sentCatalog = emotes.catalogRevision
      payload["stylesheet"] = emotes.stylesheet
    }
    if mode == "picker", sentManifest != emotes.catalogRevision {
      sentManifest = emotes.catalogRevision
      payload["manifest"] = emotes.snapshot?.emotes.map { item -> [String: Any] in
        ["prefix": item.prefix, "minimumSubTier": item.minimumSubTier, "patreonOnly": item.patreonOnly,
          "resource": item.image.first?.url.flatMap { ChatAssetConfiguration.proxied($0)?.absoluteString } ?? ""]
      } ?? []
    }
    return payload
  }
  func call(_ method: String, arguments: [String: Any], completion: (() -> Void)? = nil) {
    guard ready, let webView else { completion?(); return }
    let names: [String: [String]] = ["update": ["payload"], "assetFinished": ["url", "success"]]
    guard let parameters = names[method] else { completion?(); return }
    webView.callAsyncJavaScript("window.ChatRenderer.\(method)(\(parameters.joined(separator: ",")))", arguments: arguments, in: nil, in: .page) { result in
      if case .failure(let error) = result {
        Logger(subsystem: "gg.streamstiny.app", category: "Chat rendering").error("Renderer call failed: \(String(describing: error), privacy: .public)")
      }
      completion?()
    }
  }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
    if action == "ready" { ready = true; refresh() }
    else if action == "menu" {
      menuRequest = body
      guard !actions(body).isEmpty else { return }
      let point = CGPoint(x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0)
      editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    } else { handle(body) }
  }
  func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
    UIMenu(children: suggestedActions + actions(menuRequest))
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
    let url = navigationAction.request.url
    let ownDocument = navigationAction.navigationType == .other
      && (url?.absoluteString == "about:blank" || url?.host == "chat.streamstiny.invalid")
    decisionHandler(ownDocument ? .allow : .cancel)
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    for task in downloads.values { task.cancel() }
    downloads.removeAll(); reset(); loadDocument()
  }
  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let address = urlSchemeTask.request.url, let url = ChatAssetConfiguration.original(address) else {
      urlSchemeTask.didFailWithError(URLError(.unsupportedURL)); return
    }
    let id = ObjectIdentifier(urlSchemeTask)
    downloads[id] = Task { [weak self] in
      guard let self else { return }
      defer { downloads[id] = nil }
      do {
        let retry = URLComponents(url: address, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "__streamstiny_retry" } == true
        let value = try await emotes.assets.resource(url, cachePolicy: retry ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy)
        guard !Task.isCancelled, downloads[id] != nil else { return }
        urlSchemeTask.didReceive(URLResponse(url: address, mimeType: value.response.mimeType,
          expectedContentLength: value.data.count, textEncodingName: value.response.textEncodingName))
        urlSchemeTask.didReceive(value.data)
        urlSchemeTask.didFinish()
        call("assetFinished", arguments: ["url": url.absoluteString, "success": true])
      } catch {
        guard !Task.isCancelled, downloads[id] != nil else { return }
        urlSchemeTask.didFailWithError(error)
        call("assetFinished", arguments: ["url": url.absoluteString, "success": false])
      }
    }
  }
  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    downloads.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
  }
}

struct ChatAssetView: UIViewRepresentable {
  let emotes: EmoteStore
  let mode: String
  var account: ChatUser? = nil
  var search = ""
  var onInsert: (String) -> Void = { _ in }
  var onHeight: (CGFloat) -> Void = { _ in }
  // Reading these in the SwiftUI view tracks metadata/preferences, never image completion.
  let favorites: Set<String>
  let revision: Int
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> WKWebView {
    let view = context.coordinator.makeWebView()
    if mode == "badges" { view.scrollView.isScrollEnabled = false }
    return view
  }
  func updateUIView(_ uiView: WKWebView, context: Context) { context.coordinator.parent = self; context.coordinator.refresh() }
  static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { coordinator.stop() }
  @MainActor final class Coordinator: ChatWebCoordinator {
    var parent: ChatAssetView
    init(_ parent: ChatAssetView) { self.parent = parent; super.init(emotes: parent.emotes) }
    override func refresh() {
      guard ready else { return }
      var payload = commonPayload(mode: parent.mode)
      payload["favorites"] = Array(parent.favorites)
      payload["search"] = parent.search
      payload["account"] = ["tier": parent.account?.tier ?? 0, "patreonMember": parent.account?.patreonMember == true,
        "privileged": parent.account?.privileged == true, "animate": !UserDefaults.standard.bool(forKey: "disableEmoteAnimations")]
      if parent.mode == "badges" {
        payload["html"] = emotes.flairs.filter { parent.account?.features.contains($0.name) == true }.map { flair in
          "<div class=\"badge-detail\">" + ChatHTML.flair(flair) + "<div>" + ChatHTML.escape(flair.label)
            + "<div class=\"description\">" + ChatHTML.escape(flair.description ?? "") + "</div></div></div>"
        }.joined()
      }
      call("update", arguments: ["payload": payload])
    }
    override func handle(_ message: [String: Any]) {
      if message["action"] as? String == "insert", let name = message["name"] as? String,
        emotes.canUse(name, user: parent.account) { parent.onInsert(name) }
      if message["action"] as? String == "height", let height = message["height"] as? Double, height.isFinite {
        parent.onHeight(CGFloat(max(1, min(10000, height))))
      }
    }
    override func actions(_ message: [String: Any]) -> [UIMenuElement] {
      guard let name = message["name"] as? String, emotes.catalog[name] != nil else { return [] }
      return [UIAction(title: emotes.favorites.contains(name) ? "Remove favorite" : "Favorite", image: UIImage(systemName: "star")) { [weak self] _ in
        self?.emotes.favorite(name)
      }]
    }
  }
}
