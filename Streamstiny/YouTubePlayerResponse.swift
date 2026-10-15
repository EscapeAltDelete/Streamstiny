import Foundation

struct YouTubePlayerResponse: Decodable, Sendable {
  struct Status: Decodable, Sendable {
    let status: String
  }
  struct Details: Decodable, Sendable {
    let videoId: String
    let isLive: Bool?
  }
  struct Microformat: Decodable, Sendable {
    struct Renderer: Decodable, Sendable {
      struct Broadcast: Decodable, Sendable { let isLiveNow: Bool? }
      let liveBroadcastDetails: Broadcast?
    }
    let playerMicroformatRenderer: Renderer?
  }
  struct Streaming: Decodable, Sendable {
    struct Format: Decodable, Sendable {
      let url: String?
      let mimeType: String?
      let height: Int?
    }
    let hlsManifestUrl: String?
    let formats: [Format]?
  }
  let playabilityStatus: Status?
  let videoDetails: Details?
  let microformat: Microformat?
  let streamingData: Streaming?

  // isLiveContent also describes ended livestreams; it is not a live-now flag.
  var isLive: Bool? {
    videoDetails?.isLive ?? microformat?.playerMicroformatRenderer?.liveBroadcastDetails?.isLiveNow
  }
  func liveStatus(in playlist: String) -> Bool? {
    isLive ?? HLSPlaylist.isLive(playlist)
  }
}
