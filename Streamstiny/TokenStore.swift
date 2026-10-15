import Foundation
import Security

enum TokenStore {
  private static func query(service: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "authtoken",
    ]
  }

  static func read(service: String) -> String? {
    var request = query(service: service)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func save(_ token: String, service: String) throws {
    let query = query(service: service)
    let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.contains("\r"), !value.contains("\n"), !value.contains(";") else {
      throw NSError(
        domain: "TokenStore", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Invalid token characters."])
    }
    if value.isEmpty {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
      return
    }
    let data = Data(value.utf8)
    var status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw failure(status) }
  }

  private static func failure(_ status: OSStatus) -> NSError {
    NSError(
      domain: NSOSStatusErrorDomain, code: Int(status),
      userInfo: [NSLocalizedDescriptionKey: "Could not update the secure token (\(status))."])
  }
}
