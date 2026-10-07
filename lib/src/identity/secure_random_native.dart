/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

/// Secure random bytes on the VM. Internal; see `secure_random.dart`.
library;

import 'dart:math' show Random;
import 'dart:typed_data';

Random? _random;

/// [length] cryptographically secure random bytes, from [Random.secure].
Uint8List secureRandomBytes(int length) {
  final random = _random ??= Random.secure();
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}
