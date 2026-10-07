/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:logging/logging.dart';

import '../name.dart';
import '../status.dart';
import 'credential.dart';
import 'credential_issuer.dart';
import 'ed25519.dart';

final Logger _log = Logger('Switchboard.Identity');

/// Checks credentials offline against the issuer keys it holds, by key id.
///
/// A receiver keeps the current and the previous issuer key during a
/// rotation: add the new key under its own id, and remove the old one once
/// the credentials it signed have expired.
///
/// Verified credentials are cached by their bytes (least recently used,
/// [cacheSize] entries), so the cost is one signature check per credential,
/// not per channel or connection; concurrent checks of the same bytes share
/// one signature check. Expiry is checked on every call. Changing the keys
/// clears the cache.
class CredentialVerifier {
  /// A verifier with the given HMAC keys and Ed25519 public keys, by key
  /// id. Throws [ArgumentError] for an HMAC key shorter than
  /// [CredentialIssuer.minHmacKeyLength], an Ed25519 key that is not 32
  /// bytes, a key id given for both kinds, or a negative [cacheSize] (0
  /// disables the cache).
  CredentialVerifier({
    Map<Name, List<int>> hmacKeys = const {},
    Map<Name, List<int>> ed25519Keys = const {},
    this.cacheSize = defaultCacheSize,
  }) {
    RangeError.checkNotNegative(cacheSize, 'cacheSize');
    hmacKeys.forEach(addHmacKey);
    for (final MapEntry(:key, :value) in ed25519Keys.entries) {
      if (hmacKeys.containsKey(key)) {
        throw ArgumentError.value(key, 'ed25519Keys', 'key id used twice');
      }
      addEd25519Key(key, value);
    }
  }

  /// Default [cacheSize].
  static const int defaultCacheSize = 1024;

  /// Largest number of verified credentials kept.
  final int cacheSize;

  final Map<Name, _Key> _keys = {};
  final LinkedHashMap<_Bytes, Credential> _cache = LinkedHashMap();
  final Map<_Bytes, Future<Credential?>> _pending = {};
  // Bumped whenever the keys change, so that a check that started under
  // other keys is not cached or trusted.
  int _epoch = 0;

  /// The key ids this verifier knows.
  Set<Name> get keyIds => Set.unmodifiable(_keys.keys);

  /// Number of credentials in the cache.
  int get cachedCount => _cache.length;

  /// Adds (or replaces) the HMAC-SHA256 key [keyId]. Throws
  /// [ArgumentError] for a key shorter than
  /// [CredentialIssuer.minHmacKeyLength].
  void addHmacKey(Name keyId, List<int> key) {
    checkHmacKey(key);
    _setKey(keyId, _Key(SignatureKind.hmacSha256, Uint8List.fromList(key)));
  }

  /// Adds (or replaces) the Ed25519 public key [keyId]. Throws
  /// [ArgumentError] for a key that is not 32 bytes.
  void addEd25519Key(Name keyId, List<int> publicKey) {
    if (publicKey.length != ed25519PublicKeyLength) {
      throw ArgumentError.value(
        publicKey.length,
        'publicKey',
        'Ed25519 public keys are $ed25519PublicKeyLength bytes',
      );
    }
    _setKey(keyId, _Key(SignatureKind.ed25519, Uint8List.fromList(publicKey)));
  }

  /// Adds the key that verifies what [issuer] issues, under its key id:
  /// its HMAC key, or its Ed25519 public key. For a mesh whose authority
  /// runs in the same process (tests, a single process deployment).
  Future<void> addIssuer(CredentialIssuer issuer) async {
    final key = await issuer.verificationKey();
    switch (issuer.signatureKind) {
      case SignatureKind.hmacSha256:
        addHmacKey(issuer.keyId, key);
      case SignatureKind.ed25519:
        addEd25519Key(issuer.keyId, key);
    }
  }

  /// Removes the key [keyId]; credentials it signed no longer verify.
  /// Returns whether there was one.
  bool removeKey(Name keyId) {
    final removed = _keys.remove(keyId) != null;
    if (removed) {
      _changed();
    }
    return removed;
  }

  void _setKey(Name keyId, _Key key) {
    _keys[keyId] = key;
    _changed();
  }

