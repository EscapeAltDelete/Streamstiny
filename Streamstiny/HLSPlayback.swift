import AVFoundation
import AVKit
@preconcurrency import KSPlayer
import UIKit

@MainActor final class HLSPlayback: NSObject, MediaPlayerDelegate {
  let engine: KSMEPlayer
  private var ticking: Task<Void, Never>?
  private var changed: (() -> Void)?
  private var wantsPlayback: Bool
  private var processorMonitor: AudioOutputMonitor?
  private var nextAudioRecovery = 0.0
  private(set) var error: Error?

  init(
    url: URL, variant: HLSVariant?, headers: [String: String], provider: StreamSource.Provider, playing: Bool, changed: @escaping () -> Void
  ) {
    let options = HLSOptions(url: url, variant: variant, headers: headers, provider: provider, playing: playing)
    engine = KSMEPlayer(url: url, options: options)
    wantsPlayback = playing
    self.changed = changed
    super.init()
    engine.delegate = self
    engine.contentMode = .scaleAspectFit
  }

  func replace(url: URL, variant: HLSVariant?, headers: [String: String], provider: StreamSource.Provider, playing: Bool) {
    processorMonitor = nil
    error = nil
    wantsPlayback = playing
    let options = HLSOptions(url: url, variant: variant, headers: headers, provider: provider, playing: playing)
    engine.replace(url: url, options: options)
    start()
  }

  func start() {
    engine.prepareToPlay()
    startTicking()
  }

  private func startTicking() {
    guard wantsPlayback, ticking == nil else { return }
    ticking = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard let self else { return }
        self.checkAudioOutput()
        self.changed?()
      }
    }
  }

  func play() {
    wantsPlayback = true
    startTicking()
    if engine.isReadyToPlay { engine.play() }
    changed?()
  }

  func pause() {
    wantsPlayback = false
    ticking?.cancel()
    ticking = nil
    engine.pause()
    changed?()
  }

  func setRate(_ rate: Float) {
    guard engine.playbackRate != rate else { return }
    resetAudio(rate: rate)
  }

  private func resetAudio(rate: Float) {
    guard let audio = engine.audioOutput as? AudioEnginePlayer else {
      engine.playbackRate = rate
      return
    }
    // The device report shows non-finite pitch output persisting across rate changes.
    // Stop rendering before clearing DSP history, including the downstream mixer.
    let resume = audio.engine.isRunning
    audio.pause()
    audio.engine.reset()
    engine.playbackRate = rate
    _ = processorMonitor?.takeInvalidOutput()
    nextAudioRecovery = ProcessInfo.processInfo.systemUptime + 1
    if resume { audio.play() }
  }

  private func checkAudioOutput() {
    guard wantsPlayback, engine.isPlaying else { return }
    attachAudioMonitor()
    guard engine.loadState == .playable,
      ProcessInfo.processInfo.systemUptime >= nextAudioRecovery,
      processorMonitor?.takeInvalidOutput() == true else { return }
    resetAudio(rate: engine.playbackRate)
  }

  private func attachAudioMonitor() {
    guard processorMonitor == nil, engine.isReadyToPlay,
      let audio = engine.audioOutput as? AudioEnginePlayer,
      let pitch = audio.engine.attachedNodes.first(where: { $0 is AVAudioUnitTimePitch }) else { return }
    processorMonitor = AudioOutputMonitor(node: pitch)
  }

  func stop() {
    ticking?.cancel()
    ticking = nil
    changed = nil
    processorMonitor = nil
    engine.delegate = nil
    engine.pipController?.stopPictureInPicture()
    engine.shutdown()
  }

  deinit { ticking?.cancel() }

  func readyToPlay(player: some MediaPlayerProtocol) {
    attachAudioMonitor()
    if wantsPlayback { engine.play() }
    changed?()
  }

  func changeLoadState(player: some MediaPlayerProtocol) { changed?() }
  func changeBuffering(player: some MediaPlayerProtocol, progress: Int) { changed?() }
  func playBack(player: some MediaPlayerProtocol, loopCount: Int) { changed?() }
  func finish(player: some MediaPlayerProtocol, error: Error?) {
    self.error = error
    ticking?.cancel()
    ticking = nil
    changed?()
  }
}

private final class HLSOptions: KSOptions {
  private let variant: HLSVariant?
  init(url: URL, variant: HLSVariant?, headers: [String: String], provider: StreamSource.Provider, playing: Bool) {
    self.variant = variant
    super.init()
    userAgent = headers["User-Agent"] ?? PlaybackResolver.userAgent
    appendHeader(headers)
    let lowLatency = provider == .twitch && UserDefaults.standard.bool(forKey: "twitchLowLatency")
    preferredForwardBufferDuration = !lowLatency && url.host == "127.0.0.1" ? 2 : 0.1
    if lowLatency { formatContextOptions["live_start_index"] = -2 }
    if lowLatency || provider == .youtube {
      formatContextOptions["analyzeduration"] = 500_000
    }
    isSeekedAutoPlay = playing
    maxBufferDuration = 20
    hardwareDecode = true
    videoAdaptable = variant == nil
    registerRemoteControll = false
    canStartPictureInPictureAutomaticallyFromInline = true
  }

  override func wantedVideo(tracks: [MediaPlayerTrack]) -> Int? {
    guard let variant, variant.externalMedia else { return nil }
    return tracks.enumerated().compactMap { index, track -> (index: Int, pixels: Int64, fps: Float, bitRate: Int64)? in
      guard let format = track.formatDescription else { return nil }
      let size = CMVideoFormatDescriptionGetDimensions(format)
      guard variant.isSource || (Int(size.width) <= variant.width && Int(size.height) <= variant.height) else { return nil }
      return (index, Int64(size.width) * Int64(size.height), track.nominalFrameRate, track.bitRate)
    }.max {
      if $0.pixels != $1.pixels { return $0.pixels < $1.pixels }
      if $0.fps != $1.fps { return $0.fps < $1.fps }
      return $0.bitRate < $1.bitRate
    }?.index
  }
}
