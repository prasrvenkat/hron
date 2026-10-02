import Foundation

/// Foundation's identifier can differ from the IANA spelling, as `UTC` is `GMT` there, so both
/// are kept.
struct IANATimeZone: Sendable {
  let identifier: String
  let timeZone: TimeZone

  private static let rejectedAreas = ["systemv/", "posix/", "right/"]

  /// `UTC` or an `Area/Location` name in any case (spec/README.md, "Parse-time validation").
  /// `TimeZone(identifier:)` matches only the exact case, so names are looked up in the list
  /// generated from tzdata; a name newer than the list is accepted as Foundation spells it.
  init?(_ name: String, knownNames: [String: String] = ianaZoneNames) {
    guard name.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
    let lowercased = name.lowercased()
    guard lowercased == "utc" || name.contains("/"),
      !Self.rejectedAreas.contains(where: lowercased.hasPrefix)
    else { return nil }
    let known = knownNames[lowercased]
    guard let timeZone = TimeZone(identifier: known ?? name),
      known != nil || timeZone.identifier == name
    else { return nil }
    identifier = known ?? name
    self.timeZone = timeZone
  }

  // 0 is a valid offset.
  static let utc = TimeZone(secondsFromGMT: 0)!
}
