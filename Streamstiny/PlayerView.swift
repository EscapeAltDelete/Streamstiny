import AVFoundation
import AVKit
import MediaPlayer
import Observation
@preconcurrency import Network
import SwiftUI

@MainActor @Observable final class NativePlayback: NSObject, AVPictureInPictureControllerDelegate {
  private(set) var hls: HLSPlayback?
  private(set) var title = ""
  private(set) var status: PlaybackStatus = .stopped
  var loading: Bool { status == .connecting }
  var buffering: Bool { status == .buffering || status == .recovering }
  var playing: Bool { status == .playing }
  var error: String? { status.error }
  private var pipelineFailed: Bool { hls?.finished == true }
  private(set) var variants: [HLSVariant] = []
  private(set) var qualityID: String?
  private(set) var edge: AngelEdge?
  private(set) var discovering = false
  private(set) var switching = false
  private(set) var settingsError: String?
  private(set) var resolution = ""
  private(set) var bitrate: StreamBitrate?
  private var reportsBitrate = false
  private var informationVisible = false
  private var nextBitrateCheck = 0.0
  @ObservationIgnored private var bitrateInput: StreamBitrate.Input?
  @ObservationIgnored private var bitrateTask: Task<Void, Never>?
  private(set) var frameRate: Float = 0
  private(set) var buffered = 0.0
  private(set) var waitingForAds = false
  private(set) var catchingUp = false
  private(set) var automaticallyCatchingUp = false
  private var automaticCatchUp = false
  private var targetBuffer = 3.0
  private var highestQuality = false
  private var nextBufferCheck = 0.0
  private(set) var playbackRate: Float = 0
  private struct NowPlayingState: Equatable {
    let title: String
    let rate: Float
  }
  private var nowPlayingState: NowPlayingState?
  private var previousDefaultRate: Float = 1
  private var media: PlaybackMedia?
  private var discovery: Task<Void, Never>?
  private var selection: Task<Void, Never>?
  private var selectionVersion = 0
  @ObservationIgnored private var stall: Task<Void, Never>?
  var supportsEdges: Bool {
    source?.provider == .angelthump
      && variants.contains {
        !$0.externalMedia && AngelEdge.amsterdam.replacingHost(in: $0.url) != nil
      }
  }
  private let resolver = PlaybackResolver()
  private var source: StreamSource?
  private var playlistGateway: PlaylistGateway?
  @ObservationIgnored private var retry: Task<Void, Never>?
  private var retryVersion = 0
  private var generation = 0
  private var failures = 0
  private var healthySince: Date?
  @ObservationIgnored private var network: NWPathMonitor?
  private var networkVersion = 0
  private var connectivity = PlaybackConnectivity()
  private var wantsPlayback = true
  private var commands: [PlaybackCommandTarget] = []

  deinit { network?.cancel(); retry?.cancel(); stall?.cancel(); bitrateTask?.cancel() }

