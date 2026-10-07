/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

/// Ed25519 through `package:cryptography`'s pure Dart implementation, the
/// same on the VM and on the web. Internal to the package; not exported.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// The pure Dart implementation with a pure Dart SHA-512, so that no
/// platform implementation (WebCrypto) is involved anywhere.
final DartEd25519 ed25519 = DartEd25519(sha512: const DartSha512());

/// Length of an Ed25519 public key.
const int ed25519PublicKeyLength = 32;

/// Length of an Ed25519 signature.
const int ed25519SignatureLength = 64;

/// Signs [message] with [keyPair].
Future<Uint8List> ed25519Sign(List<int> message, SimpleKeyPair keyPair) async {
  final signature = await ed25519.sign(message, keyPair: keyPair);
  return Uint8List.fromList(signature.bytes);
}

/// Whether [signature] is a valid signature of [message] by [publicKey].
/// False for keys and signatures of the wrong length, and for anything the
/// implementation throws on.
Future<bool> ed25519Verify(
  List<int> publicKey,
  List<int> message,
  List<int> signature,
) async {
  if (publicKey.length != ed25519PublicKeyLength ||
      signature.length != ed25519SignatureLength) {
    return false;
  }
  try {
    return await ed25519.verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  } on Object {
    return false;
  }
}

/// The public key of [keyPair].
Future<Uint8List> ed25519PublicKey(SimpleKeyPair keyPair) async {
  final key = await keyPair.extractPublicKey();
  if (key.type != KeyPairType.ed25519 ||
      key.bytes.length != ed25519PublicKeyLength) {
    throw ArgumentError.value(keyPair, 'keyPair', 'not an Ed25519 key pair');
  }
  return Uint8List.fromList(key.bytes);
}

/// Compares in time independent of where the first difference is.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
