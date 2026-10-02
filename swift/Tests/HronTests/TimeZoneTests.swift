import Foundation
import Testing

@testable import Hron

/// spec/README.md, "Parse-time validation": names match in any case and keep the IANA spelling.
@Suite struct TimeZoneTests {
  @Test(arguments: [
    ("America/New_York", "America/New_York"),
    ("america/new_york", "America/New_York"),
    ("AMERICA/NEW_YORK", "America/New_York"),
    ("us/eastern", "US/Eastern"),
    ("US/Eastern", "US/Eastern"),
    ("Etc/GMT+5", "Etc/GMT+5"),
    ("etc/gmt+5", "Etc/GMT+5"),
    ("UTC", "UTC"),
    ("utc", "UTC"),
    ("Etc/UTC", "Etc/UTC"),
    ("asia/kolkata", "Asia/Kolkata"),
    ("Asia/Calcutta", "Asia/Calcutta"),
  ])
  func acceptsInAnyCase(_ written: String, _ identifier: String) throws {
    let schedule = try Schedule.parse("every day at 09:00 in \(written)")
    #expect(schedule.timeZoneIdentifier == identifier)
    #expect(schedule.description == "every day at 09:00 in \(identifier)")
  }

  @Test(arguments: [
    "EST", "GMT", "Z", "+05:30", "Factory", "Nope/Zone", "Etc/Unknown", "SystemV/EST5",
    "systemv/est5", "posix/America/New_York", "right/UTC", "Europe/\u{130}stanbul",
    "Etc/GMT+\u{FF15}", "\u{212A}iev/Europe", "America/New_York\u{301}",
  ])
  func rejects(_ name: String) {
    #expect(throws: HronError.self) { try Schedule.parse("every day at 09:00 in \(name)") }
  }

  @Test func showsUTCRatherThanFoundationsGMT() throws {
    let schedule = try Schedule.parse("every day at 09:00 in utc")
    #expect(schedule.timeZoneIdentifier == "UTC")
    #expect(schedule.timeZone.secondsFromGMT(for: Date()) == 0)
  }

  @Test func withoutAZoneComputesInUTC() throws {
    let schedule = try Schedule.parse("every day at 09:00")
    #expect(schedule.timeZoneIdentifier == nil)
    #expect(schedule.timeZone.secondsFromGMT(for: Date()) == 0)
    let now = Timestamp.date("2026-07-01T00:00:00+00:00[UTC]")
    #expect(schedule.next(after: now) == Timestamp.date("2026-07-01T09:00:00+00:00[UTC]"))
  }

  @Test func timeZoneIsTheNamedZone() throws {
    let schedule = try Schedule.parse("every day at 09:00 in Etc/GMT+5")
    #expect(schedule.timeZone.secondsFromGMT(for: Date()) == -5 * 3600)
    let next = try #require(schedule.next(after: Timestamp.date("2026-07-01T00:00:00+00:00[UTC]")))
    #expect(next == Timestamp.date("2026-07-01T09:00:00-05:00[Etc/GMT+5]"))
  }

  /// Monrovia kept -00:44:30 until 1972; spec/README.md, "Timezone data", leaves such offsets
  /// out, but Foundation keeps them to the second, so 09:00 is 09:44:30Z.
  @Test func subMinuteOffsetsAreExact() throws {
    let schedule = try Schedule.parse("every day at 09:00 in Africa/Monrovia")
    let next = schedule.next(after: Timestamp.date("1971-06-01T00:00:00+00:00[UTC]"))
    #expect(next == Timestamp.date("1971-06-01T09:44:30+00:00[UTC]"))
    #expect(schedule.matches(Timestamp.date("1971-06-01T09:44:30+00:00[UTC]")))
    #expect(schedule.matches(Timestamp.date("1971-06-01T09:45:29+00:00[UTC]")))
    #expect(!schedule.matches(Timestamp.date("1971-06-01T09:44:29+00:00[UTC]")))
    #expect(!schedule.matches(Timestamp.date("1971-06-01T09:45:30+00:00[UTC]")))
    let previous = schedule.previous(before: Timestamp.date("1971-06-01T09:44:31+00:00[UTC]"))
    #expect(previous == Timestamp.date("1971-06-01T09:44:30+00:00[UTC]"))
  }

  /// Foundation on Linux spells `UTC` as `GMT`, which is not the name given.
  @Test func aNameMissingFromTheListIsAcceptedOnlyAsFoundationSpellsIt() throws {
    let zone = try #require(IANATimeZone("America/New_York", knownNames: [:]))
    #expect(zone.identifier == "America/New_York")
    #expect(zone.timeZone.identifier == "America/New_York")
    #expect(IANATimeZone("UTC", knownNames: [:]) == nil)
    #expect(IANATimeZone("america/new_york", knownNames: [:]) == nil)
    #expect(IANATimeZone("Nope/Zone", knownNames: [:]) == nil)
  }

  @Test func theListKeepsTheIANASpellingOverTheInput() throws {
    let zone = try #require(IANATimeZone("america/new_york", knownNames: ianaZoneNames))
    #expect(zone.identifier == "America/New_York")
    #expect(zone.timeZone.identifier == "America/New_York")
  }
}