  var pipActive: Bool { hls?.engine.pipController?.isPictureInPictureActive == true }

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (
      Bool
    ) -> Void
  ) {
    completionHandler(true)
  }
  func load(_ source: StreamSource, force: Bool = false, verifyEnd: Bool = false) async {
    guard force || self.source != source || hls == nil else {
      return
    }
    endCatchUp()
    setAutomaticCatchUp(false)
    generation += 1
    let version = generation
    selectionVersion += 1
    selection?.cancel()
    discovery?.cancel()
    discovering = false
    switching = false
    if !force {
      qualityID = nil
      edge = nil
      variants = []
      media = nil
      settingsError = nil
      resolution = ""
      buffered = 0
      stall?.cancel()
      stall = nil
      wantsPlayback = true
      failures = 0
      cancelRetry()
    }
    self.source = source
    if wantsPlayback { monitorNetwork() }
    title = source.title
    status = .connecting
    clearBitrate()
    frameRate = 0
    nextBitrateCheck = 0
    healthySince = nil
    if !force {
      hls?.pause()
      playlistGateway?.stop()
      playlistGateway = nil
    }
    do {
      let media = try await resolver.resolve(source)
      if verifyEnd, source.provider == .direct,
        try await resolver.ended(at: media.url, headers: media.headers) {
        guard version == generation, !Task.isCancelled else { return }
        streamEnded(); return
      }
      let preferred = variants.first { $0.id == qualityID }
      let starting = self.media == nil
      var choices = media.variants
      try Task.checkCancellation()
      guard version == generation else { return }
      if choices == nil, highestQuality || (force && qualityID != nil) {
        choices = try await resolver.variants(at: media.url)
        guard version == generation, !Task.isCancelled else { return }
      }
      if let choices { variants = choices }
      self.media = media
      var edgeURL: URL?
      var variant: HLSVariant?
      if highestQuality, !force || starting {
        variant = variants.first
        qualityID = variant?.id
      }
      if force, qualityID != nil {
        variant = variants.first { $0.id == qualityID }
          ?? preferred.flatMap { requested in variants.first {
            $0.width == requested.width && $0.height == requested.height
              && $0.frameRate.rounded() == requested.frameRate.rounded() && $0.externalMedia == requested.externalMedia
          } }
        qualityID = variant?.id
        if let edge, let variant,
          let verified = try? await resolver.verifiedEdge(edge, variant: variant)
        {
          edgeURL = verified
        } else if edge != nil {
          edge = nil
          settingsError = "That edge is unavailable. Using the provider’s default server."
        }
        guard version == generation, !Task.isCancelled else { return }
      }
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try AVAudioSession.sharedInstance().setActive(true)
      var gateway: PlaylistGateway?
      if source.provider == .twitch || source.provider == .kick,
        HLSLowLatency.enabled(for: source.provider) || (source.provider == .twitch && UserDefaults.standard.bool(forKey: "twitchAdBlocking")) {
        gateway = try await PlaylistGateway.start(source: source, variants: variants, resolver: resolver)
        guard version == generation, !Task.isCancelled else { gateway?.stop(); return }
      }
      let remoteURL = Self.playbackURL(master: media.url, variant: variant, edgeURL: edgeURL)
      let playbackURL = await gateway?.url(for: remoteURL) ?? remoteURL
      guard version == generation, !Task.isCancelled else { gateway?.stop(); return }
      installHLS(playbackURL, variant: variant)
      playlistGateway?.stop()
      playlistGateway = gateway
      if commands.isEmpty { configureRemoteCommands() }
      status = wantsPlayback ? .buffering : .paused
      stall?.cancel()
      stall = nil
      if variants.isEmpty, choices == nil { discover(media.url, version: version) }
      updateTime()
    } catch is CancellationError { if version == generation { status = .paused } }
    catch PlaybackFailure.offline {
      guard version == generation, !Task.isCancelled else { return }
      streamEnded()
    } catch {
      guard version == generation else { return }
      guard !Task.isCancelled else { status = .paused; return }
      if PlaybackStatus.recoverable(error) {
        status = .unavailable(error.localizedDescription)
        recoverFailure(verifyEnd: verifyEnd)
      } else { status = .failed(error.localizedDescription); hls?.pause(); stopNetworkMonitor() }
    }
  }
  static func playbackURL(master: URL, variant: HLSVariant?, edgeURL: URL?) -> URL {
    edgeURL ?? variant?.playbackURL(master: master) ?? master
  }

  private func installHLS(_ url: URL, variant: HLSVariant?) {
    guard let provider = source?.provider else { return }
    if let hls {
      hls.replace(url: url, variant: variant, headers: media?.headers ?? [:], provider: provider, playing: wantsPlayback)
      return
    }
    hls = HLSPlayback(url: url, variant: variant, headers: media?.headers ?? [:], provider: provider, playing: wantsPlayback) {
      [weak self] in
      self?.updateTime()
    }
    hls?.start()
  }

  private func discover(_ url: URL, version: Int) {
    discovering = true
    discovery = Task { [weak self] in
      guard let self else { return }
      do {
        let choices = try await resolver.variants(at: url)
        guard generation == version, !Task.isCancelled else { return }
        variants = choices
        selectPreferredQuality()
      } catch {
        guard generation == version, !Task.isCancelled else { return }
        settingsError = "Couldn’t load resolutions. Retry in playback settings."
      }
      discovering = false
    }
  }

  func configure(automatic: Bool, target: Double, highest: Bool, showBitrate: Bool = false) {
    let changedQuality = highest && !highestQuality
    automaticCatchUp = automatic
    targetBuffer = target.isFinite ? min(20, max(0, target)) : 3
    highestQuality = highest
    reportsBitrate = showBitrate
    if !showBitrate { clearBitrate() }
    nextBitrateCheck = 0
    nextBufferCheck = 0
    if changedQuality { selectPreferredQuality() }
    updateTime()
  }

  func setInformationVisible(_ visible: Bool) {
    informationVisible = visible
    nextBitrateCheck = 0
    if !visible { clearBitrate() }
    else { updateTime() }
  }

  private func selectPreferredQuality() {
    guard highestQuality, let best = variants.first, !loading, !switching else { return }
    chooseQuality(best.id, edge: edge)
  }

  private func adjustAutomaticCatchUp() {
    guard automaticCatchUp, wantsPlayback, playing, !loading, !switching,
      !catchingUp, error == nil, hls?.error == nil
    else {
      setAutomaticCatchUp(false)
      return
    }
    let now = ProcessInfo.processInfo.systemUptime
    guard now >= nextBufferCheck else { return }
    nextBufferCheck = now + 1
    if automaticallyCatchingUp {
      if buffered <= targetBuffer { setAutomaticCatchUp(false) }
    } else if buffered > targetBuffer + 1 {
      setAutomaticCatchUp(true)
    }
  }

  private func setAutomaticCatchUp(_ active: Bool) {
    guard automaticallyCatchingUp != active else { return }
    automaticallyCatchingUp = active
    let rate: Float = active ? 2 : 1
    hls?.setRate(rate)
    if playing { playbackRate = rate }
  }

  func retryChoices() {
    guard let media else { return }
    discovery?.cancel()
    settingsError = nil
    discover(media.url, version: generation)
  }

  func chooseQuality(_ id: String?, edge requestedEdge: AngelEdge? = nil) {
    guard !loading, let media else { return }
    guard id != qualityID || requestedEdge != edge else { return }
    let variant = variants.first { $0.id == id }
    guard id == nil || variant != nil else { return }
    cancelRetry()
    endCatchUp()
    setAutomaticCatchUp(false)
    selection?.cancel()
    selectionVersion += 1
    let change = selectionVersion
    let version = generation
    switching = true
    clearBitrate()
    nextBitrateCheck = 0
    settingsError = nil
    selection = Task { [weak self] in
      guard let self else { return }
      do {
        var edgeURL: URL?
        if let requestedEdge, let variant {
          edgeURL = try await resolver.verifiedEdge(requestedEdge, variant: variant)
        }
        guard generation == version, selectionVersion == change, !Task.isCancelled else { return }
        let remoteURL = Self.playbackURL(master: media.url, variant: variant, edgeURL: edgeURL)
        let playbackURL = await playlistGateway?.url(for: remoteURL) ?? remoteURL
        guard generation == version, selectionVersion == change, !Task.isCancelled else { return }
        installHLS(playbackURL, variant: variant)
        qualityID = id
        edge = requestedEdge
        failures = 0
        stall?.cancel()
        stall = nil
        guard generation == version, selectionVersion == change, !Task.isCancelled else { return }
        if wantsPlayback { hls?.play() }
      } catch {
        guard generation == version, selectionVersion == change, !Task.isCancelled else { return }
        settingsError = "That server didn’t return playable media. Your current stream was kept."
      }
      switching = false
      updateTime()
    }
  }

  func chooseEdge(_ edge: AngelEdge?) {
    if edge == nil {
      chooseQuality(qualityID)
      return
    }
    let variant = variants.first { $0.id == qualityID } ?? variants.first { !$0.externalMedia }
    guard let variant else { return }
    chooseQuality(variant.id, edge: edge)
  }

  func reload(resume: Bool = false) {
    guard let source else { return }
    if resume { wantsPlayback = true }
    failures = 0
    cancelRetry()
    let attempt = retryVersion
    retry = Task { [weak self] in
      defer { if let self, self.retryVersion == attempt { self.retry = nil } }
      guard let self else { return }
      await load(source, force: true)
      resumeRecovery(after: attempt)
    }
  }
  func toggle() {
    endCatchUp()
    wantsPlayback = !(playing || buffering)
    setPlayback(wantsPlayback)
    updateTime()
  }
  func stop() {
    stopNetworkMonitor()
    endCatchUp()
    setAutomaticCatchUp(false)
    generation += 1
    selectionVersion += 1
    discovery?.cancel()
    selection?.cancel()
    discovery = nil
    selection = nil
    discovering = false
    switching = false
    cancelRetry()
    stall?.cancel()
    stall = nil
    commands.removeAll()
    hls?.stop()
    hls = nil
    playlistGateway?.stop()
    playlistGateway = nil
    source = nil
    media = nil
    variants = []
    qualityID = nil
    edge = nil
    status = .stopped
    waitingForAds = false
    playbackRate = 0
    resolution = ""
    clearBitrate()
    buffered = 0
    frameRate = 0
    settingsError = nil
    title = ""
    wantsPlayback = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    nowPlayingState = nil
  }
  private func cancelRetry() {
    retryVersion += 1
    retry?.cancel()
    retry = nil
  }

  private func streamEnded() {
    stopNetworkMonitor()
    status = .ended
    clearBitrate()
    wantsPlayback = false
    endCatchUp()
    setAutomaticCatchUp(false)
    hls?.pause()
    cancelRetry()
    stall?.cancel()
    stall = nil
    playbackRate = 0
    updateNowPlaying()
  }

  private func recoverFailure(verifyEnd: Bool = false) {
    guard retry == nil, !loading, !switching, wantsPlayback, !Task.isCancelled else { return }
    healthySince = nil
    if waitingForAds, let gateway = playlistGateway, let source, let media {
      let version = generation
      retryVersion += 1
      let attempt = retryVersion
      retry = Task { [weak self] in
        defer { if let self, self.retryVersion == attempt { self.retry = nil } }
        let clean = await gateway.waitForClean()
        guard let self, generation == version, !Task.isCancelled else { return }
        if clean {
          let variant = variants.first { $0.id == self.qualityID }
          let url = await gateway.url(for: Self.playbackURL(master: media.url, variant: variant, edgeURL: nil))
          guard generation == version, !Task.isCancelled else { return }
          installHLS(url, variant: variant)
        } else { await load(source, force: true) }
        resumeRecovery(after: attempt)
      }
      return
    }
    guard PlaybackStatus.retryDelay(attempt: failures) != nil, let source else {
      status = .unavailable("Video playback is temporarily unavailable after refreshing its source. Retry to reconnect.")
      clearBitrate()
      hls?.pause()
      return
    }
    status = .recovering
    retryVersion += 1
    let attempt = retryVersion
    retry = Task { [weak self] in
      defer { if let self, self.retryVersion == attempt { self.retry = nil } }
      guard let self else { return }
      while let delay = PlaybackStatus.retryDelay(attempt: failures) {
        failures += 1
        status = .recovering
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        guard retryVersion == attempt, self.source == source, wantsPlayback, !Task.isCancelled else { return }
        await load(source, force: true, verifyEnd: verifyEnd)
        guard retryVersion == attempt, !Task.isCancelled else { return }
        if case .unavailable = status { continue }
        guard status.error == nil else { return }
        if pipelineFailed { continue }
        return
      }
      if status.error == nil { status = .unavailable("Video playback is temporarily unavailable after refreshing its source. Retry to reconnect.") }
      clearBitrate()
      hls?.pause()
    }
  }
  private func resumeRecovery(after attempt: Int) {
    guard retryVersion == attempt, !Task.isCancelled else { return }
    if case .unavailable = status { retry = nil; recoverFailure() }
    else if status.error == nil, pipelineFailed { retry = nil; recoverFailure(verifyEnd: true) }
  }
  private func updateTime() {
    guard status.error == nil else { return }
    waitingForAds = playlistGateway?.waiting ?? false
    if let hls {
      let engine = hls.engine
      if pipelineFailed {
        recoverFailure(verifyEnd: true)
        return
      }
      if !loading, retry == nil {
        status = !wantsPlayback ? .paused : engine.loadState != .playable ? .buffering : engine.isPlaying ? .playing : .paused
      }
      if playing {
        if healthySince == nil { healthySince = Date() }
        if let healthySince, Date().timeIntervalSince(healthySince) >= 30 { failures = 0 }
      } else { healthySince = nil }
      buffered = max(0, engine.playableTime - engine.currentPlaybackTime)
      if catchingUp, wantsPlayback {
        hls.setRate(buffered > (engine.playbackRate > 1 ? 0.5 : 1) ? 2 : 1)
      }
      playbackRate = playing ? engine.playbackRate : 0
      let size = engine.naturalSize
      resolution = size.height > 0 ? "\(Int(size.width)) × \(Int(size.height))" : ""
      if informationVisible, !loading, !switching, engine.isReadyToPlay,
        ProcessInfo.processInfo.systemUptime >= nextBitrateCheck {
        nextBitrateCheck = ProcessInfo.processInfo.systemUptime + 1
        let video = engine.tracks(mediaType: .video).first { $0.isEnabled }
        if frameRate != (video?.nominalFrameRate ?? 0) { frameRate = video?.nominalFrameRate ?? 0 }
        if reportsBitrate, playlistGateway?.usingBackup != true, let video {
          let input = StreamBitrate.Input(variants: variants, selectedID: qualityID,
            width: Int(size.width), height: Int(size.height), frameRate: Double(video.nominalFrameRate), trackBitrate: video.bitRate)
          if input != bitrateInput {
            bitrateInput = input
            bitrateTask?.cancel()
            bitrateTask = Task.detached(priority: .utility) { [weak self] in
              let value = input.value
              await self?.acceptBitrate(value, input: input)
            }
          }
        } else { clearBitrate() }
      }
      if let controller = engine.pipController, controller.delegate !== self {
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
      }
    } else { return }
    if buffering && wantsPlayback && !loading && !catchingUp && !waitingForAds && hls?.error == nil {
      scheduleRecovery()
    } else {
      stall?.cancel()
      stall = nil
    }
    adjustAutomaticCatchUp()
    updateNowPlaying()
  }

  private func clearBitrate() {
    bitrateTask?.cancel(); bitrateTask = nil
    bitrateInput = nil
    bitrate = nil
  }
  private func acceptBitrate(_ value: StreamBitrate?, input: StreamBitrate.Input) {
    guard !Task.isCancelled, informationVisible, reportsBitrate, bitrateInput == input else { return }
    bitrateTask = nil
    if bitrate != value { bitrate = value }
  }

  private func updateNowPlaying() {
    let state = NowPlayingState(title: title, rate: playbackRate)
    guard nowPlayingState != state else { return }
    nowPlayingState = state
    let info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPNowPlayingInfoPropertyPlaybackRate: Double(playbackRate),
      MPNowPlayingInfoPropertyIsLiveStream: true,
    ]
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }
  func beginCatchUp() {
    updateTime()
    guard wantsPlayback, !catchingUp,
      hls?.engine.isReadyToPlay == true
    else { return }
    setAutomaticCatchUp(false)
    previousDefaultRate = hls?.engine.playbackRate ?? 1
    catchingUp = true
    hls?.play()
  }

  func endCatchUp() {
    guard catchingUp else { return }
    catchingUp = false
    hls?.setRate(previousDefaultRate)
    updateTime()
  }

  private func setPlayback(_ active: Bool) {
    if active { monitorNetwork(); status = .buffering; hls?.play() }
    else {
      stopNetworkMonitor()
      cancelRetry(); stall?.cancel(); stall = nil
      status = .paused
      hls?.pause()
    }
  }

  private func monitorNetwork() {
    guard network == nil else { return }
    networkVersion += 1
    let version = networkVersion
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let available = path.status == .satisfied
      Task { @MainActor [weak self] in
        guard let self, networkVersion == version else { return }
        let restored = connectivity.update(available: available)
        if restored, wantsPlayback, case .unavailable = status {
          failures = 0
          recoverFailure(verifyEnd: true)
        }
      }
    }
    network = monitor
    monitor.start(queue: DispatchQueue(label: "Streamstiny.PlaybackNetwork"))
  }
  private func stopNetworkMonitor() {
    networkVersion += 1
    network?.cancel(); network = nil
    connectivity = PlaybackConnectivity()
  }

  private func scheduleRecovery() {
    guard !waitingForAds, retry == nil, stall == nil
    else { return }
    let version = generation
    stall = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(12)) } catch { return }
      guard let self, generation == version, wantsPlayback, !catchingUp, buffering
      else { return }
      // Return an unresponsive manual edge to the provider route before refreshing its grant.
      edge = nil
      stall = nil
      recoverFailure(verifyEnd: true)
    }
  }

  private func configureRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    for (command, active) in [(center.playCommand, true), (center.pauseCommand, false)] {
      commands.append(PlaybackCommandTarget(command: command, token: command.addTarget { [weak self] _ in
        Task { @MainActor in
          self?.endCatchUp()
          self?.wantsPlayback = active
          self?.setPlayback(active)
        }
        return .success
      }))
    }
    center.changePlaybackPositionCommand.isEnabled = false
  }
}

