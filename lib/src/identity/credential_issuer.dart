/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

import '../name.dart';
import 'credential.dart';
import 'ed25519.dart';

/// The mesh authority's signing key: issues signed [Credential]s.
///
/// Two kinds, chosen per mesh (wiki page "Switchboard Identity and
/// Credentials"): [CredentialIssuer.hmac] with a key shared by the mesh,
/// cheapest, but anyone holding the key can mint and the credentials are
/// bearer only; [CredentialIssuer.ed25519] with the authority's key pair,
/// verified with the public key, and with holder keys for proof of
/// possession.
class CredentialIssuer {
  /// An issuer signing with HMAC-SHA256 under [key], known to receivers as
  /// [keyId]. Throws [ArgumentError] for a key shorter than
  /// [minHmacKeyLength] bytes.
  CredentialIssuer.hmac(this.keyId, List<int> key)
    : signatureKind = SignatureKind.hmacSha256,
      _hmacKey = Uint8List.fromList(key),
      _keyPair = null {
    checkHmacKey(key);
  }

  /// An issuer signing with the Ed25519 [keyPair] of
  /// `package:cryptography`, known to receivers as [keyId]. A key pair of
  /// another type fails [issue] and [publicKey]. See also
  /// [ed25519FromSeed].
  CredentialIssuer.ed25519(this.keyId, SimpleKeyPair keyPair)
    : signatureKind = SignatureKind.ed25519,
      _hmacKey = null,
      _keyPair = keyPair;

  /// An issuer signing with the Ed25519 key pair of the 32-byte [seed]
  /// (the authority's private key), known to receivers as [keyId]. Throws
  /// [ArgumentError] if [seed] is not 32 bytes.
  static Future<CredentialIssuer> ed25519FromSeed(
    Name keyId,
    List<int> seed,
  ) async {
    if (seed.length != 32) {
      throw ArgumentError.value(seed.length, 'seed', 'must be 32 bytes');
    }
    return CredentialIssuer.ed25519(
      keyId,
      await ed25519.newKeyPairFromSeed(seed),
    );
  }

  /// Shortest HMAC key accepted, in bytes. 32 random bytes are
  /// recommended.
  static const int minHmacKeyLength = 16;

  /// The default lifetime of an issued credential.
  static const Duration defaultLifetime = Duration(hours: 8);

  /// The key id written into every credential, by which receivers find the
  /// key to verify it with.
  final Name keyId;

  /// How credentials are signed.
  final SignatureKind signatureKind;

  final Uint8List? _hmacKey;
  final SimpleKeyPair? _keyPair;

  /// Issues a signed credential.
  ///
  /// [identity] is the holder's identity (at most 255 bytes of UTF-8),
  /// [scopes] what it may do. [holderKey] is the holder's Ed25519 public
  /// key ([HolderKey.publicKey]) for a credential that requires proof of
  /// possession; null for a bearer credential. [issuedAt] defaults to the
  /// current time of `package:clock`, rounded down to the second.
  /// [lifetime] (default [defaultLifetime]) sets the expiry, rounded down
  /// to the second; null issues a credential that never expires
  /// (discouraged).
  ///
  /// Throws [ArgumentError] for a [holderKey] with an HMAC issuer (HMAC
  /// credentials are bearer only), for a negative or zero [lifetime], and
  /// for everything [Credential.new] refuses, such as a credential too
  /// long for an `IDENT` ([Credential.maxLength]).
  Future<Credential> issue({
    required CredentialKind kind,
    required String identity,
    List<Scope> scopes = const [],
    List<int>? holderKey,
    DateTime? issuedAt,
    Duration? lifetime = defaultLifetime,
  }) async {
    if (holderKey != null && signatureKind == SignatureKind.hmacSha256) {
      throw ArgumentError.value(
        holderKey,
        'holderKey',
        'HMAC credentials are bearer only',
      );
    }
    if (lifetime != null && lifetime <= Duration.zero) {
      throw ArgumentError.value(lifetime, 'lifetime', 'must be positive');
    }
    final issued = (issuedAt ?? clock.now()).millisecondsSinceEpoch ~/ 1000;
    final expires = lifetime == null ? 0 : issued + lifetime.inSeconds;
    final draft = Credential(
      kind: kind,
      keyId: keyId,
      identity: identity,
      issuedAt: issued,
      expiresAt: expires,
      holderKey: holderKey,
      scopes: scopes,
      signatureKind: signatureKind,
      signature: Uint8List(signatureKind.signatureLength),
    );
    return Credential(
      kind: kind,
      keyId: keyId,
      identity: identity,
      issuedAt: issued,
      expiresAt: expires,
      holderKey: holderKey,
      scopes: scopes,
      signatureKind: signatureKind,
      signature: await _sign(draft.signedBytes),
    );
  }

  Future<Uint8List> _sign(Uint8List message) async {
    final key = _hmacKey;
    if (key != null) {
      return hmacSha256(key, message);
    }
    return ed25519Sign(message, _keyPair!);
  }

  /// The Ed25519 public key receivers verify with
  /// (`CredentialVerifier.addEd25519Key`). Throws [StateError] for an HMAC
  /// issuer, which has none, and [ArgumentError] for a key pair that is not
  /// Ed25519.
  Future<Uint8List> publicKey() async {
    final keyPair = _keyPair;
    if (keyPair == null) {
      throw StateError('an HMAC issuer has no public key');
    }
    return ed25519PublicKey(keyPair);
  }

  /// The key a verifier needs: the HMAC key, or the Ed25519 public key.
  @internal
  Future<Uint8List> verificationKey() async =>
      _hmacKey == null ? publicKey() : Uint8List.fromList(_hmacKey);

  @override
  String toString() => 'CredentialIssuer(${signatureKind.name}, key $keyId)';
}

/// HMAC-SHA256 of [message] under [key].
@internal
Uint8List hmacSha256(List<int> key, List<int> message) =>
    Uint8List.fromList(crypto.Hmac(crypto.sha256, key).convert(message).bytes);

/// Throws [ArgumentError] for an HMAC key shorter than
/// [CredentialIssuer.minHmacKeyLength].
@internal
void checkHmacKey(List<int> key) {
  if (key.length < CredentialIssuer.minHmacKeyLength) {
    throw ArgumentError.value(
      key.length,
      'key',
      'HMAC keys are at least ${CredentialIssuer.minHmacKeyLength} bytes',
    );
  }
}
