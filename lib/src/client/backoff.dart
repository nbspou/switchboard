/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

/// The reconnect backoff schedule shared by `ReconnectingClient` and
/// `PeerSet`. Internal to the package; not exported.
library;

import 'dart:math' show Random, pow;

/// Exponential backoff with jitter: the delay after `n` consecutive
/// failures is `min(initial * factor^n, max)`, multiplied by a uniform
/// random factor in `[1 - jitter, 1 + jitter]` (so a delay may exceed
/// [max] by up to that fraction).
class Backoff {
  /// Creates the schedule. Throws [ArgumentError] like [check].
  Backoff({
    required this.initial,
    required this.max,
    required this.factor,
    required this.jitter,
    Random? random,
  }) : _random = random ?? Random() {
    check(initial: initial, max: max, factor: factor, jitter: jitter);
  }

  /// Delay after the first failure.
  final Duration initial;

  /// Upper bound of the delay before jitter.
  final Duration max;

  /// Growth per consecutive failure.
  final double factor;

  /// Random spread of each delay, as a fraction of it.
  final double jitter;

  final Random _random;

  /// Throws [ArgumentError] (naming the parameters `initialBackoff`,
  /// `maxBackoff`, `backoffFactor` and `jitter`, as the public
  /// constructors call them) if [initial] is negative, [max] is below it,
  /// [factor] is below 1 or not finite, or [jitter] is outside 0 to 1.
  static void check({
    required Duration initial,
    required Duration max,
    required double factor,
    required double jitter,
  }) {
    if (initial.isNegative) {
      throw ArgumentError.value(
        initial,
        'initialBackoff',
        'must not be negative',
      );
    }
    if (max < initial) {
      throw ArgumentError.value(
        max,
        'maxBackoff',
        'must not be below initialBackoff',
      );
    }
    if (!(factor >= 1) || factor.isInfinite) {
      throw ArgumentError.value(
        factor,
        'backoffFactor',
        'must be a finite number of at least 1',
      );
    }
    if (!(jitter >= 0 && jitter <= 1)) {
      throw ArgumentError.value(jitter, 'jitter', 'must be between 0 and 1');
    }
  }

  /// The delay after [failures] consecutive failures, with jitter.
  Duration delay(int failures) {
    final first = initial.inMicroseconds;
    if (first == 0) {
      return Duration.zero;
    }
    final bound = max.inMicroseconds.toDouble();
    var base = first * pow(factor, failures).toDouble();
    if (!(base <= bound)) {
      base = bound;
    }
    if (jitter > 0) {
      base *= 1 + jitter * (2 * _random.nextDouble() - 1);
    }
    return Duration(microseconds: base.round());
  }
}
