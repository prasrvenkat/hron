extension Schedule: CustomStringConvertible {
  /// The canonical form, which `parse` reads back to an equal schedule.
  public var description: String {
    var text = expression.canonical
    // Trailing clauses in the grammar's fixed order, so the output parses back.
    if !except.isEmpty {
      text += " except " + except.map(\.canonical).joined(separator: ", ")
    }
    switch until {
    case .iso(let date): text += " until \(date)"
    case .named(let month, let day): text += " until \(month.shortName) \(day)"
    case nil: break
    }
    if let startingDate {
      text += " starting \(startingDate.iso)"
    }
    if !during.isEmpty {
      text += " during " + during.map(\.shortName).joined(separator: ", ")
    }
    if let timeZoneIdentifier {
      text += " in \(timeZoneIdentifier)"
    }
    return text
  }
}

extension ScheduleExpression {
  var canonical: String {
    switch self {
    case .intervalRepeat(let interval, let unit, let from, let to, let dayFilter):
      let unitName =
        switch unit {
        case .minutes: interval == 1 ? "minute" : "min"
        case .hours: interval == 1 ? "hour" : "hours"
        }
      let days = dayFilter.map { " on \($0.canonical)" } ?? ""
      return "every \(interval) \(unitName) from \(from.canonical) to \(to.canonical)\(days)"
    case .dayRepeat(let interval, let days, let times):
      let repeater = interval > 1 ? "\(interval) days" : days.canonical
      return "every \(repeater) at \(times.canonical)"
    case .weekRepeat(let interval, let days, let times):
      let repeater = interval > 1 ? "\(interval) weeks" : "week"
      return "every \(repeater) on \(days.canonical) at \(times.canonical)"
    case .monthRepeat(let interval, let target, let times):
      let repeater = interval > 1 ? "\(interval) months" : "month"
      return "every \(repeater) on the \(target.canonical) at \(times.canonical)"
    case .singleDate(let date, let times):
      return "on \(date.canonical) at \(times.canonical)"
    case .yearRepeat(let interval, let target, let times):
      let repeater = interval > 1 ? "\(interval) years" : "year"
      return "every \(repeater) on \(target.canonical) at \(times.canonical)"
    }
  }
}

extension TimeOfDay {
  var canonical: String {
    (hour < 10 ? "0" : "") + "\(hour):" + (minute < 10 ? "0" : "") + "\(minute)"
  }
}

extension [TimeOfDay] {
  var canonical: String { map(\.canonical).joined(separator: ", ") }
}

extension [Weekday] {
  var canonical: String { map(\.name).joined(separator: ", ") }
}

extension DayFilter {
  var canonical: String {
    switch self {
    case .every: "day"
    case .weekday: "weekday"
    case .weekend: "weekend"
    case .days(let days): days.canonical
    }
  }
}

extension MonthTarget {
  var canonical: String {
    switch self {
    case .days(let specs):
      specs.map {
        switch $0 {
        case .single(let day): ordinalDay(day)
        case .range(let start, let end): "\(ordinalDay(start)) to \(ordinalDay(end))"
        }
      }.joined(separator: ", ")
    case .lastDay: "last day"
    case .lastWeekday: "last weekday"
    case .nearestWeekday(let day, let direction):
      switch direction {
      case .next: "next nearest weekday to \(ordinalDay(day))"
      case .previous: "previous nearest weekday to \(ordinalDay(day))"
      case nil: "nearest weekday to \(ordinalDay(day))"
      }
    case .ordinalWeekday(let ordinal, let weekday): "\(ordinal.name) \(weekday.name)"
    }
  }
}

extension YearTarget {
  var canonical: String {
    switch self {
    case .date(let month, let day): "\(month.shortName) \(day)"
    case .ordinalWeekday(let ordinal, let weekday, let month):
      "the \(ordinal.name) \(weekday.name) of \(month.shortName)"
    case .dayOfMonth(let day, let month): "the \(ordinalDay(day)) of \(month.shortName)"
    case .lastWeekday(let month): "the last weekday of \(month.shortName)"
    }
  }
}

extension DateSpec {
  var canonical: String {
    switch self {
    case .named(let month, let day): "\(month.shortName) \(day)"
    case .iso(let date): date
    }
  }
}

extension Exception {
  var canonical: String {
    switch self {
    case .named(let month, let day): "\(month.shortName) \(day)"
    case .iso(let date): date
    }
  }
}

private func ordinalDay(_ day: Int) -> String {
  let suffix =
    switch (day % 100, day % 10) {
    case (11...13, _): "th"
    case (_, 1): "st"
    case (_, 2): "nd"
    case (_, 3): "rd"
    default: "th"
    }
  return "\(day)\(suffix)"
}
