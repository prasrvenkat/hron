import Foundation

enum JSON: Sendable, Equatable, Decodable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSON])
  case object([String: JSON])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSON].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSON].self))
    }
  }

  static func load(_ url: URL) -> JSON {
    do {
      return try JSONDecoder().decode(JSON.self, from: Data(contentsOf: url))
    } catch {
      fatalError("cannot read \(url.path): \(error)")
    }
  }

  subscript(key: String) -> JSON? {
    if case .object(let fields) = self { fields[key] } else { nil }
  }

  var keys: [String] {
    if case .object(let fields) = self { fields.keys.sorted() } else { [] }
  }

  var string: String? {
    if case .string(let value) = self { value } else { nil }
  }

  var bool: Bool? {
    if case .bool(let value) = self { value } else { nil }
  }

  var int: Int? {
    if case .number(let value) = self { Int(exactly: value) } else { nil }
  }

  var array: [JSON]? {
    if case .array(let items) = self { items } else { nil }
  }

  var isNull: Bool { self == .null }
}