private final class PlaybackCommandTarget {
  let command: MPRemoteCommand
  let token: Any
  init(command: MPRemoteCommand, token: Any) {
    self.command = command
    self.token = token
  }
  deinit { command.removeTarget(token) }
}

struct PlayerView: View {
  let source: StreamSource
  var blocked: String? = nil
  let doubleTapEnabled: Bool
  let playback: NativePlayback
  let controls: PlaybackControls
  let library: StreamLibrary
  let addStream: () -> Void
  let toggleChat: () -> Void
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("twitchLowLatency") private var twitchLowLatency = false
  @AppStorage("kickLowLatency") private var kickLowLatency = false
  @AppStorage("youtubeLowLatency") private var youtubeLowLatency = false
  @AppStorage("angelthumpLowLatency") private var angelthumpLowLatency = false
  @AppStorage("automaticCatchUp") private var automaticCatchUp = false
  @AppStorage("targetBuffer") private var targetBuffer = 3.0
  @AppStorage("highestQuality") private var highestQuality = false
  @AppStorage("showViewers") private var showViewers = false
  @AppStorage("showDGGViewers") private var showDGGViewers = false
  @AppStorage("showBitrate") private var showBitrate = false

  var body: some View {
    @Bindable var controls = controls
    ZStack {
      NativeVideoLayer(
        playback: playback,
        tap: { count in
          controls.tap(count: count, doubleTapEnabled: doubleTapEnabled, toggleChat: toggleChat)
        },
        hold: { active in
          if active { playback.beginCatchUp() } else { playback.endCatchUp() }
        }, doubleTapEnabled: doubleTapEnabled, toggleChat: toggleChat
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      if playback.playbackRate > 1,
        playback.catchingUp || (playback.automaticallyCatchingUp && controls.visible) {
        Text(speedLabel).font(.headline.monospacedDigit()).padding(10)
          .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white)
          .offset(y: playback.catchingUp ? 0 : 56)
          .accessibilityLabel("Playback speed: " + speedLabel).allowsHitTesting(false)
      }
      if playback.loading || playback.buffering {
        ProgressView().tint(.white).allowsHitTesting(false)
      }
      if playback.waitingForAds {
        Text("Blocking ads").font(.caption2)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white).allowsHitTesting(false)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(.leading, 8).padding(.top, controls.visible ? 60 : 8)
      }
      if let message = blocked ?? playback.error {
        VStack(spacing: 12) {
          Image(systemName: "play.slash").font(.title)
          Text(message).font(.callout).multilineTextAlignment(.center).allowsHitTesting(false)
          if blocked == nil { Button("Retry") { playback.reload(resume: true) }.buttonStyle(.bordered) }
        }.padding().foregroundStyle(.white)
      }
      if controls.visible { playerControls.transition(.opacity) }
    }
    .animation(.easeOut(duration: 0.12), value: controls.visible)
    .background(.black)
    .sheet(isPresented: $controls.settingsPresented) { PlaybackSettings(playback: playback, source: source, library: library) }
    .task(id: source.id + (blocked ?? "")) {
      configurePlayback()
      if blocked == nil { await playback.load(source) } else { playback.stop() }
    }
    .onChange(of: twitchLowLatency) { _, _ in
      if source.provider == .twitch { playback.reload() }
    }
    .onChange(of: kickLowLatency) { _, _ in
      if source.provider == .kick { playback.reload() }
    }
    .onChange(of: youtubeLowLatency) { _, _ in
      if source.provider == .youtube { playback.reload() }
    }
    .onChange(of: angelthumpLowLatency) { _, _ in
      if source.provider == .angelthump { playback.reload() }
    }
    .onChange(of: automaticCatchUp) { _, _ in configurePlayback() }
    .onChange(of: targetBuffer) { _, _ in configurePlayback() }
    .onChange(of: highestQuality) { _, _ in configurePlayback() }
    .onChange(of: showBitrate) { _, _ in configurePlayback() }
    .onReceive(NotificationCenter.default.publisher(for: .twitchAccountChanged)) { _ in
      if source.provider == .twitch { playback.reload() }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        if controls.visible { controls.show() }
      } else {
        playback.endCatchUp()
        controls.cancel()
      }
    }
    .onDisappear {
      playback.endCatchUp()
      controls.cancel()
      if scenePhase == .active, !playback.pipActive { playback.stop() }
    }
  }

  private func configurePlayback() {
    playback.configure(
      automatic: automaticCatchUp, target: targetBuffer, highest: highestQuality, showBitrate: showBitrate)
  }

  private var speedLabel: String {
    playback.playbackRate.formatted(.number.precision(.fractionLength(0...1))) + "×"
  }

  private var playerControls: some View {
    ZStack {
      Color.black.opacity(0.2).allowsHitTesting(false)
      HStack {
        StreamMenu(library: library, controls: controls, addStream: addStream)
          .frame(width: 44, height: 44)
        Spacer()
        if showDGGViewers, let count = library.dggViewerCount(for: source) {
          Label("DGG " + count.formatted(), systemImage: "person.2")
            .font(.caption.monospacedDigit())
            .accessibilityLabel("\(count) watching through Destiny.gg")
        }
        if showViewers, let count = library.viewerCount(for: source) {
          Label(count.formatted(), systemImage: "eye")
            .font(.caption.monospacedDigit())
            .accessibilityLabel("\(count) overall stream viewers")
        }
        Button {
          controls.settingsPresented = true
        } label: {
          Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
        }.accessibilityLabel("Playback settings")
      }.padding(8).frame(maxHeight: .infinity, alignment: .top)
      if blocked == nil, playback.error == nil {
        Button {
          playback.toggle()
          controls.show()
        } label: {
          Image(systemName: playback.playing || playback.buffering ? "pause.fill" : "play.fill")
            .font(.title).frame(width: 52, height: 52)
        }.accessibilityLabel(playback.playing || playback.buffering ? "Pause" : "Play")
          .opacity(playback.catchingUp ? 0 : 1).allowsHitTesting(!playback.catchingUp)
      }
    }.foregroundStyle(.white).tint(.white)
  }
}

