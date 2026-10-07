/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

/// Cryptographically secure random bytes on every platform. Internal to
/// the package; not exported.
library;

export 'secure_random_native.dart'
    if (dart.library.js_interop) 'secure_random_web.dart';
