import Foundation
import UserNotifications

enum ChatPreferences {
  static var automaticSync: Bool { UserDefaults.standard.object(forKey: "syncWebsiteChatSettings") as? Bool ?? true }
  static var removedMessages: Int { UserDefaults.standard.object(forKey: "removedChatMessages") as? Int ?? 1 }
  @MainActor private static var cachedRules: ChatTextRules?
  @MainActor static var textRules: ChatTextRules {
    let defaults = UserDefaults.standard
    let configuration = ChatTextRules.Configuration(
      highlights: defaults.string(forKey: "customChatHighlights") ?? "",
      censoredWords: defaults.string(forKey: "censoredChatWords") ?? "fuck, shit, cunt",
      censorWords: defaults.bool(forKey: "censorChatWords"),
      hideNSFW: defaults.bool(forKey: "hideNSFWLinks"), hideNSFL: defaults.bool(forKey: "hideNSFLLinks"))
    if let cachedRules, cachedRules.configuration == configuration { return cachedRules }
    let rules = ChatTextRules(configuration)
    cachedRules = rules
    return rules
  }
  @MainActor static var customHighlights: [String] { textRules.customHighlights }
  @MainActor static func highlighted(_ text: String) -> Bool { textRules.highlighted(text) }
  @MainActor static func sensitive(_ text: String) -> Bool { textRules.sensitive(text) }
  @MainActor static func censored(_ text: String) -> String { textRules.censored(text) }
  // Merge supported native preferences into the existing website settings,
  // retaining keys that this client does not own.
  private static let mapping: [(web: String, native: String, inverted: Bool)] = [
    ("previewallimages", "previewChatImages", false), ("ignorementions", "harshIgnore", false),
    ("focusmentioned", "focusChatMentions", false), ("autocompletehelper", "chatAutocomplete", false),
    ("notificationwhisper", "notifyChatWhispers", false), ("notificationhighlight", "notifyChatMentions", false),
    ("taggedvisibility", "highlightChatTags", false),
    ("showtime", "timestamps", false), ("hideflairicons", "hideFlairIcons", false),
    ("disableanimations", "disableEmoteAnimations", false), ("highlight", "disableMentionHighlight", true),
    ("hidensfw", "hideNSFWLinks", false), ("hidensfl", "hideNSFLLinks", false),
    ("censorbadwords", "censorChatWords", false), ("showhispersinchat", "showWhispersInChat", false),
  ]
  @MainActor static func load(into chat: ChatStore) async throws {
    let identity = chat.identity
    let data = try await DestinyAccount.request("/api/chat/me/settings")
    guard identity != nil, chat.identity == identity else { throw ChatInputError.loginRequired }
    guard let entries = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
      throw ChatInputError.invalidCommand("Website settings could not be read.")
    }
    let values = Dictionary(entries.compactMap { entry -> (String, Any)? in
      guard entry.count == 2, let key = entry[0] as? String else { return nil }
      return (key, entry[1])
    }, uniquingKeysWith: { _, new in new })
    let defaults = UserDefaults.standard
    for item in mapping {
      if let value = values[item.web] as? Bool { defaults.set(item.inverted ? !value : value, forKey: item.native) }
    }
    if let count = values["maxlines"] as? Int { chat.setMaximumMessages(count) }
    if let mode = values["showremoved"] as? Int { defaults.set(min(2, max(0, mode)), forKey: "removedChatMessages") }
    if let format = values["timestampformat"] as? String { defaults.set(format, forKey: "chatTimestampFormat") }
    if let terms = values["customhighlight"] as? [String] { defaults.set(terms.joined(separator: ", "), forKey: "customChatHighlights") }
    if let favorites = values["favoriteemotes"] as? [String] { defaults.set(favorites, forKey: "favoriteEmotes") }
    if let ignored = values["ignorenicks"] as? [String] {
      chat.replaceIgnored(ignored)
    }
    if let highlights = values["highlightnicks"] as? [String] {
      chat.replaceHighlighted(highlights)
    }
    if let colors = values["taggednicks"] as? [[String]] {
      chat.tagColors = Dictionary(colors.filter { $0.count == 2 && ChatStore.tagColorNames.contains($0[1]) }.map { ($0[0].lowercased(), $0[1]) }, uniquingKeysWith: { _, new in new })
    }
    if let notes = values["taggednotes"] as? [[String]] {
      chat.tags = Dictionary(notes.filter { $0.count == 2 }.map { ($0[0].lowercased(), $0[1]) }, uniquingKeysWith: { _, new in new })
    }
    defaults.set(chat.tags, forKey: "chatTags"); defaults.set(chat.tagColors, forKey: "chatTagColors")
    if defaults.bool(forKey: "notifyChatWhispers") || defaults.bool(forKey: "notifyChatMentions") {
      _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    chat.settingsChanged()
  }
  @MainActor static func save(from chat: ChatStore) async throws {
    let identity = chat.identity
    let data = try await DestinyAccount.request("/api/chat/me/settings")
    guard identity != nil, chat.identity == identity else { throw ChatInputError.loginRequired }
    guard let entries = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
      throw ChatInputError.invalidCommand("Existing website settings could not be read; nothing was overwritten.")
    }
    var values = Dictionary(entries.compactMap { entry -> (String, Any)? in
      guard entry.count == 2, let key = entry[0] as? String else { return nil }
      return (key, entry[1])
    }, uniquingKeysWith: { _, new in new })
    let defaults = UserDefaults.standard
    for item in mapping {
      let value = defaults.bool(forKey: item.native)
      values[item.web] = item.inverted ? !value : value
    }
    values["maxlines"] = defaults.integer(forKey: "maximumChatMessages") == 0 ? 1000 : defaults.integer(forKey: "maximumChatMessages")
    values["showremoved"] = removedMessages
    values["timestampformat"] = defaults.string(forKey: "chatTimestampFormat") ?? "HH:mm"
    values["customhighlight"] = customHighlights
    values["ignorenicks"] = chat.ignored.sorted()
    values["highlightnicks"] = chat.highlighted.sorted()
    values["favoriteemotes"] = defaults.stringArray(forKey: "favoriteEmotes") ?? []
    values["taggednicks"] = chat.tagColors.keys.sorted().map { [$0, chat.tagColors[$0]!] }
    values["taggednotes"] = chat.tags.keys.sorted().map { [$0, chat.tags[$0]!] }
    values["profilesettings"] = true
    let body = try JSONSerialization.data(withJSONObject: values.keys.sorted().map { [$0, values[$0]!] as [Any] })
    let reply = try await DestinyAccount.request("/api/chat/me/settings", method: "POST", body: body)
    if let response = try? JSONSerialization.jsonObject(with: reply, options: .fragmentsAllowed) as? [String: Any],
      response["success"] as? Bool == false || response["error"] != nil {
      throw ChatInputError.invalidCommand(response["message"] as? String ?? "Website settings were not saved.")
    }
  }
  static func notify(_ message: ChatMessage) {
    let content = UNMutableNotificationContent()
    content.title = message.whisper ? "\(message.nick) whispered" : "\(message.nick) mentioned you"
    content.body = String(message.text.prefix(300))
    content.sound = .default
    let request = UNNotificationRequest(identifier: "chat:" + message.id, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
  }
  static func clearNotifications() { UNUserNotificationCenter.current().removeAllDeliveredNotifications() }
}

final class ChatNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}
