import SwiftUI
import UserNotifications

struct SettingsView: View {
  let chat: ChatStore
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        NavigationLink { ChatLayoutPreferencesView() } label: {
          Label("General", systemImage: "gearshape")
        }
        NavigationLink { PlaybackPreferencesView() } label: {
          Label("Player", systemImage: "play.circle")
        }
        NavigationLink { ChatPreferencesView(chat: chat) } label: {
          Label("Chat", systemImage: "bubble.left.and.bubble.right")
        }
        NavigationLink { NotificationPreferencesView(chat: chat) } label: {
          Label("Notifications", systemImage: "bell")
        }
        NavigationLink { AccountPreferencesView(chat: chat) } label: {
          Label("Accounts", systemImage: "person.crop.circle")
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }
}

struct PlaybackPreferencesView: View {
  @AppStorage("automaticCatchUp") private var automaticCatchUp = false
  @AppStorage("targetBuffer") private var targetBuffer = 3.0
  @AppStorage("highestQuality") private var highestQuality = false
  @AppStorage("twitchLowLatency") private var twitchLowLatency = false
  @AppStorage("kickLowLatency") private var kickLowLatency = false
  @AppStorage("youtubeLowLatency") private var youtubeLowLatency = false
  @AppStorage("angelthumpLowLatency") private var angelthumpLowLatency = false
  @AppStorage("twitchAdBlocking") private var twitchAdBlocking = false
  @AppStorage("showViewers") private var showViewers = false
  @AppStorage("showDGGViewers") private var showDGGViewers = false
  @AppStorage("showBitrate") private var showBitrate = false
  var body: some View {
    Form {
      Section {
        Toggle("Automatic catch-up", isOn: $automaticCatchUp)
        Stepper(value: $targetBuffer, in: 0...20, step: 1) {
          LabeledContent("Target buffer", value: "\(Int(targetBuffer)) s")
        }.disabled(!automaticCatchUp)
      } header: { Text("Live buffer") } footer: {
        Text("Speeds up to 2× when the live buffer is above your target, then returns to normal.")
      }
      Section("Quality") {
        Toggle("Start at highest quality", isOn: $highestQuality)
      }
      Section {
        Toggle("Low latency", isOn: $twitchLowLatency)
        Toggle("Block Twitch ads", isOn: $twitchAdBlocking)
      } header: { Text("Twitch") } footer: {
        Text("Low latency downloads video segments before they finish and may buffer more on slower connections. Ad blocking uses a clean alternative stream when available and waits instead of playing detected ads when none is available. Quality may temporarily decrease during ads and returns when the selected stream is clean. Applies when opening or reloading a stream.")
      }
      Section {
        Toggle("Low latency", isOn: $kickLowLatency)
      } header: { Text("Kick") } footer: {
        Text("Downloads advertised video segments before they finish. May buffer more on slower connections.")
      }
      Section {
        Toggle("Low latency", isOn: $youtubeLowLatency)
      } header: { Text("YouTube") } footer: {
        Text("Experimental. Starts at the newest available live segment and may buffer more. YouTube's broadcast latency still applies.")
      }
      Section {
        Toggle("Low latency", isOn: $angelthumpLowLatency)
      } header: { Text("AngelThump") } footer: {
        Text("Starts closer to the live edge using completed segments. This is not early-segment streaming and may buffer more on slower connections.")
      }
      Section("Stream information") {
        Toggle("Show Bitrate", isOn: $showBitrate)
        Toggle("Show DGG viewers", isOn: $showDGGViewers)
        Toggle("Show overall stream viewers", isOn: $showViewers)
      }
    }.navigationTitle("Player").navigationBarTitleDisplayMode(.inline)
  }
}

private struct ChatLayoutPreferencesView: View {
  @AppStorage("chatOnLeft") private var chatOnLeft = false
  @AppStorage("chatOverlay") private var chatOverlay = false
  @AppStorage("chatFraction") private var chatFraction = 0.36
  var body: some View {
    Form {
      Section("Landscape layout") {
        Picker("Chat position", selection: $chatOnLeft) {
          Text("Left").tag(true)
          Text("Right").tag(false)
        }
        Toggle("Overlay chat", isOn: $chatOverlay).accessibilityIdentifier("chatOverlay")
      }
      Section {
        LabeledContent("Landscape chat size", value: "\(Int((chatFraction * 100).rounded()))%")
        Slider(value: $chatFraction, in: 0.25...0.65, step: 0.01) { Text("Chat size") }
          .accessibilityIdentifier("chatSize")
      } footer: {
        Text("In portrait, chat fills the space below the video regardless of this limit.")
      }
    }.navigationTitle("General").navigationBarTitleDisplayMode(.inline)
  }
}

