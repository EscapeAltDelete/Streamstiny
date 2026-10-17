import Foundation

enum ChatEncodingTests {
  static func run() throws {
    let cases: [(String, String?, String)] = [
      ("  Hello\n", nil, #"MSG {"data":"Hello"}"#),
      ("Hello", "EscapeAltDelete", #"PRIVMSG {"data":"Hello","nick":"EscapeAltDelete"}"#),
      ("Hello", "", #"PRIVMSG {"data":"Hello"}"#),
    ]
    for (text, recipient, expected) in cases {
      let encoded = try ChatProtocol.encode(text: text, recipient: recipient)
      precondition(encoded == expected, "Keep the existing chat wire format")
    }
    let text = "Hello \"world\"\n👋"
    let encoded = try ChatProtocol.encode(text: text)
    let payload = try JSONSerialization.jsonObject(with: Data(encoded.dropFirst(4).utf8)) as! [String: String]
    precondition(payload == ["data": text], "Keep escaping and Unicode content")
    _ = try ChatProtocol.encode(text: String(repeating: "👋", count: 500))
    for invalid in ["", " \n\t", String(repeating: "a", count: 501)] {
      do {
        _ = try ChatProtocol.encode(text: invalid)
        preconditionFailure("Invalid message lengths must remain rejected")
      } catch ChatInputError.invalidLength {}
    }
    print("Passed chat encoding, whisper recipient, Unicode, escaping, and length regressions")
  }
}
