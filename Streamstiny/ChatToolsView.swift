import SwiftUI

struct ChatPollView: View {
  let poll: ChatPoll
  let chat: ChatStore
  @State private var expanded = false
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button { expanded.toggle() } label: {
          VStack(alignment: .leading, spacing: 2) {
            Label(poll.question, systemImage: "chart.bar").font(.caption.weight(.semibold)).lineLimit(2)
            Text("\(poll.ended ? "Results" : "Vote") · \(poll.total) \(poll.weighted ? "weighted votes" : "votes")").font(.caption2)
          }.frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: expanded ? "chevron.up" : "chevron.down")
        }.buttonStyle(.plain)
        Button { chat.pollVisible = false } label: { Image(systemName: "xmark") }.accessibilityLabel("Hide poll")
      }
      if expanded {
        if !poll.ended { Text(poll.ends, style: .timer).font(.caption).monospacedDigit() }
        ScrollView {
          VStack(spacing: 8) {
            ForEach(poll.options.indices, id: \.self) { index in
              Button { Task { _ = await chat.vote(index + 1) } } label: {
                VStack(alignment: .leading) {
                  HStack {
                    Text(poll.options[index])
                    Spacer()
                    if poll.myVote == index + 1 { Image(systemName: "checkmark") }
                    Text("\(poll.totals[index])").monospacedDigit()
                  }
                  ProgressView(value: Double(poll.totals[index]), total: Double(max(1, poll.total)))
                }.font(.caption).foregroundStyle(.primary)
              }.disabled(poll.ended || !poll.canVote || chat.votePending || chat.identity == nil)
            }
          }
        }.frame(maxHeight: 150)
        if chat.account?.canPoll == true, !poll.ended {
          Button("Stop poll", role: .destructive) { Task { _ = await chat.send("/pollstop") } }.font(.caption)
        }
      }
    }.padding(8).background(.tint.opacity(0.08)).onChange(of: poll.id) { _, _ in expanded = false }
  }
}

struct ChatPinView: View {
  let message: ChatMessage
  let chat: ChatStore
  let emotes: EmoteStore
  let fontSize: Double
  let onStream: (StreamSource) -> Void
  @State private var expanded = false
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button { expanded.toggle() } label: {
          Label(expanded ? "Pinned message" : "\(message.nick): \(message.text)", systemImage: "pin.fill")
            .font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: expanded ? "chevron.up" : "chevron.down")
        }.buttonStyle(.plain).accessibilityLabel(expanded ? "Collapse pin" : "Expand pin")
        Button { chat.dismissPinned() } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss pin")
      }.padding(8)
      if expanded {
        ChatList(messages: [message], emotes: emotes, fontSize: fontSize, timestamps: true,
          onReply: { chat.requestedReply = $0 }, onWhisper: { chat.openConversation($0) },
          onIgnore: { chat.ignore($0) }, onStream: onStream, chat: chat, stateRevision: chat.renderingRevision ^ emotes.revision, backgroundColor: .clear)
          .frame(height: 150)
        if chat.account?.moderator == true {
          Button("Unpin", role: .destructive) { Task { _ = await chat.send("/unpin") } }.font(.caption).padding(4)
        }
      }
    }.background(.quaternary).onChange(of: message.id) { _, _ in expanded = false }
  }
}

