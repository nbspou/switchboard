/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'package:clock/clock.dart';

final Stopwatch _stopwatch = Stopwatch()..start();

/// The current instant for deadlines, as a duration since an arbitrary
/// origin.
///
/// Monotonic: a process-wide [Stopwatch], which wall clock adjustments do
/// not move. When a zone installs a clock of its own (`withClock` of
/// `package:clock`, as `fake_async` does), that clock is read instead, so
/// that deadlines follow the time a test controls. Instants read under
/// different clocks cannot be compared.
Duration monotonicNow() {
  final current = clock;
  if (identical(current, const Clock())) {
    return _stopwatch.elapsed;
  }
  return Duration(microseconds: current.now().microsecondsSinceEpoch);
}

/// The wall clock time of [instant], a value of [monotonicNow].
DateTime wallTimeOf(Duration instant) =>
    clock.now().add(instant - monotonicNow());