struct PlaybackSettings: View {
  let playback: NativePlayback
  let source: StreamSource
  let library: StreamLibrary
  @AppStorage("showBitrate") private var showBitrate = false
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        NavigationLink { PlaybackPreferencesView() } label: {
          Label("Playback", systemImage: "play.circle")
        }
        NavigationLink { resolutionSettings } label: {
          Label("Quality", systemImage: "sparkles.tv")
        }
        if playback.supportsEdges {
          NavigationLink { serverSettings } label: {
            Label("AngelThump server", systemImage: "network")
          }
        }
        Section("Now playing") {
          if let count = library.viewerCount(for: source) { LabeledContent("Viewers", value: count.formatted()) }
          if let count = library.dggViewerCount(for: source) { LabeledContent("DGG viewers", value: count.formatted()) }
          LabeledContent("Quality", value: playback.variants.first { $0.id == playback.qualityID }?.label ?? "Automatic")
          if !playback.resolution.isEmpty { LabeledContent("Playing", value: playback.resolution) }
          if playback.frameRate > 0 { LabeledContent("Framerate", value: playback.frameRate.formatted(.number.precision(.fractionLength(0...2))) + " fps") }
          if showBitrate {
            LabeledContent(playback.bitrate?.title ?? "Advertised stream bitrate", value: playback.bitrate?.label ?? "Unavailable")
              .accessibilityIdentifier("streamBitrate")
            Text("Playlist bandwidth, including audio and container overhead.")
              .font(.caption).foregroundStyle(.secondary)
          }
          LabeledContent("Buffered", value: playback.buffered.formatted(.number.precision(.fractionLength(1))) + " s")
          Button { playback.reload() } label: { Label("Reload stream", systemImage: "arrow.clockwise") }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Playback").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    .onAppear { playback.setInformationVisible(true) }
    .onDisappear { playback.setInformationVisible(false) }
  }

