import Foundation
import Hron
import Testing

enum Spec {
  // This file is swift/Tests/HronTests/Support/Spec.swift.
  static let directory = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in
    url.deletingLastPathComponent()
  }.appendingPathComponent("spec")

  static let tests = JSON.load(directory.appendingPathComponent("tests.json"))
  static let api = JSON.load(directory.appendingPathComponent("api.json"))

  static let defaultNow = tests["now"]!.string!

  static func cases(in category: String, only: [String]? = nil, excluding: [String] = [])
    -> [SpecCase]
  {
    let sections = tests[category]!.keys.filter {
      $0 != "description" && !excluding.contains($0) && (only?.contains($0) ?? true)
    }
    return sections.flatMap { section in
      (tests[category]![section]!["tests"]!.array!).enumerated().map {
        SpecCase(section: "\(category).\(section)", index: $0.offset, fields: $0.element)
      }
    }
  }

  static func flatCases(in category: String) -> [SpecCase] {
    tests[category]!["tests"]!.array!.enumerated().map {
      SpecCase(section: category, index: $0.offset, fields: $0.element)
    }
  }
}

struct SpecCase: Sendable, CustomTestStringConvertible {
  let section: String
  let index: Int
  let fields: JSON

  var name: String { fields["name"]?.string ?? "case \(index)" }
  var testDescription: String { "\(section) \(name)" }

  subscript(key: String) -> JSON? { fields[key] }

  func string(_ key: String) -> String {
    guard let value = fields[key]?.string else {
      Issue.record("\(testDescription): '\(key)' is not a string")
      return ""
    }
    return value
  }

  /// A field this runner does not check, one it cannot read as its type, and a case with none
  /// of the section's assertion fields: each is a case the runner would pass unchecked
  /// (spec/README.md, "Writing a runner").
  func fieldProblems(_ schema: FieldSchema) -> [String] {
    let known = schema.inputs.merging(schema.assertions) { $1 }
    var problems: [String] = []
    for key in fields.keys where !["name", "description"].contains(key) {
      if let type = known[key] {
        if let value = fields[key], !value.isA(type) {
          problems.append("\(testDescription): field '\(key)' is not \(type.rawValue)")
        }
      } else {
        problems.append("\(testDescription): field '\(key)' is not known to this runner")
      }
    }
    let assertions = schema.assertions.keys.sorted()
    if !assertions.isEmpty && !assertions.contains(where: { fields[$0] != nil }) {
      problems.append("\(testDescription) has none of the assertion fields \(assertions)")
    }
    return problems
  }

  func fieldsAreReadable(
    _ schema: FieldSchema, sourceLocation: SourceLocation = #_sourceLocation
  ) -> Bool {
    let problems = fieldProblems(schema)
    #expect(problems == [], sourceLocation: sourceLocation)
    return problems.isEmpty
  }
}

struct FieldSchema {
  let inputs: [String: FieldType]
  let assertions: [String: FieldType]
}

enum FieldType: String {
  case string = "a string"
  case timestampOrNull = "a timestamp or null"
  case integer = "an integer"
  case boolean = "a boolean"
  case list = "a list"
  case object = "an object"
}

extension JSON {
  func isA(_ type: FieldType) -> Bool {
    switch type {
    case .string: string != nil
    case .timestampOrNull: string != nil || isNull
    case .integer: int != nil
    case .boolean: bool != nil
    case .list: array != nil
    case .object: if case .object = self { true } else { false }
    }
  }
}

func thrownError(_ body: () throws(HronError) -> Void) -> HronError? {
  do {
    try body()
    return nil
  } catch {
    return error
  }
}
