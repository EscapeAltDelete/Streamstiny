import Foundation

enum TwitchBackupTests {
  static func run() async throws {
    func variant(_ name: String, _ width: Int, _ height: Int, _ fps: Double = 60,
      codecs: String = "avc1.640028,mp4a.40.2", external: Bool = false) -> HLSVariant {
      HLSVariant(url: URL(string: "https://video.ttvnw.net/\(name).m3u8")!, width: width,
        height: height, bandwidth: 6_000_000, frameRate: fps, externalMedia: external, codecs: codecs)
    }
    let hd = variant("1080", 1920, 1080), sd = variant("360", 640, 360)
    let halfRate = variant("1080-30", 1920, 1080, 30), medium = variant("720", 1280, 720)
    let hevc = variant("hevc", 1920, 1080, codecs: "hvc1.1.6.L123,mp4a.40.2")
    let external = variant("external", 1920, 1080, external: true)
    let source = variant("source", 0, 0)
    let fractional = variant("59.94", 1920, 1080, 59.94)
    let playlist = TwitchAdPlaylist("#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:1\n#EXTINF:2,live\nhttps://video.ttvnw.net/live.ts\n")!
    precondition(TwitchBackupSelection.ranked([sd, hevc, external, halfRate, medium, hd], for: hd) == [hd, halfRate, medium, sd])
    precondition(TwitchBackupSelection.ranked([hd, halfRate], for: halfRate).first == halfRate)
    precondition(TwitchBackupSelection.matchesQuality(fractional, of: hd))
    precondition(TwitchBackupSelection.compatible(source, with: source))
    precondition(!TwitchBackupSelection.compatible(source, with: hd))
    precondition(TwitchBackupSelection.ranked([sd, hd, source], for: source).first == source)
    let portrait = variant("portrait", 1080, 1920)
    precondition(TwitchBackupSelection.ranked([hd, portrait], for: portrait).first == portrait)

    // Model autoplay winning the network race while a source-capable context is slower.
    let race = await TwitchBackupSelection.search(for: hd, timeout: .seconds(2)) { context in
      do {
        switch context {
        case "autoplay": return (playlist, sd)
        case "embed": try await Task.sleep(for: .milliseconds(40)); return (playlist, hd)
        default: try await Task.sleep(for: .seconds(5)); return nil
        }
      } catch { return nil }
    }
    precondition(race?.variant == hd, "A fast 360p result must not cancel available 1080p60")
    let fpsRace = await TwitchBackupSelection.search(for: hd) { context in
      if context == "popout" { try? await Task.sleep(for: .milliseconds(30)); return (playlist, hd) }
      return context == "embed" ? (playlist, halfRate) : nil
    }
    precondition(fpsRace?.variant == hd, "1080p30 must not preempt available 1080p60")

    let clock = ContinuousClock()
    var started = clock.now
    let fallback = await TwitchBackupSelection.search(for: hd, timeout: .seconds(5)) { context in
      switch context {
      case "embed": return (playlist, hevc)
      case "site": return (playlist, external)
      case "popout": return (playlist, medium)
      default: return (playlist, sd)
      }
    }
    precondition(fallback?.variant == medium, "Keep the best compatible clean fallback")
    precondition(started.duration(to: clock.now) < .seconds(2), "Completed contexts do not wait for the deadline")
    started = clock.now
    let deadline = await TwitchBackupSelection.search(for: hd, timeout: .milliseconds(80)) { context in
      if context == "autoplay" { return (playlist, sd) }
      do { try await Task.sleep(for: .seconds(5)) } catch { return nil }
      return (playlist, hd)
    }
    precondition(deadline?.variant == sd, "The deadline must retain an already discovered clean fallback")
    precondition(started.duration(to: clock.now) < .seconds(2), "The deadline cancels pending contexts")
    let missing = await TwitchBackupSelection.search(for: hd, timeout: .milliseconds(30)) { _ in
      do { try await Task.sleep(for: .seconds(5)) } catch { return nil }
      return (playlist, hd)
    }
    precondition(missing == nil)
    let cancelled = Task {
      await TwitchBackupSelection.search(for: hd) { _ in
        do { try await Task.sleep(for: .seconds(5)) } catch { return nil }
        return (playlist, hd)
      }
    }
    cancelled.cancel()
    let cancelledResult = await cancelled.value
    precondition(cancelledResult == nil, "Cancellation must not cache a late backup")
    let interrupted = Task {
      await TwitchBackupSelection.search(for: hd) { _ in
        do { try await Task.sleep(for: .seconds(5)) } catch { return nil }
        return (playlist, hd)
      }
    }
    try await Task.sleep(for: .milliseconds(20))
    started = clock.now
    interrupted.cancel()
    let interruptedResult = await interrupted.value
    precondition(interruptedResult == nil && started.duration(to: clock.now) < .seconds(2))
    print("Passed Twitch resolution/fps selection, source, codec/container, deadline, and cancellation regressions")
  }
}
