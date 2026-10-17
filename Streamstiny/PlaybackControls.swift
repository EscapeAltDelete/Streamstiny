import Foundation
import Observation

@MainActor @Observable final class PlaybackControls {
  private(set) var visible = false
  var settingsPresented = false {
    didSet { if settingsPresented { show() } else { arm() } }
  }
  var menuPresented = false {
    didSet { if menuPresented { show() } else { arm() } }
  }
  private var beforeFirstTap = false
  private var timer: Task<Void, Never>?
  private let timeout: Duration = .seconds(3)

  func tap(count: Int, doubleTapEnabled: Bool = true, toggleChat: () -> Void) {
    if count % 2 == 1 || !doubleTapEnabled {
      beforeFirstTap = visible
      visible.toggle()
    } else {
      visible = beforeFirstTap
      toggleChat()
    }
    arm()
  }

  func show() {
    visible = true
    arm()
  }

  func cancel() {
    timer?.cancel()
    timer = nil
  }

  private func arm() {
    cancel()
    guard visible, !settingsPresented, !menuPresented else { return }
    let timeout = timeout
    timer = Task { [weak self] in
      do { try await Task.sleep(for: timeout) } catch { return }
      guard !Task.isCancelled else { return }
      self?.visible = false
      self?.timer = nil
    }
  }
}
