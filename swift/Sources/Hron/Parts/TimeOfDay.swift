public struct TimeOfDay: Hashable, Sendable {
  public let hour: Int
  public let minute: Int

  var minuteOfDay: Int { hour * 60 + minute }
}
