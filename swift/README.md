# hron (Swift)

[![Swift Package Index](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsimpllyf%2Fhron%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/simpllyf/hron)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsimpllyf%2Fhron%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/simpllyf/hron)

Native Swift implementation of [hron](https://github.com/simpllyf/hron) — human-readable cron expressions for iOS, macOS and server-side Swift.

## Install

Add the package to `Package.swift`. SwiftPM resolves the repo's version tags, so there is no registry:

```swift
dependencies: [
    .package(url: "https://github.com/simpllyf/hron", from: "2.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Hron", package: "hron")]),
]
```

## Usage

```swift
import Foundation
import Hron

let schedule = try Schedule.parse("every weekday at 9:00 in America/New_York")
let now = try Date("2026-02-06T12:00:00Z", strategy: .iso8601)

let next = schedule.next(after: now)           // 2026-02-06 14:00 UTC, 09:00 in New York
let nextFive = schedule.next(5, after: now)    // up to 5 occurrences after now
let previous = schedule.previous(before: now)  // 2026-02-05 14:00 UTC
let matches = schedule.matches(now)            // false

// A Date has no zone: format it in the schedule's zone to show the time it fires at.
let style = Date.ISO8601FormatStyle(timeZone: schedule.timeZone)
print(next!.formatted(style))  // 2026-02-06T09:00:00-0500

// Occurrences are computed lazily, one at a time.
for date in schedule.occurrences(after: now).prefix(3) {
    print(date.formatted(style))
}

print(schedule)                                               // every weekday at 09:00 in America/New_York
print(try Schedule.parse("every day at 9:00").toCron())       // 0 9 * * *
print(try Schedule.fromCron("0 16 * * 5L"))                   // every month on the last friday at 16:00
print(Schedule.validate("every day at 25:00"))                // false
```

## API

A `Schedule` is a value type, built only by `Schedule.parse` or `Schedule.fromCron`, and its properties cannot change. The spec's names (`spec/api.json`) map to these:

| Spec | Swift | Result |
| --- | --- | --- |
| `parse` | `Schedule.parse(_ input: String)` | `Schedule`; throws `HronError` |
| `fromCron` | `Schedule.fromCron(_ cronExpr: String)` | `Schedule`; throws `HronError` |
| `validate` | `Schedule.validate(_ input: String)` | `Bool`: `false` for anything `parse` rejects |
| `nextFrom` | `next(after now: Date)` | `Date?`: the next occurrence after `now` |
| `nextNFrom` | `next(_ n: Int, after now: Date)` | `[Date]`: at most `n` occurrences after `now` |
| `previousFrom` | `previous(before now: Date)` | `Date?`: the last occurrence before `now` |
| `matches` | `matches(_ datetime: Date)` | `Bool`: whether the minute containing `datetime` is an occurrence |
| `occurrences` | `occurrences(after from: Date)` | `Occurrences`: a lazy sequence of the occurrences after `from` |
| `between` | `occurrences(after from: Date, through to: Date)` | `Occurrences`: a lazy sequence of the occurrences in `from < t <= to` |
| `toCron` | `toCron()` | `String`; throws `HronError` |
| `toString` | `description` | `String`: the canonical expression, which `parse` reads back to an equal schedule |
| `equals` | `==`, `hash(into:)` | equal when the parts are equal |
| `timezone` | `timeZoneIdentifier` | `String?`: the IANA name in its canonical capitalization |
| | `timeZone` | `TimeZone`: the zone occurrences are computed in, UTC without an `in` clause |
| `expression` | `expression` | `ScheduleExpression`: the repeat, without its clauses |
| `except` | `except` | `[Exception]`: empty without an `except` clause |
| `until` | `until` | `UntilSpec?` |
| `starting` | `starting` | `String?`: a `YYYY-MM-DD` date |
| `during` | `during` | `[MonthName]`: empty without a `during` clause |

`Occurrences` conforms to `LazySequenceProtocol`, so `map`, `filter` and `prefix` on it stay lazy. Without a `through` date it stops only at an `until` clause or the end of the supported range, so take a prefix of it rather than collecting it into an array.

Schedules, their parts, `Occurrences` and `HronError` are all `Sendable`.

### Parts

The getters return the parts of the schedule: `ScheduleExpression` (`.intervalRepeat`, `.dayRepeat`, `.weekRepeat`, `.monthRepeat`, `.singleDate`, `.yearRepeat`), `DayFilter`, `MonthTarget`, `YearTarget`, `DayOfMonthSpec`, `DateSpec`, `Exception`, `UntilSpec`, `TimeOfDay`, and the names `Weekday`, `MonthName`, `OrdinalPosition`, `NearestDirection` and `IntervalUnit`. They are `Hashable` value types with associated values or read-only properties.

```swift
let parts = try Schedule.parse(
    "every weekday at 9:00 except dec 25 starting 2026-01-01 during jan, dec in america/new_york")
print(parts.timeZoneIdentifier ?? "none")  // America/New_York
print(parts.starting ?? "none")            // 2026-01-01
print(parts.until == nil)                  // true
print(parts.during == [.january, .december])  // true

if case .dayRepeat(_, .weekday, let times) = parts.expression {
    print(times.map { "\($0.hour):\($0.minute)" })  // ["9:0"]
}

switch parts.except[0] {
case .named(let month, let day): print(month, day)  // december 25
case .iso(let date): print(date)
@unknown default: break
}
```

`Weekday` and `MonthName` are closed sets. The other enums may gain cases in a minor release, so a `switch` over one of them needs an `@unknown default`.

### Equality

Two schedules are equal when their parts are, with lists compared in order and duplicates counted. Equal schedules have equal hashes, so a schedule can be a `Dictionary` key or a `Set` element:

```swift
let nine = try Schedule.parse("every day at 9:00")
print(nine == (try Schedule.parse("every day at 09:00")))  // true
print(nine.hashValue == (try Schedule.parse("every day at 09:00")).hashValue)  // true
print(nine == (try Schedule.fromCron("0 9 * * *")))  // true
print(
    (try Schedule.parse("every monday, friday at 09:00"))
        == (try Schedule.parse("every friday, monday at 09:00")))  // false
```

## Timestamps

Every method takes and returns `Date`, an instant with no zone. A schedule computes in its `timeZone`, so format a result in that zone to show the wall-clock time it fires at, as in [Usage](#usage). `timeZoneIdentifier` gives the name to show, and is `nil` when the expression has no `in` clause; `timeZone` is then UTC.

Offsets are exact to the second: Foundation keeps the offsets of local mean time and of Monrovia's `-00:44:30` until 1972, so `every day at 09:00 in Africa/Monrovia` fires at 09:44:30 UTC in 1971. A fraction of a second counts: `next(after:)` returns an occurrence strictly after the exact instant.

`next(_:after:)` returns no more than `n` occurrences, and none when `n <= 0`. A large `n` only caps the count, with no room reserved for it, so `next(Int.max, after: now)` returns every occurrence through the end of the supported range.

The supported range is `0001-01-02T00:00:00Z <= t < 9999-12-30T00:00:00Z`, in the proleptic Gregorian calendar. A `Date` outside it, including a NaN or infinite one, is not an error: `next(after:)` and `previous(before:)` return `nil`, `matches` returns `false`, and `next(_:after:)` and both `occurrences` return nothing. hron counts dates itself, as Foundation's Gregorian `Calendar` switches to the Julian calendar before 1582: `on 1582-10-10 at 12:00` fires on that proleptic Gregorian date.

## Errors

Every error hron throws is a `HronError`, through a typed `throws(HronError)`, so a `catch` binds it with no cast:

| Property | Type | Holds |
| --- | --- | --- |
| `kind` | `HronError.Kind` | `.lex`, `.parse`, `.eval` or `.cron` |
| `message` | `String` | what went wrong, also its `description` and `errorDescription` |
| `span` | `HronError.Span?` | the part of `input` it points at, for `.lex` and `.parse` |
| `input` | `String?` | the expression, for `.lex` and `.parse` |
| `suggestion` | `String?` | a fix, for some `.parse` errors |

`displayRich()` formats it for a terminal, and `HronError.lex(_:span:input:)`, `parse(_:span:input:suggestion:)`, `eval(_:)` and `cron(_:)` build one of each kind.

`Schedule.parse` throws a `.lex` or `.parse` error with the exact message of the [spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#error-message-format), the `input` and a `span`; a parse error may carry a `suggestion`:

```swift
do {
    _ = try Schedule.parse("every weekday at 09:00 until dec 31")
} catch {
    print(error.kind == .parse)  // true
    print(error.displayRich())
}
```

```text
error: until dec 31 has no year: add a starting date, or use an ISO date
  every weekday at 09:00 until dec 31
                         ^^^^^^^^^^^^ try: "until dec 31 starting YYYY-MM-DD"
```

A span counts Unicode scalars (code points), not `Character`s or UTF-16 units, so take the spanned text from `input.unicodeScalars`.

A schedule is built only by `Schedule.parse` or `Schedule.fromCron`, so evaluating it never throws. `.eval` is for schedules that other hron languages build from their parts in code; this package never throws it.

## Cron Conversion

`toCron()` and `Schedule.fromCron(_:)` convert exactly: the result fires at the same times on the same dates, or they throw a `.cron` error whose message says why. This ignores the timezone and DST transitions, where cron schedulers differ. Yearly dates, ordinal weekdays such as `5L` and `1#2`, and intervals over part of the day convert too: `every 15 min from 09:00 to 17:45` is `*/15 9-17 * * *`.

`toCron()` throws for `except`, `until` and `starting`, ISO dates, repeats every `n` days, weeks, months or years with `n > 1`, directional nearest weekdays, a `during` that excludes a yearly or named date's month, and times that are not every combination of their minutes and hours (`at 09:00, 17:30`). A schedule's timezone is not part of the cron: run the cron in the schedule's timezone.

`Schedule.fromCron(_:)` throws for crons that restrict both the day of month and the day of week (`0 9 15 * 1`), and for more than 24 times a day, unless they are evenly spaced on days an interval can carry (`*/7 * * * *` fires 216 times at uneven gaps). The [spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#cron-conversion) has the full rules and every error message.

## Timezones

Names match in any case and display with the IANA capitalization: `in america/new_york` displays `in America/New_York`, a link keeps its own name (`in us/eastern` displays `in US/Eastern`), and `in utc` displays `in UTC`.

Foundation's `TimeZone` computes the offsets. It matches a name only in its exact case and cannot list link names, so the package carries the list of IANA zone and link names, generated from a tzdata release by `tools/swift_zone_names.py`. A name newer than that list is accepted when Foundation knows it in the exact case given.

## Platforms and toolchain

- iOS 15, macOS 12, tvOS 15, watchOS 9 and visionOS 1, and Linux.
- Swift 6.0 or later (`swift-tools-version: 6.0`), in the Swift 6 language mode.
- No dependencies beyond Foundation.

## Tests

From the repository root, where `Package.swift` is:

```sh
swift test
```

`ConformanceTests` runs every case of `spec/tests.json`, `APIConformanceTests` checks each member of `spec/api.json`, and `ReadmeTests` runs the examples above.

`just test-swift-32` runs the tests at 32 bits, as Apple Watch Series 4 to 8 and SE have, on wasm32 under [wasmtime](https://wasmtime.dev), after `just setup-swift-32` installs the Swift SDK for WebAssembly. `just check-swift-client` builds `swift/ClientCheck`, a client that switches over every enum that may gain cases, and checks that each switch fails to build without its `@unknown default`.

## License

MIT
