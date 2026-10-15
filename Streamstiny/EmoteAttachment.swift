import UIKit

final class EmoteAttachment: NSTextAttachment {
  let emote: UIImage
  init(_ image: UIImage) {
    emote = image
    super.init(data: nil, ofType: nil)
    self.image = UIImage()
    allowsTextAttachmentView = false
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// TextKit determines wrapping and glyph positions; native image views animate only those glyphs.
final class ChatTextView: UITextView {
  private var emotes: [Int: EmoteImageView] = [:]
  private var attachments: [(NSRange, EmoteAttachment)] = []
  init() {
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: .zero)
    storage.addLayoutManager(manager)
    manager.addTextContainer(container)
    super.init(frame: .zero, textContainer: container)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  override var attributedText: NSAttributedString! {
    didSet {
      var next: [Int: EmoteImageView] = [:]
      attachments.removeAll(keepingCapacity: true)
      if let text = attributedText {
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) {
          value, range, _ in
          guard let attachment = value as? EmoteAttachment else { return }
          self.attachments.append((range, attachment))
          let previous = self.emotes[range.location]
          let view: EmoteImageView
          if let previous, previous.asset === attachment.emote {
            view = previous
          } else {
            view = EmoteImageView(image: attachment.emote)
          }
          next[range.location] = view
          if view.superview !== self { self.addSubview(view) }
          view.enabled = !UserDefaults.standard.bool(forKey: "disableEmoteAnimations")
        }
      }
      for (location, view) in emotes where next[location] !== view {
        view.stopAnimating()
        view.removeFromSuperview()
      }
      emotes = next
      setNeedsLayout()
    }
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    guard !attachments.isEmpty else { return }
    layoutManager.ensureLayout(for: textContainer)
    for (range, attachment) in attachments {
      let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
      emotes[range.location]?.frame = CGRect(
        x: rect.minX + textContainerInset.left, y: rect.minY + textContainerInset.top,
        width: attachment.bounds.width, height: attachment.bounds.height)
    }
  }
}

final class EmoteImageView: UIImageView {
  let asset: UIImage?
  var enabled = true { didSet { updateAnimation() } }
  override init(image: UIImage?) {
    asset = image
    super.init(image: image?.images?.first ?? image)
    isUserInteractionEnabled = false
    animationImages = image?.images
    animationDuration = image?.duration ?? 0
    contentMode = .scaleAspectFit
    if animationImages != nil { EmoteAnimationRegistry.shared.add(self) }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateAnimation()
  }
  fileprivate func updateAnimation() {
    var ancestor = superview
    var displayed = true
    while let parent = ancestor {
      if let cell = parent as? ChatCell {
        displayed = cell.emotesActive
        break
      }
      ancestor = parent.superview
    }
    if enabled, displayed, window != nil, UIApplication.shared.applicationState == .active,
      !UIAccessibility.isReduceMotionEnabled,
      !UserDefaults.standard.bool(forKey: "disableEmoteAnimations"), animationImages != nil
    {
      if !isAnimating { startAnimating() }
    } else {
      if isAnimating { stopAnimating() }
    }
  }

}

// A single set of observers serves all animated emotes. Static images need none.
@MainActor private final class EmoteAnimationRegistry {
  static let shared = EmoteAnimationRegistry()
  private let views = NSHashTable<EmoteImageView>.weakObjects()
  private var notifications: NotificationTokens?
  private init() {
    let tokens = [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification,
      UIAccessibility.reduceMotionStatusDidChangeNotification].map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated {
          for view in self?.views.allObjects ?? [] { view.updateAnimation() }
        }
      }
    }
    notifications = NotificationTokens(tokens)
  }
  func add(_ view: EmoteImageView) { views.add(view) }
}

private final class NotificationTokens: @unchecked Sendable {
  let values: [NSObjectProtocol]
  init(_ values: [NSObjectProtocol]) { self.values = values }
  deinit { for value in values { NotificationCenter.default.removeObserver(value) } }
}
