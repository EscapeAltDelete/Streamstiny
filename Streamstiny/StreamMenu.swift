import SwiftUI
import UIKit

struct StreamMenu: UIViewRepresentable {
  let library: StreamLibrary
  let controls: PlaybackControls
  let addStream: () -> Void

  func makeUIView(context: Context) -> StreamMenuButton {
    let button = StreamMenuButton(type: .system)
    button.setImage(UIImage(systemName: "line.3.horizontal"), for: .normal)
    button.tintColor = .white
    button.accessibilityLabel = "Choose stream"
    button.showsMenuAsPrimaryAction = true
    return button
  }

  func updateUIView(_ button: StreamMenuButton, context: Context) {
    button.presented = { controls.menuPresented = $0 }
    guard !controls.menuPresented else { return }
    let directory = library.directory
    let sameEntries = button.directory.elementsEqual(directory) {
      $0.source == $1.source && $0.name == $1.name
    }
    guard button.currentSource != library.selected || !sameEntries else { return }
    button.currentSource = library.selected
    button.directory = directory
    let entries: [UIMenuElement] = directory.filter { $0.id != library.selected.id }.map { item in
      UIAction(
        title: item.name, subtitle: item.source.provider.rawValue, image: UIImage(systemName: "play.rectangle")
      ) { _ in
        library.select(item.source)
      }
    }
    let current = UIAction(title: library.selected.title, image: UIImage(systemName: "play.fill"), state: .on) { _ in }
    let add = UIAction(title: "Add stream", image: UIImage(systemName: "plus")) { _ in addStream() }
    button.menu = UIMenu(children: [
      UIMenu(title: "Now playing", options: .displayInline, children: [current]),
      UIMenu(title: "Live streams", options: .displayInline, children: entries),
      UIMenu(options: .displayInline, children: [add]),
    ])
  }

  static func dismantleUIView(_ button: StreamMenuButton, coordinator: ()) {
    button.presented?(false)
    button.presented = nil
    button.menu = nil
  }
}

final class StreamMenuButton: UIButton {
  var presented: ((Bool) -> Void)?
  var currentSource: StreamSource?
  var directory: [DirectoryItem] = []
  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
    presented?(true)
  }
  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willEndFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
    if let animator {
      animator.addCompletion { [weak self] in self?.presented?(false) }
    } else {
      presented?(false)
    }
  }
}