  private var resolutionSettings: some View {
    List {
      qualityRow("Automatic", id: nil)
      ForEach(playback.variants) { variant in
        qualityRow(variant.label + (variant.externalMedia ? " · limit" : ""), id: variant.id)
      }
      if playback.discovering { ProgressView("Loading qualities…") }
      else if playback.variants.isEmpty { Text("No selectable qualities").foregroundStyle(.secondary) }
      if playback.switching { ProgressView("Applying resolution…") }
      if let message = playback.settingsError {
        Section {
          Text(message).foregroundStyle(.secondary)
          Button("Retry qualities") { playback.retryChoices() }
        }
      }
    }.navigationTitle("Quality").navigationBarTitleDisplayMode(.inline)
  }

  private var serverSettings: some View {
    List {
      Button { playback.chooseEdge(nil) } label: {
        selectionRow("Provider default", selected: playback.edge == nil)
      }
      ForEach(AngelEdge.allCases) { edge in
        Button { playback.chooseEdge(edge) } label: {
          selectionRow(edge.name, selected: playback.edge == edge)
        }
      }
    }.disabled(playback.switching || playback.loading).navigationTitle("AngelThump server").navigationBarTitleDisplayMode(.inline)
  }

  private func qualityRow(_ title: String, id: String?) -> some View {
    Button { playback.chooseQuality(id) } label: {
      selectionRow(title, selected: playback.qualityID == id)
    }.disabled(playback.switching || playback.loading)
  }