private struct ChatPreferencesView: View {
  let chat: ChatStore
  @AppStorage("fontSize") private var fontSize = 15.0
  @AppStorage("timestamps") private var timestamps = false
  @AppStorage("disableMentionHighlight") private var disableMentionHighlight = false
  @AppStorage("hideFlairIcons") private var hideFlairIcons = false
  @AppStorage("disableEmoteAnimations") private var disableEmoteAnimations = false
  @AppStorage("disableEmoteCombos") private var disableEmoteCombos = false
  @AppStorage("maximumChatMessages") private var maximumChatMessages = 1000
  @AppStorage("customChatHighlights") private var customHighlights = ""
  @AppStorage("hideNSFWLinks") private var hideNSFW = false
  @AppStorage("hideNSFLLinks") private var hideNSFL = false
  @AppStorage("censorChatWords") private var censorWords = false
  @AppStorage("censoredChatWords") private var censoredWords = "fuck, shit, cunt"
  @AppStorage("showWhispersInChat") private var showWhispers = false
  @AppStorage("removedChatMessages") private var removedMessages = 1
  @AppStorage("previewChatImages") private var previewImages = false
  @AppStorage("harshIgnore") private var harshIgnore = false
  @AppStorage("chatAutocomplete") private var autocomplete = true
  @AppStorage("focusChatMentions") private var focusMentions = false
  @AppStorage("highlightChatTags") private var highlightTags = false
  @AppStorage("syncWebsiteChatSettings") private var automaticSync = true
  @State private var syncResult: String?
  @State private var syncing = false
  var body: some View {
    Form {
      Section("Appearance") {
        Toggle("Show timestamps", isOn: $timestamps)
        Toggle("Show badges", isOn: Binding(get: { !hideFlairIcons }, set: { hideFlairIcons = !$0 }))
        LabeledContent("Text size", value: "\(Int(fontSize))")
        Slider(value: $fontSize, in: 12...26, step: 1) { Text("Text size") }
      }
      Section("Messages") {
        Toggle("Highlight mentions of me", isOn: Binding(get: { !disableMentionHighlight }, set: { disableMentionHighlight = !$0 }))
        Toggle("Highlight tagged users", isOn: $highlightTags)
        Toggle("Focus messages mentioning me", isOn: $focusMentions)
        TextField("Highlight words, separated by commas", text: $customHighlights)
        Picker("Deleted messages", selection: $removedMessages) {
          Text("Hide").tag(0)
          Text("Show placeholder").tag(1)
          Text("Show original text").tag(2)
        }
        Stepper("Keep \(maximumChatMessages) messages", value: $maximumChatMessages, in: 100...5000, step: 100)
          .onChange(of: maximumChatMessages) { _, count in chat.setMaximumMessages(count) }
      }
      Section("Emotes") {
        Toggle("Animate emotes", isOn: Binding(get: { !disableEmoteAnimations }, set: { disableEmoteAnimations = !$0 }))
        Toggle("Combine repeated emotes", isOn: Binding(get: { !disableEmoteCombos }, set: { disableEmoteCombos = !$0 }))
      }
      Section("Interaction") {
        Toggle("Show typing suggestions", isOn: $autocomplete)
        Toggle("Show whispers in public chat", isOn: $showWhispers)
        Toggle("Hide messages mentioning ignored users", isOn: $harshIgnore)
        Button("Clear ignored users (\(chat.ignored.count))") { chat.clearIgnored() }
      }
      Section("Links and language") {
        Toggle("Load image previews", isOn: $previewImages)
        Toggle("Hide links marked NSFW", isOn: $hideNSFW)
        Toggle("Hide links marked NSFL", isOn: $hideNSFL)
        Toggle("Censor words", isOn: $censorWords)
        if censorWords { TextField("Words to censor, separated by commas", text: $censoredWords) }
      }
      if DestinyAccount.hasSession {
        Section("Website settings") {
          Toggle("Sync chat settings with Destiny.gg", isOn: $automaticSync)
            .onChange(of: automaticSync) { _, enabled in if enabled { sync(save: false) } }
          if !automaticSync {
            Button("Load from Destiny.gg") { sync(save: false) }.disabled(syncing)
            Button("Save to Destiny.gg") { sync(save: true) }.disabled(syncing)
          }
          if syncing { ProgressView() }
          if let syncResult { Text(syncResult).font(.caption) }
        }
      }
    }.navigationTitle("Chat").navigationBarTitleDisplayMode(.inline)
      .onDisappear {
        chat.settingsChanged()
        if automaticSync, DestinyAccount.hasSession, chat.identity != nil {
          Task {
            do { try await ChatPreferences.save(from: chat) }
            catch is CancellationError {} catch { chat.error = "Website settings: " + error.localizedDescription }
          }
        }
      }
  }
  private func sync(save: Bool) {
    syncing = true
    Task {
      defer { syncing = false }
      do {
        if save { try await ChatPreferences.save(from: chat) } else { try await ChatPreferences.load(into: chat) }
        syncResult = save ? "Website settings saved." : "Website settings loaded."
      } catch { syncResult = error.localizedDescription }
    }
  }
}

