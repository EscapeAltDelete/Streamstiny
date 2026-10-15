import AVFoundation
import CryptoKit
import SwiftUI

extension ChatMessage {
  // Matches DGG's message identity for spotlight emphasis, not for authentication.
  var spotlightIdentity: String {
    let time = timestamp.isFinite ? String(format: "%.0f", timestamp) : "0"
    let input = time + (userID.map(String.init) ?? "") + text
    return Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

struct ChatEventBar: View {
  let chat: ChatStore
  let emotes: EmoteStore
  let fontSize: Double
  let onStream: (StreamSource) -> Void
  @State private var selected: ChatMessage?
  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack {
        ForEach(chat.paidEvents) { event in
          Button { selected = event } label: {
            Text(event.heading ?? event.nick).font(.caption2).lineLimit(1)
              .padding(6).background(.tint.opacity(0.1), in: Capsule())
          }
        }
      }.padding(.horizontal, 8)
    }.frame(height: 30)
      .sheet(item: $selected) { event in
        ChatEventDetail(message: event, chat: chat, emotes: emotes, fontSize: fontSize, onStream: onStream)
      }
  }
}

private struct ChatEventDetail: View {
  let message: ChatMessage
  let chat: ChatStore
  let emotes: EmoteStore
  let fontSize: Double
  let onStream: (StreamSource) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var audio: AVPlayer?
  @State private var playingAudio = false
  var body: some View {
    NavigationStack {
      VStack {
        ChatList(messages: [message], emotes: emotes, fontSize: fontSize, timestamps: true,
          onReply: { chat.requestedReply = $0 }, onWhisper: { chat.openConversation($0) },
          onIgnore: { chat.ignore($0) }, onStream: onStream, chat: chat, stateRevision: chat.renderingRevision ^ emotes.revision)
        if message.kind.hasPrefix("VESTABOARD_") {
          if let board = message.board { VestaboardView(board: board).padding(.horizontal) }
          ForEach(message.contributors.indices, id: \.self) { index in
            let contributor = message.contributors[index]
            Button("\(contributor.name) · $" + String(format: "%.2f", Double(contributor.amount) / 100)) {
              chat.requestedProfile = ChatUser(["nick": contributor.name]); dismiss()
            }.font(.caption)
          }
          Link("Open Vestaboard auction", destination: URL(string: "https://www.destiny.gg/vestaboard")!).font(.caption).padding(8)
        }
        if let url = message.audio {
          Button(playingAudio ? "Pause TTS" : "Play TTS") {
            if audio == nil { audio = AVPlayer(url: url) }
            playingAudio.toggle()
            if playingAudio { audio?.play() } else { audio?.pause() }
          }.buttonStyle(.bordered).padding()
        }
        if chat.account?.canRemoveEvents == true {
          Button("Remove event", role: .destructive) {
            Task {
              do { try await chat.transmit("REMOVEEVENT", ["data": message.id]); dismiss() }
              catch { chat.error = error.localizedDescription }
            }
          }.padding()
        }
      }.navigationTitle("Chat event").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    .onDisappear { audio?.pause(); audio = nil }
    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
      guard let item = notification.object as? AVPlayerItem, item === audio?.currentItem else { return }
      playingAudio = false; audio?.seek(to: .zero)
    }
  }
}

