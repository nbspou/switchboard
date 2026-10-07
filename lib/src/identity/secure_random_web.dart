/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

/// Secure random bytes on the web. Internal; see `secure_random.dart`.
///
/// Calls `globalThis.crypto.getRandomValues` directly rather than through
/// `Random.secure()`, which reads `self.crypto`: on Node.js the test
/// runner's `self` is not the global object, and the `crypto` accessor of
/// the global object refuses any other receiver.
library;

import 'dart:js_interop';
import 'dart:typed_data';

@JS('globalThis.crypto')
external _Crypto? get _crypto;

extension type _Crypto(JSObject _) implements JSObject {
  external JSUint8Array getRandomValues(JSUint8Array array);
}

/// [length] cryptographically secure random bytes, from the Web Crypto
/// API. Throws [UnsupportedError] where there is none.
Uint8List secureRandomBytes(int length) {
  final crypto = _crypto;
  if (crypto == null) {
    throw UnsupportedError('no Web Crypto API for secure random bytes');
  }
  return crypto.getRandomValues(Uint8List(length).toJS).toDart;
}
