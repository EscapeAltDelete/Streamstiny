import SwiftUI
import UserNotifications
@preconcurrency import KSPlayer

@main struct StreamstinyApp: App {
  private let notificationDelegate = ChatNotificationDelegate()
  init() {
    KSOptions.logLevel = .panic
    KSOptions.logger = SilentPlaybackLog()
    UNUserNotificationCenter.current().delegate = notificationDelegate
  }
  var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
  @State private var chat = ChatStore()
  @State private var library = StreamLibrary()
  @State private var emotes = EmoteStore()
  @State private var draft = ""
  @State private var chatTools = false
  @State private var emotePicker = false
  @State private var settings = false
  @State private var sources = false
  @State private var controls = PlaybackControls()
  @State private var showChat = false
  @State private var sending = false
  @State private var mounted = false
  @AppStorage("chatOnLeft") private var chatOnLeft = false
  @AppStorage("chatOverlay") private var chatOverlay = false
  @AppStorage("chatFraction") private var chatFraction = 0.36
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @AppStorage("fontSize") private var fontSize = 15.0
  @AppStorage("timestamps") private var timestamps = false

  var body: some View {
    GeometryReader { geometry in
      let landscape =
        verticalSizeClass == .compact
        || (horizontalSizeClass == .regular && geometry.size.width > geometry.size.height)
      let chatVisible = !landscape || showChat
      let overlay = landscape && chatOverlay
      let layout =
        overlay
        ? AnyLayout(ZStackLayout(alignment: landscape ? (chatOnLeft ? .leading : .trailing) : .bottom))
        : landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
      let chatExtent = ChatSize.extent(
        size: geometry.size,
        fraction: chatFraction, landscape: landscape)
      layout {
        if landscape && chatVisible && !overlay && chatOnLeft {
          chatPanel.frame(width: chatExtent).frame(maxHeight: .infinity)
        }
        PlayerView(
          source: library.selected, blocked: library.banned[library.selected.id],
          doubleTapEnabled: landscape, controls: controls, library: library,
          addStream: { sources = true }
        ) { showChat.toggle() }
        .frame(
          width: landscape && chatVisible && !overlay ? geometry.size.width - chatExtent : nil,
          height: !landscape && chatVisible && !overlay
            ? geometry.size.height - chatExtent : nil
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        if chatVisible && !(landscape && !overlay && chatOnLeft) {
          chatPanel
            .frame(width: landscape ? chatExtent : nil, height: landscape ? nil : chatExtent)
            .frame(maxWidth: landscape ? nil : .infinity, maxHeight: landscape ? .infinity : nil)
        }
      }
    }
    .sheet(isPresented: $settings) { SettingsView(chat: chat).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
    .sheet(isPresented: $sources) { AddStreamView(library: library).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
    .sheet(isPresented: $chatTools) { ChatToolsView(emotes: emotes, chat: chat).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
    .sheet(item: $chat.requestedProfile) { user in ChatUserProfileView(emotes: emotes, initial: user, chat: chat).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
    .sheet(isPresented: $emotePicker) {
      ChatEmotePicker(emotes: emotes, account: chat.account) { name in draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + name + " " }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    .alert(
      "Chat",
      isPresented: Binding(get: { chat.error != nil }, set: { if !$0 { chat.error = nil } })
    ) {
      Button("OK") { chat.error = nil }
    } message: {
      Text(chat.error ?? "")
    }
    .task {
      mounted = true
      emotes.resume()
      chat.start()
      chat.selectedSource = library.selected
      library.start()
      await emotes.load()
    }
    .onDisappear {
      mounted = false
      emotes.releaseMemory(suspend: true)
      Task {
        guard !mounted else { return }
        async let chatStop: Void = chat.stop()
        async let directoryStop: Void = library.stop()
        _ = await (chatStop, directoryStop)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background {
        emotes.releaseMemory(suspend: true)
        Task {
          guard scenePhase == .background else { return }
          async let chatStop: Void = chat.stop()
          async let directoryStop: Void = library.stop()
          _ = await (chatStop, directoryStop)
        }
      } else if phase == .active {
        emotes.resume()
        chat.start()
        library.start()
        Task { await emotes.load() }
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
    ) { _ in
      emotes.releaseMemory()
    }
    .onChange(of: chat.assetRevision) { _, _ in Task { await emotes.load(force: true) } }
    .onChange(of: chat.settingsRevision) { _, _ in emotes.refreshPreferences() }
    .onChange(of: library.selected) { _, source in chat.selectedSource = source }
    .onChange(of: chat.requestedSource) { _, source in
      if let source { library.select(source); chat.requestedSource = nil }
    }
    .onChange(of: chat.requestedReply) { _, nick in
      if let nick { chat.activeRecipient = nil; draft = nick + " "; chat.requestedReply = nil }
    }
    .background(.black)
    .statusBarHidden(true)
    .persistentSystemOverlays(controls.visible ? .visible : .hidden)
  }

  private var chatPanel: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Button { chatTools = true } label: {
          Label("Chat tools", systemImage: "person.2")
        }.labelStyle(.iconOnly).accessibilityLabel("Users, whispers, and search")
        let unread = chat.unreadWhispers.values.reduce(0, +)
        if unread > 0 { Text("\(unread)").font(.caption.monospacedDigit()).foregroundStyle(.tint) }
        if chat.subOnly > 0 { Text("Tier \(chat.subOnly)+").font(.caption2) }
        if let pinned = chat.pinned, chat.dismissedPin == pinned.id {
          Button { chat.dismissedPin = nil } label: { Image(systemName: "pin") }.accessibilityLabel("Show pinned message")
        }
        if chat.poll != nil, !chat.pollVisible {
          Button { chat.pollVisible = true } label: { Image(systemName: "chart.bar") }.accessibilityLabel("Show poll")
        }
        Spacer()
        Button { chat.hideUnfocused.toggle() } label: {
          Image(systemName: "line.3.horizontal.decrease.circle")
            .foregroundStyle(chat.hideUnfocused ? Color.accentColor : .secondary)
        }
        .frame(minWidth: 32, minHeight: 32)
        .accessibilityIdentifier("hideUnfocusedMessages")
        .accessibilityLabel("Hide messages from other streams")
        .accessibilityValue(chat.hideUnfocused ? (chat.watchingFocus ? "Paused while focus is on" : "On") : "Off")
        .help("Hide messages from users not watching this stream; keep highlighted messages. Paused while fade focus is on.")
        Button { chat.watchingFocus.toggle() } label: {
          Image(systemName: "eye").foregroundStyle(chat.watchingFocus ? Color.accentColor : .secondary)
        }
        .accessibilityLabel("Focus viewers watching the same stream")
        .accessibilityValue(chat.watchingFocus ? "On" : "Off")
        Button {
          settings = true
        } label: {
          Image(systemName: "gearshape")
        }
        .font(.body).frame(width: 36, height: 32)
        .accessibilityLabel("Chat settings")
      }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
      if let pinned = chat.pinned, chat.dismissedPin != pinned.id {
        ChatPinView(message: pinned, chat: chat, emotes: emotes, fontSize: fontSize,
          onStream: { library.select($0) })
      }
      if let poll = chat.poll, chat.pollVisible { ChatPollView(poll: poll, chat: chat) }
      if !chat.paidEvents.isEmpty {
        ChatEventBar(chat: chat, emotes: emotes, fontSize: fontSize, onStream: { library.select($0) })
      }
      ChatList(
        messages: emotes.combining(chat.visibleMessages), emotes: emotes,
        fontSize: fontSize, timestamps: timestamps,
        onReply: { draft = "\($0) " }, onWhisper: { chat.openConversation($0) },
        onIgnore: { chat.ignore($0) }, onStream: { library.select($0) }, chat: chat,
        stateRevision: chat.renderingRevision ^ emotes.revision, watchingFocus: chat.watchingFocus
      )
      .accessibilityIdentifier("chat")
      if let status = emotes.status {
        Text(status).font(.caption2).foregroundStyle(.secondary).padding(4)
      }
      if let recipient = chat.activeRecipient {
        HStack {
          Text("Whisper to \(recipient)").font(.caption)
          if DestinyAccount.hasSession {
            Button("Earlier") { Task { await chat.loadConversation(recipient, older: true) } }.font(.caption)
          }
          Spacer()
          Button("Back to chat") { chat.activeRecipient = nil }
        }.padding(.horizontal)
      }
      HStack(alignment: .bottom) {
        TextField(
          chat.identity != nil ? "Message chat" : "Sign in through Account settings", text: $draft,
          axis: .vertical
        ).lineLimit(1...4).textFieldStyle(.roundedBorder).onSubmit { send() }
        Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
          .disabled(
            sending || (!chat.canSend && !draft.hasPrefix("/"))
              || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ).accessibilityLabel("Send message")
      }.padding(12)
      HStack {
        Button { emotePicker = true } label: { Image(systemName: "face.smiling") }.accessibilityLabel("Choose emote")
        if UserDefaults.standard.object(forKey: "chatAutocomplete") as? Bool ?? true {
          ChatCompletionBar(draft: $draft, users: chat.users, emotes: emotes, account: chat.account)
        }
      }.padding(.horizontal, 12).padding(.bottom, 6)
    }.background(Color(.systemBackground))
  }

  private func send() {
    guard !sending else { return }
    let text = draft
    let target = chat.activeRecipient
    sending = true
    Task {
      if await chat.send(text, recipient: target), draft == text { draft = "" }
      sending = false
    }
  }
}

struct AddStreamView: View {
  let library: StreamLibrary
  @State private var input = ""
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section("Stream URL") {
          TextField("Paste a stream URL", text: $input).keyboardType(.URL)
            .textInputAutocapitalization(
              .never
            ).autocorrectionDisabled()
          Button {
            do {
              library.select(try StreamSource.parse(input))
              dismiss()
            } catch { self.error = error.localizedDescription }
          } label: { Label("Watch stream", systemImage: "play.fill") }
          .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
      }.navigationTitle("Add stream").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
  }
}
