# Changelog

Current version: 1.0.0

## Unreleased

- Breaking: `package:hron/hron.dart` no longer exports the schedule's syntax tree (`ScheduleExpr`, `ScheduleData`, `Weekday`, `MonthName`, `OrdinalPosition`, `TimeOfDay` and the rest) or the helpers `expandDaySpec`, `expandMonthTarget` and `ordinalSuffix`, and `Schedule.expression` is removed. No public method accepted them; build a schedule with `Schedule.parse` or `Schedule.fromCron`.

See [GitHub Releases](https://github.com/simpllyf/hron/releases) for release notes.
