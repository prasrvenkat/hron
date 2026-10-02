/// Human-readable cron (hron) - scheduling expressions that read like English
/// and convert to and from cron.
library;

import 'package:timezone/timezone.dart';

import 'src/ast.dart';
import 'src/cron.dart' as cron_impl;
import 'src/display.dart' as display_impl;
import 'src/error.dart';
import 'src/eval.dart' as eval_impl;
import 'src/parser.dart' as parser_impl;

export 'src/error.dart';

/// Built only by [Schedule.parse] or [Schedule.fromCron].
///
/// A [TZDateTime] argument stands for its instant; its location changes no
/// result. Every returned [TZDateTime] is in the schedule's [timezone], or in a
/// location named `UTC` when it has none. An argument outside
/// `0001-01-02T00:00:00Z <= t < 9999-12-30T00:00:00Z` is not an error: it gives
/// `null`, `false` or no occurrences.
class Schedule {
  final ScheduleData _data;

  Schedule._(this._data);

  /// Parses a hron expression and returns a [Schedule].
  ///
  /// Throws [HronError] if the expression is invalid, including a timezone
  /// name missing from the loaded `package:timezone` database.
  static Schedule parse(String input) => Schedule._(parser_impl.parse(input));

  /// Converts a 5-field cron expression or `@` shortcut into a [Schedule] that
  /// fires at the same times on the same dates.
  ///
  /// Throws a [HronError] of kind [HronErrorKind.cron] if [cronExpr] is
  /// invalid or no hron schedule fires exactly as it does.
  static Schedule fromCron(String cronExpr) =>
      Schedule._(cron_impl.fromCron(cronExpr));

  /// Returns `true` if [input] is a valid hron expression.
  ///
  /// False, rather than throwing, for anything [parse] rejects.
  static bool validate(String input) {
    try {
      parser_impl.parse(input);
      return true;
    } on HronError {
      return false;
    }
  }

  /// Returns the next occurrence strictly after [now], or `null` if none exists.
  TZDateTime? nextFrom(TZDateTime now) => eval_impl.nextFrom(_data, now);

  /// Returns the next [n] occurrences strictly after [now]: none when [n] is
  /// 0 or less, and fewer when the schedule or the supported range ends.
  List<TZDateTime> nextNFrom(TZDateTime now, int n) =>
      eval_impl.nextNFrom(_data, now, n);

  /// Returns the most recent occurrence strictly before [now], or `null` if none exists.
  TZDateTime? previousFrom(TZDateTime now) =>
      eval_impl.previousFrom(_data, now);

  /// Returns `true` if the minute containing [datetime] is an occurrence
  /// (seconds are ignored).
  bool matches(TZDateTime datetime) => eval_impl.matches(_data, datetime);

  /// Returns a lazy iterable of occurrences strictly after [from], through the
  /// end of the supported range unless the schedule ends first.
  Iterable<TZDateTime> occurrences(TZDateTime from) =>
      eval_impl.occurrences(_data, from);

  /// Returns a bounded iterable of occurrences where `from < occurrence <= to`.
  Iterable<TZDateTime> between(TZDateTime from, TZDateTime to) =>
      eval_impl.between(_data, from, to);

  /// Converts this schedule to a 5-field cron expression that fires at the
  /// same times on the same dates; the timezone is not part of it.
  ///
  /// Throws a [HronError] of kind [HronErrorKind.cron] if no cron does.
  String toCron() => cron_impl.toCron(_data);

  /// Returns the canonical hron string representation of this schedule.
  @override
  String toString() => display_impl.display(_data);

  /// The IANA timezone name, in its canonical capitalization, or `null` if not
  /// specified.
  String? get timezone => _data.timezone;
}