  void _changed() {
    _epoch++;
    _cache.clear();
    _pending.clear();
  }

  /// Verifies [bytes] as a credential at [now] (default: the current time
  /// of `package:clock`) and returns it.
  ///
  /// Fails with [SwitchboardException] [StatusCode.unauthenticated] and the
  /// generic reason `invalid credential` when the bytes are malformed, the
  /// key id is unknown, the signature kind is not the key's, the signature
  /// does not verify, an HMAC credential names a holder key (HMAC
  /// credentials are bearer only), or the credential has expired. The
  /// cause is logged at FINE (logger `Switchboard.Identity`), never told to
  /// the peer.
  Future<Credential> verify(Uint8List bytes, {DateTime? now}) async {
    final key = _Bytes(bytes);
    var credential = _cache.remove(key);
    if (credential != null) {
      // Most recently used last.
      _cache[key] = credential;
    } else {
      credential = await _verifyShared(key);
      if (credential == null) {
        throw _invalid();
      }
    }
    if (credential.isExpired(now ?? clock.now())) {
      _log.fine('credential of "${credential.identity}" expired');
      throw _invalid();
    }
    return credential;
  }

  Future<Credential?> _verifyShared(_Bytes key) async {
    while (true) {
      final epoch = _epoch;
      final pending = _pending[key] ??= _check(key.bytes);
      final credential = await pending;
      if (identical(_pending[key], pending)) {
        // Already awaited.
        unawaited(_pending.remove(key));
      }
      if (epoch != _epoch) {
        // The keys changed meanwhile: check again under the new ones.
        continue;
      }
      if (credential != null && cacheSize > 0) {
        _cache[key] = credential;
        while (_cache.length > cacheSize) {
          _cache.remove(_cache.keys.first);
        }
      }
      return credential;
    }
  }

  /// The credential in [bytes] if its signature verifies, else null (the
  /// cause logged). Never fails.
  Future<Credential?> _check(Uint8List bytes) async {
    final Credential credential;
    try {
      credential = Credential.decode(bytes);
    } on ProtocolException catch (e) {
      _log.fine('malformed credential: ${e.status.reason}');
      return null;
    }
    final key = _keys[credential.keyId];
    if (key == null) {
      _log.fine(
        'credential of "${credential.identity}": unknown key id '
        '${credential.keyId}',
      );
      return null;
    }
    if (key.kind != credential.signatureKind) {
      _log.fine(
        'credential of "${credential.identity}": signed with '
        '${credential.signatureKind.name}, key ${credential.keyId} is '
        '${key.kind.name}',
      );
      return null;
    }
    final signed = credential.signedBytes;
    final bool valid;
    switch (key.kind) {
      case SignatureKind.hmacSha256:
        if (!credential.isBearer) {
          _log.fine(
            'credential of "${credential.identity}": HMAC with a '
            'holder key',
          );
          return null;
        }
        valid = constantTimeEquals(
          hmacSha256(key.bytes, signed),
          credential.signature,
        );
      case SignatureKind.ed25519:
        valid = await ed25519Verify(key.bytes, signed, credential.signature);
    }
    if (!valid) {
      _log.fine('credential of "${credential.identity}": bad signature');
      return null;
    }
    return credential;
  }

  static SwitchboardException _invalid() =>
      SwitchboardException.of(StatusCode.unauthenticated, 'invalid credential');

  @override
  String toString() =>
      'CredentialVerifier(keys ${_keys.keys.join(', ')}, '
      '${_cache.length} cached)';
}

class _Key {
  _Key(this.kind, this.bytes);

  final SignatureKind kind;
  final Uint8List bytes;
}

/// Bytes compared by content, as a map key.
class _Bytes {
  _Bytes(List<int> bytes)
    : bytes = Uint8List.fromList(bytes),
      hashCode = Object.hashAll(bytes);

  final Uint8List bytes;

  @override
  final int hashCode;

  @override
  bool operator ==(Object other) {
    if (other is! _Bytes ||
        other.hashCode != hashCode ||
        other.bytes.length != bytes.length) {
      return false;
    }
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != other.bytes[i]) {
        return false;
      }
    }
    return true;
  }
}
