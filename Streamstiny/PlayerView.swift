import AVFoundation
import AVKit
import MediaPlayer
import Observation
import SwiftUI

@MainActor @Observable final class NativePlayback: NSObject, AVPictureInPictureControllerDelegate {
  let player: AVPlayer
  private(set) var hls: HLSPlayback?
  private(set) var title = ""
  private(set) var loading = false
  private(set) var buffering = false
  private(set) var playing = false
  private(set) var seconds = 0.0
  private(set) var duration = 0.0
  private(set) var live = false
  private(set) var error: String?
  private(set) var variants: [HLSVariant] = []
  private(set) var qualityID: String?
  private(set) var edge: AngelEdge?
  private(set) var discovering = false
  private(set) var switching = false
  private(set) var settingsError: String?
  private(set) var resolution = ""
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
    let elapsedSecond: Double
    let duration: Double
    let rate: Float
    let live: Bool
  }
  private var nowPlayingState: NowPlayingState?
  private var catchUpTask: Task<Void, Never>?
  private var previousWaitingPolicy = true
  private var previousDefaultRate: Float = 1
  private var rateObserver: NSKeyValueObservation?
  private var media: PlaybackMedia?
  private var discovery: Task<Void, Never>?
  private var selection: Task<Void, Never>?
  private var selectionVersion = 0
  private var stall: Task<Void, Never>?
  private var statusObserver: NSKeyValueObservation?
  private var recoveredAt = Date.distantPast
  var supportsEdges: Bool {
    source?.provider == .angelthump
      && variants.contains {
        !$0.externalMedia && AngelEdge.amsterdam.replacingHost(in: $0.url) != nil
      }
  }
  private let resolver = PlaybackResolver()
  private var source: StreamSource?
  private var observer: PlaybackTimeObservation?
  private var itemObserver: NSKeyValueObservation?
  private var renewal: Task<Void, Never>?
  private var twitchGateway: TwitchPlaylistGateway?
  private var retry: Task<Void, Never>?
  private var retryVersion = 0
  private var generation = 0
  private var failures = 0
  private var wantsPlayback = true
  private var pip: AVPictureInPictureController?
  private weak var pipLayer: AVPlayerLayer?
  private var commands: [PlaybackCommandTarget] = []

  override init() {
    player = AVPlayer()
    super.init()
  }

  var pipActive: Bool {
    hls?.engine.pipController?.isPictureInPictureActive == true
      || pip?.isPictureInPictureActive == true
  }

  func attach(_ layer: AVPlayerLayer) {
    guard hls == nil, !pipActive, pipLayer !== layer else { return }
    pipLayer = layer
    pip = AVPictureInPictureController(playerLayer: layer)
    pip?.delegate = self
    pip?.canStartPictureInPictureAutomaticallyFromInline = true
  }
  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (
      Bool
    ) -> Void
  ) {
    completionHandler(true)
  }
  func load(_ source: StreamSource, force: Bool = false) async {
    guard force || self.source != source || (player.currentItem == nil && hls == nil) else {
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
    let oldTime = seconds
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
    let wasLive = live
    self.source = source
    title = source.title
    error = nil
    loading = true
    renewal?.cancel()
    itemObserver = nil
    if !force {
      hls?.stop()
      hls = nil
      twitchGateway?.stop()
      twitchGateway = nil
      player.pause()
      player.replaceCurrentItem(with: nil)
      seconds = 0
      duration = 0
      live = false
      playing = false
      buffering = false
    }
    do {
      let media = try await resolver.resolve(source)
      let useLiveDecoder: Bool
      if source.provider == .youtube {
        // Native HLS handles YouTube adaptation without FFmpeg rendition probing.
        useLiveDecoder = false
      } else if let isLive = media.isLive {
        useLiveDecoder = isLive
      } else {
        useLiveDecoder = try await resolver.requiresLiveDecoder(media.url, source: source)
      }
      try Task.checkCancellation()
      guard version == generation else { return }
      self.media = media
      if let choices = media.variants { variants = choices }
      var edgeURL: URL?
      var variant: HLSVariant?
      if highestQuality, !force {
        if media.variants == nil {
          variants = (try? await resolver.variants(at: media.url)) ?? []
        }
        guard version == generation, !Task.isCancelled else { return }
        if highestQuality {
          variant = variants.first
          qualityID = variant?.id
        }
      }
      if force, qualityID != nil {
        if media.variants == nil {
          variants = (try? await resolver.variants(at: media.url)) ?? []
        }
        guard version == generation, !Task.isCancelled else { return }
        variant = variants.first { $0.id == qualityID }
        if let edge, let variant,
          let verified = try? await resolver.verifiedEdge(edge, variant: variant)
        {
          edgeURL = verified
        } else if edge != nil {
          edge = nil
          settingsError = "That edge is unavailable. Using the provider’s default server."
        }
        guard version == generation, !Task.isCancelled else { return }
        if variant == nil { qualityID = nil }
      }
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try AVAudioSession.sharedInstance().setActive(true)
      var gateway: TwitchPlaylistGateway?
      if source.provider == .twitch, UserDefaults.standard.bool(forKey: "twitchAdBlocking") {
        gateway = try await TwitchPlaylistGateway.start(source: source, variants: variants, resolver: resolver)
        guard version == generation, !Task.isCancelled else { gateway?.stop(); return }
      }
      let remoteURL = Self.playbackURL(master: media.url, variant: variant, edgeURL: edgeURL)
      let playbackURL = await gateway?.url(for: remoteURL) ?? remoteURL
      guard version == generation, !Task.isCancelled else { gateway?.stop(); return }
      if useLiveDecoder {
        installHLS(playbackURL, variant: variant, startTime: force && !wasLive ? oldTime : 0)
      } else {
        hls?.stop()
        hls = nil
        let item = Self.makeItem(master: media.url, variant: variant, edgeURL: edgeURL,
          headers: media.headers, adaptive: source.provider == .youtube)
        player.replaceCurrentItem(with: item)
        if force, !wasLive, oldTime > 0 {
          await player.seek(to: CMTime(seconds: oldTime, preferredTimescale: 600))
          guard version == generation, !Task.isCancelled else { return }
        }
        if wantsPlayback { player.play() }
        itemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
          Task { @MainActor [weak self] in self?.itemChanged() }
        }
      }
      twitchGateway?.stop()
      twitchGateway = gateway
      if observer == nil {
        let token = player.addPeriodicTimeObserver(
          forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in self?.updateTime() }
        }
        observer = PlaybackTimeObservation(player: player, token: token)
        statusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) {
          [weak self] _, _ in
          Task { @MainActor [weak self] in self?.updateTime() }
        }
        rateObserver = player.observe(\.rate, options: [.initial, .new]) { [weak self] _, _ in
          Task { @MainActor [weak self] in self?.updateTime() }
        }
        configureRemoteCommands()
      }
      // Existing live CDN playback can outlive the grant used to open it.
      // Recover on actual failure instead of rebuilding a healthy stream on a timer.
      if !useLiveDecoder, media.isLive != true, let expires = media.expires {
        let delay = max(15, expires.timeIntervalSinceNow - 30)
        renewal = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(delay)) } catch { return }
          guard let self, self.generation == version else { return }
          self.renewal = nil
          await self.load(source, force: true)
        }
      }
      loading = false
      stall?.cancel()
      stall = nil
      if variants.isEmpty, media.variants == nil { discover(media.url, version: version) }
    } catch is CancellationError { if version == generation { loading = false } } catch {
      guard version == generation else { return }
      loading = false
      self.error = error.localizedDescription
    }
  }
  static func makeItem(master: URL, variant: HLSVariant?, edgeURL: URL? = nil,
    headers: [String: String] = [:], adaptive: Bool = false) -> AVPlayerItem {
    let url = adaptive ? master : playbackURL(master: master, variant: variant, edgeURL: edgeURL)
    let item = AVPlayerItem(
      asset: AVURLAsset(
        url: url,
        options: [AVURLAssetHTTPUserAgentKey: headers["User-Agent"] ?? PlaybackResolver.userAgent,
          "AVURLAssetHTTPHeaderFieldsKey": headers]))
    // Keep the master for alternate media groups and YouTube bitrate adaptation.
    if let variant, variant.externalMedia || adaptive {
      item.preferredMaximumResolution = CGSize(
        width: CGFloat(variant.width), height: CGFloat(variant.height))
      item.preferredPeakBitRate = variant.bandwidth
    }
    return item
  }

  static func playbackURL(master: URL, variant: HLSVariant?, edgeURL: URL?) -> URL {
    edgeURL ?? variant.flatMap { $0.externalMedia ? nil : $0.url } ?? master
  }

  private func installHLS(_ url: URL, variant: HLSVariant?, startTime: Double = 0) {
    hls?.stop()
    player.pause()
    player.replaceCurrentItem(with: nil)
    itemObserver = nil
    pip?.stopPictureInPicture()
    pip = nil
    pipLayer = nil
    hls = HLSPlayback(url: url, variant: variant, headers: media?.headers ?? [:], playing: wantsPlayback, startTime: startTime) {
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

  func configure(automatic: Bool, target: Double, highest: Bool) {
    let changedQuality = highest && !highestQuality
    automaticCatchUp = automatic
    targetBuffer = target.isFinite ? min(20, max(0, target)) : 3
    highestQuality = highest
    nextBufferCheck = 0
    if changedQuality { selectPreferredQuality() }
    updateTime()
  }

  private func selectPreferredQuality() {
    guard highestQuality, let best = variants.first, !loading, !switching else { return }
    chooseQuality(best.id, edge: edge)
  }

  private func adjustAutomaticCatchUp() {
    guard automaticCatchUp, live, wantsPlayback, playing, !loading, !switching,
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
    if let hls {
      hls.setRate(rate)
    } else {
      player.defaultRate = rate
      if wantsPlayback, player.timeControlStatus == .playing { player.playImmediately(atRate: rate) }
    }
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
    endCatchUp()
    setAutomaticCatchUp(false)
    selection?.cancel()
    selectionVersion += 1
    let change = selectionVersion
    let version = generation
    switching = true
    settingsError = nil
    selection = Task { [weak self] in
      guard let self else { return }
      do {
        var edgeURL: URL?
        if let requestedEdge, let variant {
          edgeURL = try await resolver.verifiedEdge(requestedEdge, variant: variant)
        }
        guard generation == version, selectionVersion == change, !Task.isCancelled else { return }
        let time = seconds
        let restoreTime = !live && time > 0
        if hls != nil {
          let remoteURL = Self.playbackURL(master: media.url, variant: variant, edgeURL: edgeURL)
          let playbackURL = await twitchGateway?.url(for: remoteURL) ?? remoteURL
          guard generation == version, selectionVersion == change, !Task.isCancelled else { return }
          installHLS(
            playbackURL,
            variant: variant, startTime: restoreTime ? time : 0)
        } else {
          let item = Self.makeItem(master: media.url, variant: variant, edgeURL: edgeURL,
            headers: media.headers, adaptive: source?.provider == .youtube)
          player.replaceCurrentItem(with: item)
          itemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.itemChanged() }
          }
        }
        qualityID = id
        edge = requestedEdge
        failures = 0
        stall?.cancel()
        stall = nil
        if restoreTime, hls == nil {
          await player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        }
        guard generation == version, selectionVersion == change, !Task.isCancelled else { return }
        if wantsPlayback {
          if let hls { hls.play() } else { player.play() }
        }
      } catch {
        guard generation == version, selectionVersion == change, !Task.isCancelled else { return }
        settingsError = "That server didn’t return playable media. Your current stream was kept."
      }
      switching = false
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

  func reload() {
    guard let source else { return }
    failures = 0
    cancelRetry()
    let attempt = retryVersion
    retry = Task { [weak self] in
      defer { if let self, self.retryVersion == attempt { self.retry = nil } }
      guard let self else { return }
      await load(source, force: true)
    }
  }
  func toggle() {
    endCatchUp()
    wantsPlayback = !(playing || buffering)
    setPlayback(wantsPlayback)
    updateTime()
  }
  func seek(_ seconds: Double) {
    endCatchUp()
    guard seconds.isFinite else { return }
    if let hls {
      hls.engine.seek(time: max(0, seconds)) { _ in }
    } else {
      player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    }
  }
  func stop() {
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
    renewal?.cancel()
    renewal = nil
    cancelRetry()
    itemObserver = nil
    statusObserver = nil
    rateObserver = nil
    stall?.cancel()
    stall = nil
    observer = nil
    commands.removeAll()
    pip?.stopPictureInPicture()
    pip = nil
    pipLayer = nil
    hls?.stop()
    hls = nil
    twitchGateway?.stop()
    twitchGateway = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    source = nil
    media = nil
    variants = []
    qualityID = nil
    edge = nil
    loading = false
    buffering = false
    waitingForAds = false
    playing = false
    playbackRate = 0
    seconds = 0
    duration = 0
    live = false
    resolution = ""
    buffered = 0
    error = nil
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

  private func itemChanged() {
    if player.currentItem?.status == .failed { recoverFailure() }
    updateTime()
  }

  private func recoverFailure() {
    guard retry == nil, !loading else { return }
    if waitingForAds, let gateway = twitchGateway, let source, let media {
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
      }
      return
    }
    guard failures < 2, let source else {
      error = "Video playback failed after refreshing its source. Try another channel or retry."
      return
    }
    failures += 1
    let version = generation
    retryVersion += 1
    let attempt = retryVersion
    retry = Task { [weak self] in
      defer { if let self, self.retryVersion == attempt { self.retry = nil } }
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      guard let self, generation == version else { return }
      await load(source, force: true)
    }
  }
  private func updateTime() {
    waitingForAds = twitchGateway?.waiting ?? false
    // Reuse the decoder's existing tick to maintain a held rate as media arrives.
    if catchingUp, wantsPlayback {
      if let hls {
        hls.setRate(2)
      } else if player.currentItem?.status == .readyToPlay,
        player.rate != 2 || player.timeControlStatus == .paused
      {
        player.playImmediately(atRate: 2)
      }
    }
    if let hls {
      let engine = hls.engine
      seconds = max(0, engine.currentPlaybackTime)
      duration = max(0, engine.duration)
      live = media?.isLive ?? (duration == 0)
      playing = engine.isPlaying && engine.loadState == .playable
      playbackRate = playing ? engine.playbackRate : 0
      buffering = wantsPlayback && engine.loadState != .playable
      buffered = max(0, engine.playableTime - seconds)
      let size = engine.naturalSize
      resolution = size.height > 0 ? "\(Int(size.width)) × \(Int(size.height))" : ""
      if hls.error != nil { recoverFailure() }
      if buffering && wantsPlayback && !loading && !catchingUp && !waitingForAds && hls.error == nil {
        scheduleRecovery()
      } else {
        stall?.cancel()
        stall = nil
      }
      if let controller = engine.pipController, controller.delegate !== self {
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
      }
      adjustAutomaticCatchUp()
      updateNowPlaying()
      return
    }
    guard player.currentItem != nil else { return }
    let time = player.currentTime().seconds
    seconds = time.isFinite ? max(0, time) : 0
    let length = player.currentItem?.duration.seconds ?? 0
    duration = length.isFinite ? max(0, length) : 0
    live = media?.isLive ?? (length.isInfinite || player.currentItem?.duration.isIndefinite == true)
    playing = player.timeControlStatus == .playing
    playbackRate = playing ? player.rate : 0
    buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    if let item = player.currentItem {
      let size = item.presentationSize
      resolution = size.height > 0 ? "\(Int(size.width)) × \(Int(size.height))" : ""
      let timing = PlaybackTiming(
        current: time, loaded: item.loadedTimeRanges.map(\.timeRangeValue))
      buffered = timing.buffered
      if catchingUp && (!wantsPlayback || item.status != .readyToPlay) {
        endCatchUp()
      }
    }
    if buffering && wantsPlayback && !loading && !catchingUp && !waitingForAds {
      scheduleRecovery()
    } else {
      stall?.cancel()
      stall = nil
    }
    adjustAutomaticCatchUp()
    updateNowPlaying()
  }

  private func updateNowPlaying() {
    let state = NowPlayingState(
      title: title, elapsedSecond: seconds.rounded(.down), duration: duration,
      rate: playbackRate, live: live)
    guard nowPlayingState != state else { return }
    nowPlayingState = state
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: seconds,
      MPNowPlayingInfoPropertyPlaybackRate: Double(playbackRate),
      MPNowPlayingInfoPropertyIsLiveStream: live,
    ]
    if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }
  func beginCatchUp() {
    updateTime()
    guard wantsPlayback, !catchingUp,
      hls?.engine.isReadyToPlay == true || player.currentItem?.status == .readyToPlay
    else { return }
    setAutomaticCatchUp(false)
    previousWaitingPolicy = player.automaticallyWaitsToMinimizeStalling
    previousDefaultRate = hls?.engine.playbackRate ?? player.defaultRate
    catchingUp = true
    if let hls {
      hls.setRate(2)
      hls.play()
    } else {
      player.automaticallyWaitsToMinimizeStalling = false
      player.defaultRate = 2
      player.playImmediately(atRate: 2)
    }
    updateTime()
    if hls == nil {
      // AVPlayer's periodic observer stops at an empty buffer; keep retrying a held rate.
      catchUpTask = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
          guard let self, catchingUp, wantsPlayback else { return }
          updateTime()
        }
      }
    }
  }

  func endCatchUp() {
    guard catchingUp else { return }
    catchingUp = false
    catchUpTask?.cancel()
    catchUpTask = nil
    if let hls {
      hls.setRate(previousDefaultRate)
    } else {
      player.defaultRate = previousDefaultRate
      player.automaticallyWaitsToMinimizeStalling = previousWaitingPolicy
      if wantsPlayback, player.currentItem?.status == .readyToPlay { player.play() }
    }
    updateTime()
  }

  private func setPlayback(_ active: Bool) {
    if let hls {
      if active { hls.play() } else { hls.pause() }
    } else {
      if active { player.play() } else { player.pause() }
    }
  }


  private func scheduleRecovery() {
    guard !waitingForAds, stall == nil, failures < 2,
      Date().timeIntervalSince(recoveredAt) > 60, let source
    else { return }
    let version = generation
    stall = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(12)) } catch { return }
      guard let self, generation == version, wantsPlayback, !catchingUp, buffering
      else { return }
      recoveredAt = Date()
      failures += 1
      // Return an unresponsive manual edge to the provider route before refreshing its grant.
      edge = nil
      await load(source, force: true)
      if !Task.isCancelled { stall = nil }
    }
  }

  private func configureRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    commands.append(
      PlaybackCommandTarget(
        command: center.playCommand,
        token: center.playCommand.addTarget { [weak self] _ in
          Task { @MainActor in
            self?.endCatchUp()
            self?.wantsPlayback = true
            self?.setPlayback(true)
          }
          return .success
        }
      ))
    commands.append(
      PlaybackCommandTarget(
        command: center.pauseCommand,
        token: center.pauseCommand.addTarget { [weak self] _ in
          Task { @MainActor in
            self?.endCatchUp()
            self?.wantsPlayback = false
            self?.setPlayback(false)
          }
          return .success
        }
      ))
    commands.append(
      PlaybackCommandTarget(
        command: center.changePlaybackPositionCommand,
        token: center.changePlaybackPositionCommand.addTarget { [weak self] event in
          guard let event = event as? MPChangePlaybackPositionCommandEvent else {
            return .commandFailed
          }
          let time = event.positionTime
          Task { @MainActor in self?.seek(time) }
          return .success
        }
      ))
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

