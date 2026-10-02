import Foundation
import Hron
import Testing

/// Every member of spec/api.json, called through its Swift name from the `swift` note. Swift
/// cannot list a type's members by reflection, so each name maps to a call by hand.
@Suite struct APIConformanceTests {
  typealias Call = @Sendable () throws -> Void

  static let now = Timestamp.date("2026-02-06T12:00:00+00:00[UTC]")
  static let schedule = try! Schedule.parse("every day at 09:00 except dec 25 in America/New_York")
  static let error = HronError.parse(
    "expected 'at', got end of input", span: HronError.Span(start: 9, end: 9),
    input: "every day", suggestion: "every day at 09:00")

  static let calls: [String: Call] = [
    "schedule.staticMethods.parse": { () throws in
      #expect(try Schedule.parse("every day at 9:00").description == "every day at 09:00")
    },
    "schedule.staticMethods.fromCron": { () throws in
      #expect(try Schedule.fromCron("0 9 * * 1-5").description == "every weekday at 09:00")
    },
    "schedule.staticMethods.validate": {
      #expect(Schedule.validate("every day at 09:00"))
      #expect(!Schedule.validate("every day"))
    },
    "schedule.instanceMethods.nextFrom": {
      #expect(
        schedule.next(after: now) == Timestamp.date("2026-02-06T09:00:00-05:00[America/New_York]"))
    },
    "schedule.instanceMethods.nextNFrom": {
      #expect(schedule.next(2, after: now).count == 2)
    },
    "schedule.instanceMethods.previousFrom": {
      #expect(
        schedule.previous(before: now)
          == Timestamp.date("2026-02-05T09:00:00-05:00[America/New_York]"))
    },
    "schedule.instanceMethods.matches": {
      #expect(schedule.matches(Timestamp.date("2026-02-06T14:00:00+00:00[UTC]")))
    },
    "schedule.instanceMethods.occurrences": {
      #expect(Array(schedule.occurrences(after: now).prefix(3)) == schedule.next(3, after: now))
    },
    "schedule.instanceMethods.between": {
      let through = Timestamp.date("2026-02-09T14:00:00+00:00[UTC]")
      #expect(Array(schedule.occurrences(after: now, through: through)).count == 4)
    },
    "schedule.instanceMethods.toCron": { () throws in
      #expect(try Schedule.parse("every day at 09:00").toCron() == "0 9 * * *")
    },
    "schedule.instanceMethods.toString": {
      #expect(schedule.description == "every day at 09:00 except dec 25 in America/New_York")
    },
    "schedule.instanceMethods.equals": { () throws in
      let reparsed = try Schedule.parse(schedule.description)
      #expect(schedule == reparsed)
    },
    "schedule.getters.timezone": {
      #expect(schedule.timeZoneIdentifier == "America/New_York")
    },
    "schedule.getters.expression": { () throws in
      let daily = try Schedule.parse("every day at 09:00")
      #expect(schedule.expression == daily.expression)
    },
    "schedule.getters.except": {
      #expect(schedule.except == [.named(month: .december, day: 25)])
    },
    "schedule.getters.until": {
      #expect(schedule.until == nil)
    },
    "schedule.getters.starting": {
      #expect(schedule.starting == nil)
    },
    "schedule.getters.during": {
      #expect(schedule.during == [])
    },
    "error.kinds.lex": {
      #expect(HronError.lex("m", span: .init(start: 0, end: 1), input: "x").kind == .lex)
    },
    "error.kinds.parse": { #expect(error.kind == .parse) },
    "error.kinds.eval": { #expect(HronError.eval("m").kind == .eval) },
    "error.kinds.cron": { #expect(HronError.cron("m").kind == .cron) },
    "error.properties.kind": { #expect(error.kind == .parse) },
    "error.properties.message": { #expect(error.message == "expected 'at', got end of input") },
    "error.properties.span": { #expect(error.span == HronError.Span(start: 9, end: 9)) },
    "error.properties.input": { #expect(error.input == "every day") },
    "error.properties.suggestion": { #expect(error.suggestion == "every day at 09:00") },
    "error.methods.displayRich": { () throws in
      #expect(
        error.displayRich()
          == "error: expected 'at', got end of input\n  every day\n           ^ try: \"every day at 09:00\""
      )
    },
    "error.constructors.lex": {
      let lex = HronError.lex("m", span: .init(start: 0, end: 1), input: "x")
      #expect(lex.kind == .lex && lex.span != nil && lex.input == "x" && lex.suggestion == nil)
    },
    "error.constructors.parse": {
      #expect(error.kind == .parse && error.suggestion == "every day at 09:00")
    },
    "error.constructors.eval": {
      let eval = HronError.eval("m")
      #expect(eval.kind == .eval && eval.span == nil && eval.input == nil)
    },
    "error.constructors.cron": {
      let cron = HronError.cron("m")
      #expect(cron.kind == .cron && cron.message == "m" && cron.span == nil)
    },
  ]

  /// Each member api.json lists, as `group.list.name`.
  static func members(of api: JSON) -> [String] {
    let lists = [
      ("schedule", "staticMethods"), ("schedule", "instanceMethods"), ("schedule", "getters"),
      ("error", "kinds"), ("error", "properties"), ("error", "methods"),
      ("error", "constructors"),
    ]
    return lists.flatMap { group, list in
      (api[group]?[list]?.array ?? []).map {
        "\(group).\(list).\($0.string ?? $0["name"]?.string ?? "")"
      }
    }
  }

  static func missing(from api: JSON) -> [String] {
    members(of: api).filter { calls[$0] == nil }
  }

  @Test func everyMemberHasACall() {
    #expect(Self.members(of: Spec.api).count >= 30)
    #expect(Self.missing(from: Spec.api) == [])
  }

  @Test func everyCallNamesAMember() {
    #expect(Set(Self.calls.keys) == Set(Self.members(of: Spec.api)))
  }

  @Test(arguments: members(of: Spec.api))
  func call(_ member: String) throws {
    let call = try #require(Self.calls[member])
    try call()
  }

  @Test func aMemberWithoutACallFails() throws {
    guard case .object(var api) = Spec.api, case .object(var schedule) = api["schedule"],
      case .array(var methods) = schedule["instanceMethods"]
    else {
      Issue.record("api.json has no schedule.instanceMethods")
      return
    }
    methods.append(.object(["name": .string("fakeMethod")]))
    schedule["instanceMethods"] = .array(methods)
    api["schedule"] = .object(schedule)
    #expect(Self.missing(from: .object(api)) == ["schedule.instanceMethods.fakeMethod"])
  }
}
