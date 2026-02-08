import 'package:timezone/timezone.dart';

import 'src/ast.dart';
import 'src/cron.dart' as cron_impl;
import 'src/display.dart' as display_impl;
import 'src/eval.dart' as eval_impl;
import 'src/parser.dart' as parser_impl;

export 'src/ast.dart';
export 'src/error.dart';

class Schedule {
  final ScheduleData _data;

  Schedule._(this._data);

  static Schedule parse(String input) =>
      Schedule._(parser_impl.parse(input));

  static Schedule fromCron(String cronExpr) =>
      Schedule._(cron_impl.fromCron(cronExpr));

  static bool validate(String input) {
    try {
      parser_impl.parse(input);
      return true;
    } catch (_) {
      return false;
    }
  }

  TZDateTime? nextFrom(TZDateTime now) =>
      eval_impl.nextFrom(_data, now);

  List<TZDateTime> nextNFrom(TZDateTime now, int n) =>
      eval_impl.nextNFrom(_data, now, n);

  bool matches(TZDateTime datetime) =>
      eval_impl.matches(_data, datetime);

  String toCron() => cron_impl.toCron(_data);

  @override
  String toString() => display_impl.display(_data);

  String? get timezone => _data.timezone;

  ScheduleExpr get expression => _data.expr;
}
