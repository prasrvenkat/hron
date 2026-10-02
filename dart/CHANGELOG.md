# Changelog

Current version: 2.0.0

## 2.0.0

- Breaking: `package:hron/hron.dart` no longer exports `ScheduleData` or the helpers `expandDaySpec`, `expandMonthTarget` and `ordinalSuffix`, and `Weekday.tryParse`, `Weekday.fromNumber` and `MonthName.tryParse` are removed. No public method accepted them; build a schedule with `Schedule.parse` or `Schedule.fromCron`.
- Breaking: the lists in a schedule's parts are unmodifiable, so changing one throws `UnsupportedError`, and a schedule cannot change after it is built.
- Breaking: `Schedule` is a `final class`, so another library can no longer implement or extend it, for example as a mock. Every `Schedule` is then one that `parse` or `fromCron` built, which `==` relies on.
- `Schedule` has the getters `except`, `until`, `starting` and `during` beside `timezone` and `expression`.
- `Schedule` and every part type have `==` and `hashCode`: schedules are equal when their parts are, so `every day at 9:00` equals `every day at 09:00`.
- `OrdinalPosition.toN` returns -1 for `last` instead of throwing.
- Breaking: the package requires `timezone` ^0.11.1.
- Breaking: every invalid schedule is rejected by `Schedule.parse`, and `Schedule.validate` returns false for it: a named `until` such as `until dec 31` without `starting`, a time window that crosses midnight, an unknown timezone name or an abbreviation such as `EST`, year `0000`, and a number above 2147483647. Timezone names match in any case and display in their IANA form.
- Breaking: every lex, parse and cron error message has new text, the same in every hron implementation, and error spans count Unicode code points rather than UTF-16 code units.
- Breaking: `fromCron` and `toCron` convert exactly or fail; `toCron` now converts many more schedules, and `fromCron` fails on a cron that restricts both day fields or on irregular times such as `*/7 * * * *`.
- `now`, `from`, `to` and `datetime` count only as instants, and every result is a `TZDateTime` in the schedule's zone, or UTC without one. `starting` is a lower bound as well as the interval anchor.
- Evaluation is the same as in every other hron implementation: a fall-back takes the first pass, a time in a spring-forward gap moves by the length of the gap, and results outside the supported range are null. Evaluation also works when compiled to JavaScript, where `nextFrom` used to throw.

See [GitHub Releases](https://github.com/simpllyf/hron/releases) for release notes.
