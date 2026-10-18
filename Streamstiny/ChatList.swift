import SwiftUI
import WebKit

struct ChatList: UIViewRepresentable {
  let messages: [ChatMessage]
  let emotes: EmoteStore
  let fontSize: Double
  let timestamps: Bool
  let onReply: (String) -> Void
  let onWhisper: (String) -> Void
  let onIgnore: (String) -> Void
  let onStream: (StreamSource) -> Void
  var chat: ChatStore? = nil
  var stateRevision = 0
  var backgroundColor: UIColor = .systemBackground
  var watchingFocus = false

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
  func updateUIView(_ view: WKWebView, context: Context) {
    view.scrollView.backgroundColor = backgroundColor
    context.coordinator.parent = self
    context.coordinator.refresh()
  }
  static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }

  @MainActor final class Coordinator: ChatWebCoordinator {
    var parent: ChatList
    private var records: [String: ChatMessage] = [:]
    private var rendered: [String: [String: Any]] = [:]
    private var inputs: [String: Input] = [:]
    private var ids: [String] = []
    private var sending = false
    private var pending = false
    private var revealed: Set<String> = []
    private let formatter = DateFormatter()
    private let announcement = UIImage(systemName: "megaphone.fill")?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal).pngData()?.base64EncodedString()
    private struct Input: Equatable {
      let message: ChatMessage
      let user: ChatUser
      let tag: String?
      let tagColor: String?
      let highlighted: Bool
      let spotlight: Bool
      let faded: Bool
      let options: String
    }
    init(_ parent: ChatList) { self.parent = parent; super.init(emotes: parent.emotes) }
    override func reset() { records.removeAll(); rendered.removeAll(); inputs.removeAll(); ids = []; sending = false; pending = false }
    override func refresh() {
      guard ready else { return }
      if sending { pending = true; return }
      let defaults = UserDefaults.standard
      let rules = ChatPreferences.textRules
      let format = defaults.string(forKey: "chatTimestampFormat") ?? "HH:mm"
      if formatter.dateFormat != format { formatter.dateFormat = format }
      let options = "\(emotes.catalogRevision):\(parent.timestamps):\(format):\(ChatPreferences.removedMessages):\(rules.configuration):\(defaults.bool(forKey: "previewChatImages")):\(defaults.bool(forKey: "highlightChatTags"))"
      var updates: [[String: Any]] = []
      let nextIDs = parent.messages.map(\.id)
      let retained = Set(nextIDs)
      revealed.formIntersection(retained)
      for message in parent.messages {
        let user = parent.chat?.users[message.nick.lowercased()] ?? message.user
        let highlighted = parent.chat?.isHighlighted(message, rules: rules) ?? rules.highlighted(message.text)
        let input = Input(message: message, user: user, tag: parent.chat?.tags[user.id], tagColor: parent.chat?.tagColors[user.id],
          highlighted: highlighted, spotlight: parent.chat.map { !$0.spotlights.isEmpty && $0.spotlights[message.spotlightIdentity] != nil } ?? false,
          faded: parent.watchingFocus && message.kind == "MSG" && !message.whisper && !highlighted && parent.chat?.isWatchingSame(message) != true,
          options: options)
        if inputs[message.id] != input || rendered[message.id] == nil {
          let record = render(input, rules: rules)
          inputs[message.id] = input; rendered[message.id] = record; updates.append(record)
        }
      }
      records = Dictionary(parent.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
      rendered = rendered.filter { retained.contains($0.key) }; inputs = inputs.filter { retained.contains($0.key) }
      var payload = commonPayload(mode: "chat")
      payload["records"] = updates
      payload["fontSize"] = UIFontMetrics.default.scaledValue(for: CGFloat(parent.fontSize))
      if ids != nextIDs { payload["ids"] = nextIDs; ids = nextIDs }
      sending = true
      call("update", arguments: ["payload": payload]) { [weak self] in
        guard let self else { return }
        sending = false
        if pending { pending = false; refresh() }
      }
    }
    private func render(_ input: Input, rules: ChatTextRules) -> [String: Any] {
      let message = input.message, user = input.user
      let hidden = message.removed && ChatPreferences.removedMessages == 1 && !revealed.contains(message.id)
      let action = !hidden && message.text.hasPrefix("/me ")
      var body = hidden ? "[message deleted · long press to reveal]" : rules.censored(action ? String(message.text.dropFirst(4)) : message.text)
      let sensitive = rules.sensitive(message.text)
      if sensitive {
        for match in ChatLinks.matches(in: body).reversed() {
          if let range = Range(match.range, in: body) { body.replaceSubrange(range, with: "[link hidden]") }
        }
      }
      var html = ""
      html += "<time class=\"time\" data-unixtimestamp=\"" + String(format: "%.0f", message.timestamp) + "\"" + (parent.timestamps ? "" : " hidden") + ">"
        + ChatHTML.escape(formatter.string(from: Date(timeIntervalSince1970: message.timestamp / 1000))) + "</time> "
      let badges = user.features.compactMap { name in emotes.flairs.first { $0.name == name } }
      html += "<span class=\"features\">" + badges.map(ChatHTML.flair).joined() + "</span> "
      let color = emotes.flairs.first { user.features.contains($0.name) && ($0.rainbowColor == true || $0.color?.isEmpty == false) }
      let tagColors = ["green":"#34c759", "yellow":"#ffcc00", "orange":"#ff9500", "red":"#ff3b30", "purple":"#af52de", "blue":"#007aff", "sky":"#32ade6", "lime":"#00c7be", "pink":"#ff2d55", "black":"CanvasText"]
      let tagColor = input.tagColor.flatMap { tagColors[$0] }
      let title = message.heading ?? message.nick
      if message.kind == "BROADCAST", message.heading == "Announcement", let announcement {
        html += "<img class=\"announcement\" alt=\"\" src=\"data:image/png;base64," + announcement + "\"> "
      }
      html += "<a class=\"user " + ChatHTML.escape(color?.name ?? "") + "\""
        + (tagColor.map { " style=\"color:" + $0 + ";background-image:none\"" } ?? "")
        + ">" + ChatHTML.escape(title) + "</a><span class=\"ctrl\">" + (action ? " " : message.whisper ? " whispered: " : ": ") + "</span>"
      if let tag = input.tag, !tag.isEmpty { html += "<span class=\"tag\">[" + ChatHTML.escape(tag) + "]</span>" }
      html += "<span class=\"text\">" + ChatHTML.body(body, links: !hidden && !sensitive) { word in
        emotes.canUse(word, user: user) && !hidden ? emotes.catalog[word] : nil
      } + "</span>"
      if sensitive && !hidden { html += " <span class=\"time\">[sensitive links hidden]</span>" }
      if !hidden, !sensitive, UserDefaults.standard.bool(forKey: "previewChatImages"),
        let url = ChatLinks.matches(in: message.text).first(where: { ["png", "jpg", "jpeg", "gif", "webp"].contains($0.url.pathExtension.lowercased()) })?.url,
        let proxy = ChatAssetConfiguration.proxied(url) {
        html += "<img class=\"preview not-visible\" width=\"200\" height=\"120\" alt=\"Image preview\" data-resource=\"" + ChatHTML.escape(proxy.absoluteString) + "\">"
      }
      if message.comboNicks.count > 1 { html += " <span class=\"combo\"></span>" }
      let combo = message.comboNicks.count
      let group = [50, 30, 20, 10, 5, 2].first { combo >= $0 } ?? 2
      let classes = "msg-chat " + (combo > 1 ? "msg-emote" : "msg-user") + (action ? " action msg-me" : "") + (message.whisper ? " msg-whisper" : "") + (message.removed ? " removed" : "") + (body.hasPrefix(">") ? " green" : "") + " " + user.features.map(ChatHTML.escape).joined(separator: " ")
      let background = message.kind == "PIN" ? "transparent"
        : UserDefaults.standard.bool(forKey: "highlightChatTags") && tagColor != nil ? "color-mix(in srgb," + tagColor! + " 12%,transparent)"
        : input.highlighted ? "rgba(255,204,0,.12)" : input.spotlight ? "rgba(255,149,0,.15)" : message.heading != nil ? "rgba(128,128,128,.1)" : ""
      return ["id": message.id, "html": html, "classes": classes, "username": user.id, "faded": input.faded,
        "background": background, "combo": combo, "comboGroup": "x\(group)", "accessibility": "\(title): \(hidden ? "Message deleted" : message.text)"]
    }
    override func handle(_ request: [String: Any]) {
      if request["action"] as? String == "link", let address = request["url"] as? String,
        let url = URL(string: address), ["https", "http"].contains(url.scheme) { open(url) }
      if request["action"] as? String == "profile", let id = request["id"] as? String,
        let message = records[id] { parent.chat?.requestedProfile = parent.chat?.users[message.nick.lowercased()] ?? message.user }
    }
    override func actions(_ request: [String: Any]) -> [UIMenuElement] {
      guard let id = request["id"] as? String, let message = records[id] else { return [] }
      return actions(message)
    }
    private func open(_ url: URL) {
      if let source = ChatLinks.stream(at: url) { parent.onStream(source) } else { UIApplication.shared.open(url) }
    }
    private func actions(_ message: ChatMessage) -> [UIMenuElement] {
      var actions: [UIMenuElement] = [
        UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) {
          [weak self] _ in
          self?.parent.onReply(message.nick)
        },
        UIAction(title: "Whisper", image: UIImage(systemName: "envelope")) { [weak self] _ in
          self?.parent.onWhisper(message.nick)
        },
        UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
          UIPasteboard.general.string = message.text
        },
        UIAction(title: "Ignore user", image: UIImage(systemName: "person.slash")) {
          [weak self] _ in
          self?.parent.onIgnore(message.nick)
        },
      ]
      if message.removed {
        actions.insert(UIAction(title: revealed.contains(message.id) ? "Hide deleted text" : "Reveal deleted text", image: UIImage(systemName: "eye")) { [weak self] _ in
          guard let self else { return }
          if revealed.contains(message.id) { revealed.remove(message.id) } else { revealed.insert(message.id) }
          rendered.removeValue(forKey: message.id)
          refresh()
        }, at: 0)
      }
      if let chat = parent.chat {
        actions.append(UIAction(title: "Profile and badges", image: UIImage(systemName: "person.crop.circle")) { _ in
          chat.requestedProfile = chat.users[message.nick.lowercased()] ?? message.user
        })
        actions.append(UIAction(title: chat.highlighted.contains(message.nick.lowercased()) ? "Remove highlight" : "Highlight user",
          image: UIImage(systemName: "highlighter")) { _ in
          chat.highlight(message.nick, enabled: !chat.highlighted.contains(message.nick.lowercased()))
        })
        if chat.account?.moderator == true {
          let key = message.spotlightIdentity
          let spotlighted = chat.spotlights[key] != nil
          actions.append(UIAction(title: spotlighted ? "Remove spotlight" : "Spotlight message", image: UIImage(systemName: "sparkles")) { _ in
            Task {
              do {
                try await chat.transmit(spotlighted ? "UNSPOTLIGHT" : "SPOTLIGHT", spotlighted
                  ? ["data": key] : ["nick": message.nick, "messageTimestamp": message.timestamp, "data": message.text])
              } catch { chat.error = error.localizedDescription }
            }
          })
          actions.append(UIAction(title: "Pin message", image: UIImage(systemName: "pin")) { _ in
            Task { _ = await chat.send("/pin " + message.text) }
          })
          actions.append(UIAction(title: "Mute for 10 minutes", image: UIImage(systemName: "speaker.slash")) { _ in
            Task { _ = await chat.send("/mute " + message.nick + " 10m") }
          })
        }
      }
      let links = ChatPreferences.sensitive(message.text) ? [] : ChatLinks.matches(in: message.text)
      if !links.isEmpty {
        for match in links {
          if let source = try? StreamSource.parse(match.url.absoluteString), source.provider != .direct {
            actions.append(UIAction(title: "Watch in Streamstiny", image: UIImage(systemName: "play.rectangle")) { [weak self] _ in self?.parent.onStream(source) })
          }
        }
      }
      actions += links.map { match in
        UIAction(
          title: "Open \(ChatLinks.stream(at: match.url)?.title ?? match.url.host ?? "link")",
          image: UIImage(systemName: "link")
        ) { [weak self] _ in self?.open(match.url) }
      }
      return actions
    }
  }
}