  private func selectionRow(_ title: String, selected: Bool) -> some View {
    HStack {
      Text(title)
      Spacer()
      if selected { Image(systemName: "checkmark") }
    }.foregroundStyle(.primary)
  }
}

private struct NativeVideoLayer: UIViewRepresentable {
  let playback: NativePlayback
  let tap: (Int) -> Void
  let hold: (Bool) -> Void
  let doubleTapEnabled: Bool
  let toggleChat: () -> Void
  func makeCoordinator() -> NativePlayback { playback }
  func makeUIView(context: Context) -> VideoSurface {
    let view = VideoSurface()
    view.isAccessibilityElement = true
    view.accessibilityLabel = "Video"
    view.accessibilityIdentifier = "video"
    view.accessibilityTraits = .button
    configure(view)
    return view
  }
  func updateUIView(_ view: VideoSurface, context: Context) {
    configure(view)
  }
  private func configure(_ view: VideoSurface) {
    view.setRenderingView(playback.hls?.engine.view)
    view.tap = tap
    view.hold = hold
    view.accessibilityValue = playback.resolution.isEmpty ? nil : playback.resolution
    view.accessibilityHint =
      doubleTapEnabled
      ? "Hold to catch up at 2 times speed. Double tap to show or hide chat."
      : "Hold to catch up at 2 times speed."
    view.accessibilityCustomActions =
      doubleTapEnabled
      ? [
        UIAccessibilityCustomAction(name: "Toggle chat") { _ in
          toggleChat()
          return true
        }
      ] : []
  }
  static func dismantleUIView(_ view: VideoSurface, coordinator: NativePlayback) {
    view.cancelHold()
    view.hold = nil
    view.tap = nil
    guard !coordinator.pipActive, UIApplication.shared.applicationState == .active else { return }
    view.setRenderingView(nil)
  }
}

