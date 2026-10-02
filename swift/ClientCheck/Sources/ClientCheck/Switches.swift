import Hron

// `just check-swift-client` builds this as a client would, then again with STRICT, where each
// switch over an enum marked @nonexhaustive must fail for want of its `@unknown default`.

func name(_ value: ScheduleExpression) -> String {
  switch value {
  case .intervalRepeat: "intervalRepeat"
  case .dayRepeat: "dayRepeat"
  case .weekRepeat: "weekRepeat"
  case .monthRepeat: "monthRepeat"
  case .singleDate: "singleDate"
  case .yearRepeat: "yearRepeat"
  #if !STRICT
    @unknown default: "unknown"
  #endif
  }
}

func name(_ value: DayFilter) -> String {
  switch value {
  case .every: "every"
  case .weekday: "weekday"
  case .weekend: "weekend"
  case .days: "days"
  #if !STRICT
    @unknown default: "unknown"
  #endif
  }
}

func name(_ value: MonthTarget) -> String {
  switch value {
  case .days: "days"
  case .lastDay: "lastDay"
  case .lastWeekday: "lastWeekday"
  case .nearestWeekday: "nearestWeekday"
  case .ordinalWeekday: "ordinalWeekday"
  #if !STRICT
    @unknown default: "unknown"
  #endif
  }
}

func name(_ value: YearTarget) -> String {
  switch value {
  case .date: "date"
  case .ordinalWeekday: "ordinalWeekday"
  case .dayOfMonth: "dayOfMonth"
  case .lastWeekday: "lastWeekday"
  #if !STRICT
    @unknown default: "unknown"
  #endif
  }
}

func name(_ value: DayOfMonthSpec) -> String {
  switch value {
  case .single: "single"
  case .range: "range"
  #if !STRICT
    @unknown default: "unknown"
  #endif
  }
}

func name(_ value: DateSpec) -> String {
  switch value {
  case .named: "named"
  case .iso: "iso"
  #if !STRICT
    @unknown default: "unknown"
  #endif
  }
}

func name(_ value: Exception) -> String {
  switch value {
  case .named: "named"
  case .iso: "iso"
  #if !STRICT
    @unknown default: "unknown"
  #endif
  }
}

func name(_ value: UntilSpec) -> String {
  switch value {
  case .iso: "iso"
  case .named: "named"
  #if !STRICT
    @unknown default: "unknown"
  #endif
  }
}

func name(_ value: OrdinalPosition) -> String {
  switch value {
  case .first: "first"
  case .second: "second"
  case .third: "third"
  case .fourth: "fourth"
  case .fifth: "fifth"
  case .last: "last"
  #if !STRICT
    @unknown default: "unknown"
  #endif
  }
}

func name(_ value: NearestDirection) -> String {
  switch value {
  case .next: "next"
  case .previous: "previous"
  #if !STRICT
    @unknown default: "unknown"
  #endif
  }
}

func name(_ value: IntervalUnit) -> String {
  switch value {
  case .minutes: "minutes"
  case .hours: "hours"
  #if !STRICT
    @unknown default: "unknown"
  #endif
  }
}

// The README promises these two are closed sets, so a switch over them needs no default.

func isFirstDayOfWeek(_ value: Weekday) -> Bool {
  switch value {
  case .monday: true
  case .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday: false
  }
}

func isFirstMonth(_ value: MonthName) -> Bool {
  switch value {
  case .january: true
  case .february, .march, .april, .may, .june, .july, .august, .september, .october, .november,
    .december:
    false
  }
}
