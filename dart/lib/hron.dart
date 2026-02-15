/// Human-readable cron (hron) - scheduling expressions that are a superset
/// of what cron can express.
///
/// ```dart
/// import 'package:hron/hron.dart';
/// import 'package:timezone/data/latest.dart' as tz;
/// import 'package:timezone/timezone.dart';
///
/// void main() {
///   tz.initializeTimeZones();
///   final schedule = Schedule.parse('every day at 9am');
///   final now = TZDateTime.now(getLocation('America/New_York'));
///   print(schedule.nextFrom(now));
/// }
/// ```
library;

import 'package:timezone/timezone.dart';

import 'src/ast.dart';
import 'src/cron.dart' as cron_impl;
import 'src/display.dart' as display_impl;
import 'src/error.dart';
import 'src/eval.dart' as eval_impl;
import 'src/parser.dart' as parser_impl;

export 'src/ast.dart';
export 'src/error.dart';

/// A parsed hron schedule that can compute occurrences and match datetimes.
///
/// Use [Schedule.parse] to create a schedule from a hron expression, or
/// [Schedule.fromCron] to convert from standard cron format.
///
/// Example:
/// ```dart
/// final schedule = Schedule.parse('every weekday at 9am, 5pm');
/// final next = schedule.nextFrom(TZDateTime.now(location));
/// ```
class Schedule {
  final ScheduleData _data;

  Schedule._(this._data);

  /// Parses a hron expression and returns a [Schedule].
  ///
  /// Throws [HronError] if the expression is invalid.
  ///
  /// Example expressions:
  /// - `'every day at 9am'`
  /// - `'every weekday at 9am, 5pm'`
  /// - `'every 2 weeks on monday at 10:00'`
  /// - `'on the 1st of every month at 00:00'`
  static Schedule parse(String input) => Schedule._(parser_impl.parse(input));

  /// Creates a [Schedule] from a standard 5-field cron expression.
  ///
  /// Throws [HronError] if the cron expression is invalid.
  ///
  /// Example: `Schedule.fromCron('0 9 * * 1-5')` (weekdays at 9am)
  static Schedule fromCron(String cronExpr) =>
      Schedule._(cron_impl.fromCron(cronExpr));

  /// Returns `true` if [input] is a valid hron expression.
  ///
  /// Unlike [parse], this does not throw on invalid input.
  static bool validate(String input) {
    try {
      parser_impl.parse(input);
      return true;
    } on HronError {
      return false;
    }
  }

  /// Returns the next occurrence at or after [now], or `null` if none exists.
  ///
  /// For schedules with an `until` clause, returns `null` after the end date.
  TZDateTime? nextFrom(TZDateTime now) => eval_impl.nextFrom(_data, now);

  /// Returns the next [n] occurrences starting at or after [now].
  ///
  /// May return fewer than [n] results if the schedule has an end date.
  List<TZDateTime> nextNFrom(TZDateTime now, int n) =>
      eval_impl.nextNFrom(_data, now, n);

  /// Returns the most recent occurrence strictly before [now], or `null` if none exists.
  ///
  /// For schedules with a `starting` clause, returns `null` if the result would be before the start date.
  TZDateTime? previousFrom(TZDateTime now) =>
      eval_impl.previousFrom(_data, now);

  /// Returns `true` if [datetime] matches this schedule.
  bool matches(TZDateTime datetime) => eval_impl.matches(_data, datetime);

  /// Returns a lazy iterable of occurrences starting after [from].
  /// The iterable is unbounded for repeating schedules (will iterate forever unless limited),
  /// but respects the `until` clause if specified in the schedule.
  Iterable<TZDateTime> occurrences(TZDateTime from) =>
      eval_impl.occurrences(_data, from);

  /// Returns a bounded iterable of occurrences where `from < occurrence <= to`.
  /// The iterable yields occurrences strictly after [from] and up to and including [to].
  Iterable<TZDateTime> between(TZDateTime from, TZDateTime to) =>
      eval_impl.between(_data, from, to);

  /// Converts this schedule to a standard 5-field cron expression.
  ///
  /// Throws [HronError] if the schedule cannot be expressed in cron format
  /// (e.g., schedules with `except`, `until`, or complex patterns).
  String toCron() => cron_impl.toCron(_data);

  /// Returns the canonical hron string representation of this schedule.
  @override
  String toString() => display_impl.display(_data);

  /// The IANA timezone for this schedule, or `null` if not specified.
  ///
  /// When set (via `in America/New_York` clause), all times are interpreted
  /// in that timezone.
  String? get timezone => _data.timezone;

  /// The underlying schedule expression AST node.
  ScheduleExpr get expression => _data.expr;
}
