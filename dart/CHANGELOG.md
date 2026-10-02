# Changelog

Current version: 1.0.0

## Unreleased

- Breaking: `package:hron/hron.dart` no longer exports `ScheduleData` or the helpers `expandDaySpec`, `expandMonthTarget` and `ordinalSuffix`, and `Weekday.tryParse`, `Weekday.fromNumber` and `MonthName.tryParse` are removed. No public method accepted them; build a schedule with `Schedule.parse` or `Schedule.fromCron`.
- Breaking: the lists in a schedule's parts are unmodifiable, so changing one throws `UnsupportedError`, and a schedule cannot change after it is built.
- Breaking: `Schedule` is a `final class`, so another library can no longer implement or extend it, for example as a mock. Every `Schedule` is then one that `parse` or `fromCron` built, which `==` relies on.
- `Schedule` has the getters `except`, `until`, `starting` and `during` beside `timezone` and `expression`.
- `Schedule` and every part type have `==` and `hashCode`: schedules are equal when their parts are, so `every day at 9:00` equals `every day at 09:00`.
- `OrdinalPosition.toN` returns -1 for `last` instead of throwing.

See [GitHub Releases](https://github.com/simpllyf/hron/releases) for release notes.
