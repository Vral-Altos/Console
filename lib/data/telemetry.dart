import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import 'console_repository.dart';
import 'models.dart';

part 'telemetry.freezed.dart';

/// Time windows of the Logs page, and the chart bucket each one uses.
enum TimeRange {
  m15('15 min', Duration(minutes: 15), Duration(minutes: 1)),
  h1('1 hour', Duration(hours: 1), Duration(minutes: 2)),
  h6('6 hours', Duration(hours: 6), Duration(minutes: 10)),
  h24('24 hours', Duration(hours: 24), Duration(minutes: 30)),
  d7('7 days', Duration(days: 7), Duration(hours: 4)),
  d30('30 days', Duration(days: 30), Duration(hours: 12));

  const TimeRange(this.label, this.span, this.bucket);
  final String label;
  final Duration span;
  final Duration bucket;
}

/// What the Logs Explorer asks for. [now] is fixed per query (the page
/// refreshes it), so the stream does not restart on every tick.
@freezed
abstract class LogQuery with _$LogQuery {
  const factory LogQuery({
    required DateTime from,
    String? source,
    @Default(<String>[]) List<String> severities,
    @Default(<String>[]) List<String> components,
    @Default(200) int limit,
  }) = _LogQuery;
}

/// Sums (counters) or averages (gauges) one metric into equal buckets from
/// [from] to [to]; null where nothing was recorded. [source] null: all.
List<double?> bucketed(
  List<MetricHour> hours,
  String name, {
  required DateTime from,
  required DateTime to,
  required Duration bucket,
  String? source,
  bool gauge = false,
}) {
  final n = (to.difference(from).inSeconds / bucket.inSeconds).ceil();
  final sums = List<double?>.filled(n, null);
  final counts = List<int>.filled(n, 0);
  for (final h in hours) {
    if (source != null && h.source != source) continue;
    for (final e in h.minutes.entries) {
      final v = e.value[name];
      if (v == null) continue;
      final at = h.hour.add(Duration(minutes: e.key));
      if (at.isBefore(from) || !at.isBefore(to)) continue;
      final i = at.difference(from).inSeconds ~/ bucket.inSeconds;
      if (i < 0 || i >= n) continue;
      sums[i] = (sums[i] ?? 0) + v;
      counts[i]++;
    }
  }
  if (gauge) {
    for (var i = 0; i < n; i++) {
      if (sums[i] != null) sums[i] = sums[i]! / counts[i];
    }
  }
  return sums;
}

/// Total of a counter over [from]..[to].
double total(List<MetricHour> hours, String name, {required DateTime from, required DateTime to, String? source}) =>
    bucketed(hours, name, from: from, to: to, bucket: to.difference(from) + const Duration(seconds: 1), source: source)
        .first ??
    0;

/// Sends the Console's own errors to the logs (component `client`), at most
/// [perMinute] a minute so a render loop cannot flood them.
class ClientErrors {
  ClientErrors(this.repo, {this.perMinute = 10});
  final ConsoleRepository repo;
  final int perMinute;
  final _sent = <DateTime>[];

  void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      previous?.call(details);
      report(details.exception, details.stack, context: details.context?.toString());
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      report(error, stack);
      return false;
    };
  }

  void report(Object error, StackTrace? stack, {String? context}) {
    final now = DateTime.now();
    _sent.removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (_sent.length >= perMinute) return;
    _sent.add(now);
    unawaited(repo.writeLog('client', LogSeverity.error, '$error', {
      'context': ?context,
      if (stack != null) 'stack': stack.toString().split('\n').take(12).join('\n'),
      'url': Uri.base.path,
    }));
  }
}