struct ChatToolsView: View {
  let emotes: EmoteStore
  @Bindable var chat: ChatStore
  @Environment(\.dismiss) private var dismiss
  @AppStorage("focusChatMentions") private var focusMentions = false
  @State private var search = ""
  @State private var profile: ChatUser?
  var body: some View {
    NavigationStack {
      List {
        Section("Messages") {
          TextField("Search chat", text: $chat.filter)
          Toggle("Only messages mentioning me", isOn: $focusMentions)
          Toggle("Fade messages watching other streams", isOn: $chat.watchingFocus)
          Toggle("Hide messages watching other streams", isOn: $chat.hideUnfocused)
          if chat.hideUnfocused && chat.watchingFocus { Text("Hiding is paused while fade focus is on.").font(.caption).foregroundStyle(.secondary) }
          Button("Clear search") { chat.filter = ""; focusMentions = false }
        }
        if let identity = chat.identity {
          Section("Account") {
            Text(identity)
            if chat.banned { Text("Banned from chat").foregroundStyle(.red) }
            if let until = chat.mutedUntil, until > Date() {
              HStack { Text("Muted for"); Text(until, style: .timer) }
            }
            Link("Profile and ban information", destination: URL(string: "https://www.destiny.gg/profile")!)
          }
        }
        Section("Whispers") {
          ForEach(chat.conversationNames.keys.sorted(), id: \.self) { nick in
            Button {
              chat.openConversation(nick); dismiss()
            } label: {
              HStack {
                VStack(alignment: .leading) {
                  Text(chat.conversationNames[nick] ?? nick)
                  if let preview = chat.conversationPreviews[nick] { Text(preview).font(.caption).lineLimit(1).foregroundStyle(.secondary) }
                }
                Spacer()
                if let count = chat.unreadWhispers[nick], count > 0 { Text("\(count)").monospacedDigit() }
              }
            }
          }
          if chat.conversationNames.isEmpty { Text("Long press a message to start a whisper.").foregroundStyle(.secondary) }
          if chat.loadingConversations { ProgressView("Loading conversations…") }
          if chat.moreConversations { Button("More conversations") { Task { await chat.loadConversations(more: true) } } }
          Button("Return to public chat") { chat.activeRecipient = nil; dismiss() }
        }
        Section("Users (\(chat.users.count))") {
          TextField("Find user", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
          ForEach(chat.users.values.filter { search.isEmpty || $0.nick.localizedCaseInsensitiveContains(search) }.sorted { $0.id < $1.id }) { user in
            Menu {
              Button { profile = user } label: { Label("Profile and badges", systemImage: "person.crop.circle") }
              Button { chat.openConversation(user.nick); dismiss() } label: { Label("Whisper", systemImage: "envelope") }
              Button(chat.ignored.contains(user.id) ? "Unignore" : "Ignore") {
                if chat.ignored.contains(user.id) { chat.unignore(user.nick) } else { chat.ignore(user.nick) }
              }
              Button(chat.highlighted.contains(user.id) ? "Remove highlight" : "Highlight") {
                chat.highlight(user.nick, enabled: !chat.highlighted.contains(user.id))
              }
            } label: {
              HStack {
                Text(user.nick)
                Spacer()
                Text(user.moderator ? "Moderator" : user.tier > 0 ? "Tier \(user.tier)" : "")
                  .font(.caption).foregroundStyle(.secondary)
              }.foregroundStyle(.primary)
            }
          }
        }
        Section("Ignored users") {
          ForEach(chat.ignored.sorted(), id: \.self) { nick in
            HStack { Text(nick); Spacer(); Button("Unignore") { chat.unignore(nick) } }
          }
        }
        Section { Text(ChatStore.commandHelp).font(.caption).textSelection(.enabled) }
      }.listStyle(.insetGrouped).navigationTitle("Chat tools").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(item: $profile) { user in ChatUserProfileView(emotes: emotes, initial: user, chat: chat) }
        .task { await chat.loadConversations() }
    }
  }
}

struct ChatEmotePicker: View {
  let emotes: EmoteStore
  let account: ChatUser?
  let insert: (String) -> Void
  @State private var search = ""
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let status = emotes.status { Text(status).font(.caption).foregroundStyle(.secondary).padding(8) }
        ChatAssetView(emotes: emotes, mode: "picker", account: account, search: search,
          onInsert: { name in insert(name); dismiss() }, favorites: emotes.favorites, revision: emotes.revision)
      }
        .searchable(text: $search).navigationTitle("Emotes").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    .task { await emotes.load() }
  }
}

struct ChatCompletionBar: View {
  @Binding var draft: String
  let users: [String: ChatUser]
  let emotes: EmoteStore
  let account: ChatUser?
  private var token: String { draft.last?.isWhitespace == true ? "" : String(draft.split(whereSeparator: { $0.isWhitespace }).last ?? "") }
  private var suggestions: [String] {
    guard token.count >= 2 else { return [] }
    let needle = token.hasPrefix("@") ? String(token.dropFirst()) : token
    if token.hasPrefix("/") {
      return ["/help", "/me", "/w", "/ignore", "/unignore", "/highlight", "/poll", "/spoll", "/showpoll", "/stalk", "/mentions", "/pin"]
        .filter { $0.hasPrefix(token.lowercased()) }
    }
    let names = users.values.filter { $0.nick.lowercased().hasPrefix(needle.lowercased()) }.map { (token.hasPrefix("@") ? "@" : "") + $0.nick }
    return Array((names + emotes.catalog.keys.filter { emotes.canUse($0, user: account) && $0.lowercased().hasPrefix(needle.lowercased()) }).sorted().prefix(8))
  }
  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack {
        ForEach(suggestions, id: \.self) { suggestion in
          Button(suggestion) { draft = String(draft.dropLast(token.count)) + suggestion + " " }
            .font(.caption).buttonStyle(.bordered)
        }
      }
    }
  }
}
