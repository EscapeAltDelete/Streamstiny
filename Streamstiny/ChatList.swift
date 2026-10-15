import SwiftUI
import UIKit

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
  func makeUIView(context: Context) -> UITableView {
    let table = ChatTableView(frame: .zero, style: .plain)
    table.backgroundColor = backgroundColor
    table.separatorStyle = .none
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 60
    table.selfSizingInvalidation = .enabledIncludingConstraints
    table.contentInsetAdjustmentBehavior = .never
    table.keyboardDismissMode = .interactive
    table.register(ChatCell.self, forCellReuseIdentifier: "message")
    table.delegate = context.coordinator
    table.willResize = { [weak coordinator = context.coordinator] table in coordinator?.willResize(table) }
    table.didResize = { [weak coordinator = context.coordinator] table in coordinator?.didResize(table) }
    table.didLayout = { [weak coordinator = context.coordinator] table in coordinator?.didLayout(table) }
    context.coordinator.dataSource = UITableViewDiffableDataSource<Int, String>(tableView: table) {
      [weak coordinator = context.coordinator] table, index, id in
      guard let coordinator, let message = coordinator.records[id],
        let cell = table.dequeueReusableCell(withIdentifier: "message", for: index) as? ChatCell
      else { return UITableViewCell() }
      coordinator.configure(cell, message: message)
      return cell
    }
    return table
  }
  func updateUIView(_ table: UITableView, context: Context) {
    context.coordinator.update(self, table: table)
  }

  @MainActor final class Coordinator: NSObject, UITableViewDelegate, UITextViewDelegate {
    var parent: ChatList
    var records: [String: ChatMessage] = [:]
    var dataSource: UITableViewDiffableDataSource<Int, String>!
    private var revision = -1
    private var appearanceRevision = 0
    private static func appearanceRevision(_ list: ChatList) -> Int {
      var hasher = Hasher()
      hasher.combine(list.stateRevision)
      hasher.combine(list.watchingFocus)
      hasher.combine(ChatPreferences.removedMessages)
      hasher.combine(list.chat?.identity)
      hasher.combine(list.chat?.highlighted)
      hasher.combine(list.chat?.spotlights.keys.sorted())
      hasher.combine(UserDefaults.standard.bool(forKey: "hideFlairIcons"))
      hasher.combine(UserDefaults.standard.bool(forKey: "disableEmoteAnimations"))
      hasher.combine(UserDefaults.standard.bool(forKey: "disableMentionHighlight"))
      hasher.combine(UserDefaults.standard.string(forKey: "chatTimestampFormat"))
      for key in ["customChatHighlights", "hideNSFWLinks", "hideNSFLLinks", "censorChatWords", "censoredChatWords", "previewChatImages", "highlightChatTags"] {
        hasher.combine(UserDefaults.standard.object(forKey: key).map { String(describing: $0) })
      }
      if let tags = list.chat?.tags {
        for key in tags.keys.sorted() { hasher.combine(key); hasher.combine(tags[key]) }
      }
      return hasher.finalize()
    }
    private weak var table: UITableView?
    private var applying = false
    private var restoring = false
    private var pending: ChatList?
    private var followingLatest = true
    private var measuredHeights: [String: CGFloat] = [:]
    private var contentSizeCategory: UIContentSizeCategory?
    private struct Position {
      let visible: [(id: String, offset: CGFloat)]
      let previous: [String]
    }
    private var resizePosition: Position?
    private var initialized = false
    private var revealed: Set<String> = []
    private let timestampFormatter = DateFormatter()
    private static let tokens = try? NSRegularExpression(pattern: #"\S+|\s+"#)
    init(_ parent: ChatList) { self.parent = parent }

    private func position(in table: UITableView) -> Position {
      Position(visible: (table.indexPathsForVisibleRows ?? []).sorted().compactMap { path in
        dataSource.itemIdentifier(for: path).map { ($0, table.rectForRow(at: path).minY - table.contentOffset.y) }
      }, previous: dataSource.snapshot().itemIdentifiers)
    }
    private func restore(_ position: Position, in table: UITableView) {
      guard !table.isDragging, !table.isDecelerating else { return }
      restoring = true
      defer { restoring = false }
      let minimum = -table.adjustedContentInset.top
      let maximum = max(minimum, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
      let desired: CGFloat
      if followingLatest { desired = maximum }
      else if let id = ChatScrollAnchor.surviving(visible: position.visible.map(\.id),
        previous: position.previous, current: Set(dataSource.snapshot().itemIdentifiers)),
        let path = dataSource.indexPath(for: id) {
        desired = table.rectForRow(at: path).minY - (position.visible.first { $0.id == id }?.offset ?? 0)
      } else { desired = table.contentOffset.y }
      let offset = min(maximum, max(minimum, desired))
      if abs(table.contentOffset.y - offset) > 0.5 {
        table.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
      }
    }
    func willResize(_ table: UITableView) {
      guard initialized, !restoring else { return }
      resizePosition = position(in: table)
      measuredHeights.removeAll(keepingCapacity: true)
    }
    func didResize(_ table: UITableView) {
      if let position = resizePosition { resizePosition = nil; restore(position, in: table) }
    }
    func didLayout(_ table: UITableView) {
      guard initialized, followingLatest, !applying, !restoring, resizePosition == nil else { return }
      restore(Position(visible: [], previous: []), in: table)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      guard !restoring, scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking else { return }
      followingLatest = scrollView.contentSize.height - scrollView.bounds.height
        + scrollView.adjustedContentInset.bottom - scrollView.contentOffset.y <= 60
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { scrollViewDidScroll(scrollView) }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate { flushPending() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { flushPending() }
    private func flushPending() {
      guard !applying, let table, !table.isDragging, !table.isDecelerating, let next = pending else { return }
      pending = nil
      update(next, table: table)
    }
    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
      dataSource.itemIdentifier(for: indexPath).flatMap { measuredHeights[$0] } ?? 60
    }
    func update(_ next: ChatList, table: UITableView) {
      self.table = table
      // Never mutate a snapshot beneath an active gesture or another application.
      // Retain only the latest state, including filters and growing emote combos.
      if applying || table.isDragging || table.isDecelerating { pending = next; return }
      table.backgroundColor = next.backgroundColor
      let changed = !initialized || parent.messages != next.messages
      let fontChanged = parent.fontSize != next.fontSize
        || contentSizeCategory != table.traitCollection.preferredContentSizeCategory
      let appearance = Self.appearanceRevision(next)
      let appearanceChanged = revision != next.emotes.revision || fontChanged
        || parent.timestamps != next.timestamps || appearanceRevision != appearance
      guard changed || appearanceChanged else { parent = next; return }
      let anchor = position(in: table)
      parent = next
      revision = next.emotes.revision
      appearanceRevision = appearance
      contentSizeCategory = table.traitCollection.preferredContentSizeCategory
      if fontChanged { measuredHeights.removeAll(keepingCapacity: true) }
      initialized = true
      let modified = next.messages.filter { message in records[message.id].map { $0 != message } == true }.map(\.id)
      var snapshot: NSDiffableDataSourceSnapshot<Int, String>
      if changed {
        let ids = Set(next.messages.map(\.id))
        revealed.formIntersection(ids)
        measuredHeights = measuredHeights.filter { ids.contains($0.key) }
        records = Dictionary(next.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(next.messages.map(\.id))
      } else { snapshot = dataSource.snapshot() }
      var refresh = Set(modified)
      if appearanceChanged {
        refresh.formUnion((table.indexPathsForVisibleRows ?? []).compactMap {
          dataSource.itemIdentifier(for: $0)
        }.filter { records[$0] != nil })
      }
      if !refresh.isEmpty { snapshot.reconfigureItems(Array(refresh)) }
      applying = true
      dataSource.apply(snapshot, animatingDifferences: false) { [weak self, weak table] in
        guard let self, let table else { return }
        table.layoutIfNeeded()
        // followingLatest may have changed since the snapshot began applying.
        self.restore(anchor, in: table)
        self.applying = false
        self.flushPending()
      }
    }

    func configure(_ cell: ChatCell, message: ChatMessage) {
      let rules = ChatPreferences.textRules
      let sensitive = rules.sensitive(message.text)
      let size = CGFloat(parent.fontSize)
      let font = UIFontMetrics.default.scaledFont(for: UIFont.systemFont(ofSize: size))
      let text = NSMutableAttributedString(string: "")
      if parent.timestamps {
        let date = Date(timeIntervalSince1970: message.timestamp / 1000)
        let format = UserDefaults.standard.string(forKey: "chatTimestampFormat") ?? "HH:mm"
        if timestampFormatter.dateFormat != format { timestampFormatter.dateFormat = format }
        text.append(
          NSAttributedString(
            string: timestampFormatter.string(from: date) + " ",
            attributes: [
              .font: UIFontMetrics.default.scaledFont(for: UIFont.systemFont(ofSize: size - 3)),
              .foregroundColor: UIColor.secondaryLabel,
            ]))
      }
      let user = parent.chat?.users[message.nick.lowercased()] ?? message.user
      let tagged = parent.chat?.tagColors[message.nick.lowercased()]
      let tagColor: UIColor? = tagged.flatMap { ["green": UIColor.systemGreen, "yellow": .systemYellow, "orange": .systemOrange, "red": .systemRed, "purple": .systemPurple, "blue": .systemBlue, "sky": .systemCyan, "lime": .systemMint, "pink": .systemPink, "black": .label][$0] }
      let color = tagColor ?? parent.emotes.usernameColor(features: user.features)
        ?? (user.moderator ? UIColor.systemGreen : message.features.contains("subscriber") ? .systemPurple : .systemBlue)
      if !UserDefaults.standard.bool(forKey: "hideFlairIcons") {
        for flair in ChatFlair.visible(in: parent.emotes.flairs, features: user.features) {
          let attachment = NSTextAttachment()
          attachment.image = parent.emotes.image(for: "flair:" + flair.name) ?? UIImage()
          guard let dimensions = flair.image?.first, let badgeWidth = dimensions.width,
            let badgeHeight = dimensions.height else { continue }
          let metrics = UIFontMetrics.default
          let width = metrics.scaledValue(for: CGFloat(badgeWidth))
          let height = metrics.scaledValue(for: CGFloat(badgeHeight))
          attachment.bounds = CGRect(x: 0, y: (font.capHeight - height) / 2, width: width, height: height)
          text.append(NSAttributedString(attachment: attachment))
          text.append(NSAttributedString(string: " "))
        }
      }
      if message.kind == "BROADCAST", message.heading == "Announcement",
        let image = UIImage(systemName: "megaphone.fill")?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal) {
        let attachment = NSTextAttachment(); attachment.image = image
        attachment.bounds = CGRect(x: 0, y: 0, width: font.lineHeight, height: font.lineHeight)
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: " "))
      }
      let nameFont = UIFontMetrics.default.scaledFont(for: UIFont.boldSystemFont(ofSize: size))
      if message.heading == nil, !message.whisper,
        let image = parent.emotes.rainbowName(message.nick, features: user.features, font: nameFont) {
        let attachment = EmoteAttachment(image)
        attachment.bounds = CGRect(x: 0, y: font.descender, width: image.size.width, height: image.size.height)
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: "  ", attributes: [.font: font]))
      } else {
        text.append(NSAttributedString(string: (message.heading ?? ((message.whisper ? "Whisper · " : "") + message.nick)) + "  ",
          attributes: [.font: nameFont, .foregroundColor: color]))
      }
      if let tag = parent.chat?.tags[message.nick.lowercased()], !tag.isEmpty {
        text.append(NSAttributedString(string: "[\(tag)] ", attributes: [.font: font, .foregroundColor: color]))
      }
      let hidden = message.removed && ChatPreferences.removedMessages == 1 && !revealed.contains(message.id)
      let action = !hidden && message.text.hasPrefix("/me ")
      var body = hidden ? "[message deleted · long press to reveal]" : rules.censored(action ? String(message.text.dropFirst(4)) : message.text)
      if sensitive {
        for match in ChatLinks.matches(in: body).reversed() {
          if let range = Range(match.range, in: body) { body.replaceSubrange(range, with: "[link hidden]") }
        }
      }
      let bodyFont =
        action ? UIFontMetrics.default.scaledFont(for: UIFont.italicSystemFont(ofSize: size)) : font
      let bodyColor: UIColor = message.removed ? .secondaryLabel : body.hasPrefix(">") ? .systemGreen : .label
      var lineHeight = font.lineHeight
      let words =
        Self.tokens?.matches(in: body, range: NSRange(body.startIndex..., in: body))
        .compactMap { Range($0.range, in: body).map { String(body[$0]) } } ?? [body]
      for word in words {
        if parent.emotes.canUse(word, user: user) {
          let attachment = EmoteAttachment(parent.emotes.image(for: word) ?? UIImage())
          let size = parent.emotes.displaySize(for: word, lineHeight: font.lineHeight)
          lineHeight = max(lineHeight, size.height)
          attachment.bounds = CGRect(
            x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
          let emote = NSMutableAttributedString(attachment: attachment)
          emote.addAttribute(
            .font, value: bodyFont, range: NSRange(location: 0, length: emote.length))
          text.append(emote)
        } else {
          text.append(
            NSAttributedString(
              string: word, attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
        }
      }
      if !hidden && !sensitive {
        for match in ChatLinks.matches(in: text.string) {
          text.addAttribute(.link, value: match.url, range: match.range)
        }
      } else if !hidden {
        text.append(NSAttributedString(string: " [sensitive links hidden]", attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
      }
      if !hidden, !sensitive, UserDefaults.standard.bool(forKey: "previewChatImages"),
        let url = ChatLinks.matches(in: message.text).first(where: { ["png", "jpg", "jpeg", "gif", "webp"].contains($0.url.pathExtension.lowercased()) })?.url {
        let image = parent.emotes.preview(url)
        let attachment = EmoteAttachment(image?.images?.first ?? image ?? UIImage(systemName: "photo") ?? UIImage())
        attachment.bounds = CGRect(x: 0, y: 0, width: 200, height: 120)
        text.append(NSAttributedString(string: "\n"))
        text.append(NSAttributedString(attachment: attachment))
      }
      if message.comboNicks.count > 1 {
        text.append(NSAttributedString(string: "  \(message.comboNicks.count)× combo",
          attributes: [.font: font, .foregroundColor: UIColor.systemOrange]))
      }
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight = lineHeight + 2
      paragraph.lineSpacing = 2
      text.addAttribute(
        .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
      cell.messageText.delegate = self
      cell.messageText.attributedText = text
      let highlighted = parent.chat?.isHighlighted(message, rules: rules) ?? rules.highlighted(message.text)
      cell.contentView.alpha = parent.watchingFocus && message.kind == "MSG" && !message.whisper && !highlighted
        && parent.chat?.isWatchingSame(message) != true ? 0.3 : 1
      cell.backgroundColor = message.kind == "PIN" ? .clear
        : UserDefaults.standard.bool(forKey: "highlightChatTags") && tagColor != nil ? tagColor!.withAlphaComponent(0.12) : highlighted ? UIColor.systemYellow.withAlphaComponent(0.12)
        : parent.chat?.spotlights[message.spotlightIdentity] != nil ? UIColor.systemOrange.withAlphaComponent(0.15)
        : message.heading != nil ? UIColor.secondarySystemBackground : .clear
      cell.menu = { [weak self] in self?.actions(message) ?? [] }
      cell.accessibilityLabel = "\(message.heading ?? message.nick): \(hidden ? "Message deleted" : message.text)"
      cell.accessibilityHint = "Long press for reply, whisper, copy, ignore, and link actions."
    }
    func tableView(
      _ tableView: UITableView, willDisplay cell: UITableViewCell,
      forRowAt indexPath: IndexPath
    ) {
      if let id = dataSource.itemIdentifier(for: indexPath), cell.bounds.height > 0 {
        measuredHeights[id] = cell.bounds.height
      }
      (cell as? ChatCell)?.animateEmotes(true)
    }
    func tableView(
      _ tableView: UITableView, didEndDisplaying cell: UITableViewCell,
      forRowAt indexPath: IndexPath
    ) { (cell as? ChatCell)?.animateEmotes(false) }

    func textView(
      _ textView: UITextView, primaryActionFor textItem: UITextItem,
      defaultAction: UIAction
    ) -> UIAction? {
      guard case .link(let url) = textItem.content else { return defaultAction }
      return UIAction { [weak self] _ in self?.open(url) }
    }
    func textView(
      _ textView: UITextView, editMenuForTextIn range: NSRange,
      suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
      UIMenu(
        children: suggestedActions + ((textView.superview?.superview as? ChatCell)?.menu?() ?? []))
    }
    private func open(_ url: URL) {
      if let source = ChatLinks.stream(at: url) {
        parent.onStream(source)
      } else {
        UIApplication.shared.open(url)
      }
    }
    func tableView(
      _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
      point: CGPoint
    ) -> UIContextMenuConfiguration? {
      guard let id = dataSource.itemIdentifier(for: indexPath), let message = records[id] else {
        return nil
      }
      return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
        UIMenu(children: self?.actions(message) ?? [])
      }
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
          appearanceRevision = .min
          if let table { update(parent, table: table) }
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

// Preserve the reading position when rotation or the keyboard changes the viewport.
final class ChatTableView: UITableView {
  var willResize: ((UITableView) -> Void)?
  var didResize: ((UITableView) -> Void)?
  var didLayout: ((UITableView) -> Void)?
  private var previousSize: CGSize = .zero
  private var layingOut = false
  override func layoutSubviews() {
    guard !layingOut else { super.layoutSubviews(); return }
    layingOut = true
    defer { layingOut = false }
    let changed = previousSize != bounds.size
    if changed { willResize?(self); previousSize = bounds.size }
    super.layoutSubviews()
    if changed { didResize?(self) }
    didLayout?(self)
  }
}

final class ChatCell: UITableViewCell {
  let messageText = ChatTextView()
  var menu: (() -> [UIMenuElement])?
  private(set) var emotesActive = false
  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    messageText.isEditable = false
    messageText.isScrollEnabled = false
    messageText.backgroundColor = .clear
    messageText.textContainerInset = .zero
    messageText.textContainer.lineFragmentPadding = 0
    messageText.linkTextAttributes = [.foregroundColor: UIColor.link]

    messageText.adjustsFontForContentSizeCategory = true
    messageText.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(messageText)
    NSLayoutConstraint.activate([
      messageText.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
      messageText.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
      messageText.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
      messageText.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
    ])
  }
  func animateEmotes(_ playing: Bool) {
    emotesActive = playing
    func visit(_ view: UIView) {
      (view as? EmoteImageView)?.enabled = playing
      for child in view.subviews { visit(child) }
    }
    visit(messageText)
  }
  override func prepareForReuse() {
    super.prepareForReuse()
    animateEmotes(false)
    messageText.attributedText = nil
    menu = nil
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
