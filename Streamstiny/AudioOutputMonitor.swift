import AVFoundation
@preconcurrency import KSPlayer

// Production recovery for non-finite speed-processor output; no recording or reports.
final class AudioOutputMonitor: @unchecked Sendable {
  private let node: AVAudioNode
  private let lock = NSLock()
  private var invalid = false

  init?(node: AVAudioNode) {
    guard node.numberOfOutputs > 0 else { return nil }
    let format = node.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0,
      format.commonFormat == .pcmFormatFloat32 else { return nil }
    self.node = node
    node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
      guard let self, buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { return }
      let count = Int(buffer.frameLength)
      for index in 0..<min(16, count) {
        if !samples[index * max(1, count / 16) * buffer.stride].isFinite {
          lock.lock()
          invalid = true
          lock.unlock()
          break
        }
      }
    }
  }
  deinit { node.removeTap(onBus: 0) }
  func takeInvalidOutput() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let result = invalid
    invalid = false
    return result
  }
}

// Suppress playback-library logging in the distributed app.
struct SilentPlaybackLog: LogHandler {
  func log(level: LogLevel, message: CustomStringConvertible, file: String, function: String, line: UInt) {}
}