struct ChatUserProfileView: View {
  let emotes: EmoteStore
  let initial: ChatUser
  let chat: ChatStore
  @Environment(\.dismiss) private var dismiss
  @State private var fetched: ChatUser?
  @State private var failure: String?
  @State private var changedTag = false
  var body: some View {
    let user = fetched ?? initial
    NavigationStack {
      List {
        Section("Profile") {
          Text(user.nick).font(.headline)
          if let created = user.created { LabeledContent("Joined", value: created) }
          if let bio = user.bio, !bio.isEmpty { Text(bio).textSelection(.enabled) }
          if let age = user.age { LabeledContent("Age", value: age) }
          if let gender = user.gender { LabeledContent("Gender", value: gender) }
          if let watching = user.watching {
            Button("Watching: " + watching.title) { chat.requestedSource = watching; dismiss() }
          }
          ForEach(emotes.flairs.filter { user.features.contains($0.name) }, id: \.name) { flair in
            HStack {
              if !flair.hidden, let image = emotes.image(for: "flair:" + flair.name) {
                Image(uiImage: image).resizable().scaledToFit().frame(width: 24, height: 24)
              }
              VStack(alignment: .leading) {
                Text(flair.label)
                if let description = flair.description { Text(description).font(.caption).foregroundStyle(.secondary) }
              }
            }
          }
        }
        Section("Personal tag") {
          Picker("Color", selection: Binding(get: { chat.tagColors[user.id] ?? "none" }, set: { color in
            changedTag = true
            chat.tag(user.nick, text: color == "none" ? nil : chat.tags[user.id] ?? "", color: color)
          })) {
            Text("None").tag("none")
            ForEach(ChatStore.tagColorNames, id: \.self) { Text($0.capitalized).tag($0) }
          }
          TextField("Note", text: Binding(get: { chat.tags[user.id] ?? "" }, set: { changedTag = true; chat.tag(user.nick, text: $0) }))
        }
        Section("Actions") {
          Button { chat.openConversation(user.nick); dismiss() } label: { Label("Whisper", systemImage: "envelope") }
          Button(chat.ignored.contains(user.id) ? "Unignore" : "Ignore") {
            if chat.ignored.contains(user.id) { chat.unignore(user.nick) } else { chat.ignore(user.nick) }
          }
          Button(chat.highlighted.contains(user.id) ? "Remove highlight" : "Highlight") {
            chat.highlight(user.nick, enabled: !chat.highlighted.contains(user.id))
          }
        }
        if let failure { Section { Text(failure).font(.caption).foregroundStyle(.secondary) } }
      }.listStyle(.insetGrouped).navigationTitle("User profile").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onDisappear {
          if changedTag, DestinyAccount.hasSession, chat.identity != nil, ChatPreferences.automaticSync {
            Task {
              do { try await ChatPreferences.save(from: chat) }
              catch is CancellationError {} catch { chat.error = error.localizedDescription }
            }
          }
        }
        .task(id: initial.id) {
          do {
            let nick = initial.nick.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?#+"))) ?? ""
            let data = try await DestinyAccount.request("/api/chat/userinfo?username=" + nick)
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["success"] as? Bool == true, let user = payload["data"] as? [String: Any] else {
              failure = "This profile is unavailable."; return
            }
            fetched = ChatUser(user)
          } catch { failure = error.localizedDescription }
        }
    }
  }
}

private struct VestaboardView: View {
  let board: [[Int]]
  private let punctuation = [37: "!", 38: "@", 39: "#", 40: "$", 41: "(", 42: ")", 44: "-", 46: "+", 47: "&", 48: "=", 49: ";", 50: ":", 52: "'", 53: "\"", 54: "%", 55: ",", 56: ".", 59: "/", 60: "?"]
  private let colors: [Int: Color] = [63: .red, 64: .orange, 65: .yellow, 66: .green, 67: .blue, 68: .purple, 69: .white, 70: .black, 71: .gray]
  private func character(_ code: Int) -> String {
    if (1...26).contains(code) { return String(UnicodeScalar(64 + code)!) }
    if (27...36).contains(code) { return String((code - 26) % 10) }
    return punctuation[code] ?? ""
  }
  var body: some View {
    GeometryReader { geometry in
      let tile = (geometry.size.width - 21) / 22
      VStack(spacing: 1) {
        ForEach(board.indices, id: \.self) { row in
          HStack(spacing: 1) {
            ForEach(board[row].indices, id: \.self) { column in
              let code = board[row][column]
              Text(character(code)).font(.system(size: tile * 0.65, weight: .bold, design: .monospaced))
                .foregroundStyle(.white).frame(width: tile, height: tile)
                .background(colors[code] ?? Color(white: 0.1))
            }
          }
        }
      }
    }.aspectRatio(22.0 / 6.0, contentMode: .fit).background(.black).clipShape(RoundedRectangle(cornerRadius: 6))
  }
}
