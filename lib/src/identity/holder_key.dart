/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'ed25519.dart';
import 'secure_random.dart';

/// The Ed25519 key pair a credential holder keeps to prove possession of
/// a credential that names its public key ([Credential.holderKey]).
///
/// The private key never leaves the holder: the authority issues the
/// credential for [publicKey], and the holder signs the `IDENT` proof of
/// every connection it identifies on (`MuxConnection.identify`), which
/// binds the proof to that connection's nonces.
class HolderKey {
  HolderKey._(this._keyPair, this.publicKey);

  /// A new random key pair, from a 32-byte seed of the platform's secure
  /// random source.
  static Future<HolderKey> generate() => fromSeed(secureRandomBytes(32));

  /// The key pair of the 32-byte Ed25519 [seed] (the private key). Throws
  /// [ArgumentError] if [seed] is not 32 bytes.
  static Future<HolderKey> fromSeed(List<int> seed) async {
    if (seed.length != 32) {
      throw ArgumentError.value(seed.length, 'seed', 'must be 32 bytes');
    }
    return fromKeyPair(await ed25519.newKeyPairFromSeed(seed));
  }

  /// Wraps an Ed25519 [keyPair] of `package:cryptography`. Throws
  /// [ArgumentError] for a key pair of another type.
  static Future<HolderKey> fromKeyPair(SimpleKeyPair keyPair) async =>
      HolderKey._(keyPair, await ed25519PublicKey(keyPair));

  final SimpleKeyPair _keyPair;

  /// The 32-byte public key, the [Credential.holderKey] of the credentials
  /// issued for this holder. Must not be modified.
  final Uint8List publicKey;

  /// The Ed25519 signature (64 bytes) of [message].
  Future<Uint8List> sign(List<int> message) => ed25519Sign(message, _keyPair);
}
