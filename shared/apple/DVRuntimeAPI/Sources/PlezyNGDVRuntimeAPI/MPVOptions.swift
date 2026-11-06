import Foundation

public enum MPVOptionsError: Error { case invalidOptions, invalidHeader }

/// Decode the same byte-length quoting used by PlayerNative's loadfile call.
/// Header values may contain commas, equals signs and non-ASCII text.
public enum MPVOptions {
  public static func parse(_ input: String) throws -> [String: String] {
    let bytes = Array(input.utf8)
    var position = 0
    var result: [String: String] = [:]
    while position < bytes.count {
      let keyStart = position
      while position < bytes.count && bytes[position] != 61 && bytes[position] != 44 { position += 1 }
      guard position < bytes.count, bytes[position] == 61, position > keyStart else {
        throw MPVOptionsError.invalidOptions
      }
      let key = String(decoding: bytes[keyStart..<position], as: UTF8.self)
      position += 1
      let value: String
      if position < bytes.count && bytes[position] == 37 {
        position += 1
        let countStart = position
        while position < bytes.count && bytes[position] >= 48 && bytes[position] <= 57 { position += 1 }
        guard position < bytes.count, bytes[position] == 37, position > countStart,
          let count = Int(String(decoding: bytes[countStart..<position], as: UTF8.self)),
          count <= bytes.count - position - 1
        else { throw MPVOptionsError.invalidOptions }
        position += 1
        guard let decoded = String(bytes: bytes[position..<(position + count)], encoding: .utf8) else {
          throw MPVOptionsError.invalidOptions
        }
        value = decoded
        position += count
      } else {
        let start = position
        while position < bytes.count && bytes[position] != 44 { position += 1 }
        value = String(decoding: bytes[start..<position], as: UTF8.self)
      }
      result[key] = value
      if position < bytes.count {
        guard bytes[position] == 44 else { throw MPVOptionsError.invalidOptions }
        position += 1
      }
    }
    return result
  }

  public static func headers(_ input: String) throws -> [String: String] {
    var items: [String] = []
    var current = ""
    let characters = Array(input)
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "\\" && index + 1 < characters.count && characters[index + 1] == "," {
        current.append(",")
        index += 2
      } else if character == "," {
        items.append(current)
        current = ""
        index += 1
      } else {
        current.append(character)
        index += 1
      }
    }
    if !current.isEmpty { items.append(current) }
    return try headers(fromItems: items)
  }

  public static func headers(fromItems items: [String]) throws -> [String: String] {
    let token = CharacterSet(
      charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    var headers: [String: String] = [:]
    for item in items {
      // Swift combines CRLF into one Character, so validate the actual bytes.
      let invalidControl = item.utf8.contains { $0 == 13 || $0 == 10 || $0 == 0 }
      guard !invalidControl,
        let colon = item.firstIndex(of: ":")
      else { throw MPVOptionsError.invalidHeader }
      let name = String(item[..<colon])
      guard !name.isEmpty, name.unicodeScalars.allSatisfy(token.contains) else { throw MPVOptionsError.invalidHeader }
      headers[name] = item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return headers
  }
}