private struct NotificationPreferencesView: View {
  let chat: ChatStore
  @AppStorage("notifyChatWhispers") private var notifyWhispers = false
  @AppStorage("notifyChatMentions") private var notifyMentions = false
  @State private var failure: String?
  var body: some View {
    Form {
      Section {
        Toggle("Whispers", isOn: $notifyWhispers)
        Toggle("Mentions", isOn: $notifyMentions)
      } header: { Text("Chat alerts") } footer: {
        Text("Notifications arrive while Streamstiny is active. Chat pauses in the background.")
      }
      if let failure { Text(failure).foregroundStyle(.secondary) }
    }
    .navigationTitle("Notifications").navigationBarTitleDisplayMode(.inline)
    .onChange(of: notifyWhispers || notifyMentions) { _, enabled in
      if enabled {
        Task {
          do {
            if try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) == false {
              notifyWhispers = false; notifyMentions = false
              failure = "Notifications are disabled in iOS Settings."
            }
          } catch { failure = error.localizedDescription }
        }
      }
    }
    .onDisappear {
      if ChatPreferences.automaticSync, DestinyAccount.hasSession, chat.identity != nil {
        Task {
          do { try await ChatPreferences.save(from: chat) }
          catch is CancellationError {} catch { chat.error = "Website settings: " + error.localizedDescription }
        }
      }
    }
  }
}

private struct AccountPreferencesView: View {
  let chat: ChatStore
  @State private var twitch = TwitchAccount.shared
  @State private var destinySignIn = false
  @State private var twitchSignIn = false
  @State private var failure: String?
  @AppStorage("destinyLogin") private var destinyLogin = ""
  var body: some View {
    Form {
      AccountSection(service: "Destiny.gg", username: DestinyAccount.hasSession ? chat.identity ?? (destinyLogin.isEmpty ? nil : destinyLogin) : nil,
        signIn: { destinySignIn = true }, signOut: {
          do { try DestinyAccount.signOut(); Task { await chat.restart() } }
          catch { failure = error.localizedDescription }
        })
      AccountSection(service: "Twitch", username: twitch.linked ? twitch.login ?? "Twitch account" : nil,
        signIn: { twitchSignIn = true }, signOut: { Task { await twitch.signOut() } })
      if let failure { Section { Text(failure).font(.callout).foregroundStyle(.secondary) } }
      if let message = twitch.message { Section { Text(message).font(.callout).foregroundStyle(.secondary) } }
    }.navigationTitle("Accounts").navigationBarTitleDisplayMode(.inline)
      .sheet(isPresented: $destinySignIn) { DestinyLoginView(chat: chat) }
      .sheet(isPresented: $twitchSignIn) {
        NavigationStack {
          TwitchLoginView { twitchSignIn = false }
            .navigationTitle("Twitch sign-in").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { twitchSignIn = false } } }
        }
      }
  }
}

private struct AccountSection: View {
  let service: String
  let username: String?
  let signIn: () -> Void
  let signOut: () -> Void
  var body: some View {
    Section(service) {
      Button(action: signIn) {
        Label {
          Text(username.map { "Signed in as \($0)" } ?? "Sign in to \(service)")
            .foregroundStyle(username == nil ? Color.accentColor : Color.primary)
        } icon: {
          Image(systemName: username == nil ? "person.crop.circle" : "checkmark.circle.fill")
            .foregroundStyle(username == nil ? Color.accentColor : Color.green)
        }
      }.disabled(username != nil)
      if username != nil {
        Button(role: .destructive, action: signOut) { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
      }
    }
  }
}