final class VideoSurface: UIView {
  var tap: ((Int) -> Void)?
  var hold: ((Bool) -> Void)?
  private weak var renderingView: UIView?
  func setRenderingView(_ view: UIView?) {
    guard renderingView !== view else { return }
    renderingView?.removeFromSuperview()
    renderingView = view
    guard let view else { return }
    view.frame = bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.isUserInteractionEnabled = false
    addSubview(view)
  }

  private var holding = false
  private var consumedTouch = false
  private let press = UILongPressGestureRecognizer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    press.minimumPressDuration = 0.35
    press.delaysTouchesBegan = false
    press.delaysTouchesEnded = false
    press.addTarget(self, action: #selector(pressed(_:)))
    addGestureRecognizer(press)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
    switch recognizer.state {
    case .began:
      holding = true
      consumedTouch = true
      hold?(true)
    case .ended, .cancelled, .failed:
      cancelHold()
    default: break
    }
  }

  func cancelHold() {
    guard holding else { return }
    holding = false
    hold?(false)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    consumedTouch = false
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil { cancelHold() }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard !consumedTouch, !holding, press.state != .ended,
      let touch = touches.first, touch.phase == .ended
    else { return }
    tap?(touch.tapCount)
  }
  override func accessibilityActivate() -> Bool {
    tap?(1)
    return true
  }
}