private final class PlaybackTimeObservation {
  let player: AVPlayer
  let token: Any
  init(player: AVPlayer, token: Any) {
    self.player = player
    self.token = token
  }
  deinit { player.removeTimeObserver(token) }
}

struct PlayerView: View {
  let source: StreamSource
  var blocked: String? = nil
  let doubleTapEnabled: Bool
  @State private var playback = NativePlayback()
  let controls: PlaybackControls
  let library: StreamLibrary
  let addStream: () -> Void
  let toggleChat: () -> Void
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("automaticCatchUp") private var automaticCatchUp = false
  @AppStorage("targetBuffer") private var targetBuffer = 3.0
  @AppStorage("highestQuality") private var highestQuality = false
  @AppStorage("showViewers") private var showViewers = false
  @AppStorage("showDGGViewers") private var showDGGViewers = false

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
      if playback.catchingUp || (playback.automaticallyCatchingUp && controls.visible) {
        Text(speedLabel).font(.headline.monospacedDigit()).padding(10)
          .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white)
          .accessibilityLabel("Playback speed: " + speedLabel).allowsHitTesting(false)
      }
      if playback.loading || playback.buffering {
        ProgressView().tint(.white).allowsHitTesting(false)
      }
      if playback.waitingForAds {
        Text("Waiting for an ad-free stream").font(.caption).padding(10)
          .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white).allowsHitTesting(false)
      }
      if let message = blocked ?? playback.error {
        VStack(spacing: 12) {
          Image(systemName: "play.slash").font(.title)
          Text(message).font(.callout).multilineTextAlignment(.center).allowsHitTesting(false)
          if blocked == nil { Button("Retry") { playback.reload() }.buttonStyle(.bordered) }
        }.padding().foregroundStyle(.white)
      }
      if controls.visible { playerControls.transition(.opacity) }
    }
    .animation(.easeOut(duration: 0.12), value: controls.visible)
    .background(.black)
    .sheet(isPresented: $controls.settingsPresented) { PlaybackSettings(playback: playback) }
    .task(id: source.id + (blocked ?? "")) {
      configurePlayback()
      if blocked == nil { await playback.load(source) } else { playback.stop() }
    }
    .onChange(of: automaticCatchUp) { _, _ in configurePlayback() }
    .onChange(of: targetBuffer) { _, _ in configurePlayback() }
    .onChange(of: highestQuality) { _, _ in configurePlayback() }
    .onReceive(NotificationCenter.default.publisher(for: .twitchAccountChanged)) { _ in
      if [.twitch, .twitchVod, .twitchClip].contains(source.provider) { playback.reload() }
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
      if !playback.pipActive { playback.stop() }
    }
  }

  private func configurePlayback() {
    playback.configure(
      automatic: automaticCatchUp, target: targetBuffer, highest: highestQuality)
  }

  private var speedLabel: String {
    playback.playbackRate > 0
      ? playback.playbackRate.formatted(.number.precision(.fractionLength(0...1))) + "×"
      : "Waiting for video"
  }

  private var playerControls: some View {
    ZStack {
      Color.black.opacity(0.2).allowsHitTesting(false)
      VStack {
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
        }
        Spacer(minLength: 4)
        HStack(spacing: 30) {
          if !playback.live {
            Button {
              playback.seek(playback.seconds - 10)
              controls.show()
            } label: {
              Image(systemName: "gobackward.10").frame(width: 44, height: 44)
            }.accessibilityLabel("Back 10 seconds")
          }
          Button {
            playback.toggle()
            controls.show()
          } label: {
            Image(systemName: playback.playing || playback.buffering ? "pause.fill" : "play.fill")
              .font(.title).frame(width: 52, height: 52)
          }.accessibilityLabel(playback.playing || playback.buffering ? "Pause" : "Play")
          if !playback.live {
            Button {
              playback.seek(playback.seconds + 10)
              controls.show()
            } label: {
              Image(systemName: "goforward.10").frame(width: 44, height: 44)
            }.accessibilityLabel("Forward 10 seconds")
          }
        }
        Spacer(minLength: 4)
        if playback.duration > 0 && !playback.live {
          Slider(
            value: Binding(
              get: { min(playback.seconds, playback.duration) },
              set: { playback.seek($0) }), in: 0...playback.duration,
            onEditingChanged: { controls.scrub($0) }
          ).accessibilityLabel("Video position")
        }
      }.padding(8).foregroundStyle(.white).tint(.white)
    }
  }
}

private struct PlaybackSettings: View {
  let playback: NativePlayback
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
          if !playback.resolution.isEmpty { LabeledContent("Playing", value: playback.resolution) }
          LabeledContent("Buffered", value: playback.buffered.formatted(.number.precision(.fractionLength(1))) + " s")
          Button { playback.reload() } label: { Label("Reload stream", systemImage: "arrow.clockwise") }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Playback").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
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
  func makeUIView(context: Context) -> VideoSurface {
    let view = VideoSurface()
    view.layerPlayer.player = playback.hls == nil ? playback.player : nil
    view.layerPlayer.videoGravity = .resizeAspect
    view.isAccessibilityElement = true
    view.accessibilityLabel = "Video"
    view.accessibilityIdentifier = "video"
    view.accessibilityTraits = .button
    playback.attach(view.layerPlayer)
    configure(view)
    return view
  }
  func updateUIView(_ view: VideoSurface, context: Context) {
    view.layerPlayer.player = playback.hls == nil ? playback.player : nil
    playback.attach(view.layerPlayer)
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
  static func dismantleUIView(_ view: VideoSurface, coordinator: ()) {
    view.cancelHold()
    view.hold = nil
    view.tap = nil
    view.layerPlayer.player = nil
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

  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var layerPlayer: AVPlayerLayer { layer as! AVPlayerLayer }
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
