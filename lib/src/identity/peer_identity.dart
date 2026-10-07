/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:typed_data';

import '../name.dart';
import 'credential.dart';

/// Who the peer of a connection proved to be: the verified credential of
/// its last valid `IDENT` (`MuxConnection.peerIdentity`).
///
/// See the wiki page "Switchboard Identity and Credentials", section
/// "Connection identity".
class PeerIdentity {
  /// An identity from [credential], verified at [verifiedAt], with the
  /// opaque [intent] the `IDENT` carried and the [receiver] it named
  /// (empty: none).
  PeerIdentity({
    required this.credential,
    required this.intent,
    required this.verifiedAt,
    this.receiver = '',
  });

  /// The verified credential.
  final Credential credential;

  /// The opaque intent of the `IDENT` (used by `CONNECT`), empty when none.
  /// Must not be modified.
  final Uint8List intent;

  /// When the `IDENT` was verified.
  final DateTime verifiedAt;

  /// The receiver the `IDENT` named: this side's identity
  /// (`MuxConnection.localIdentity`), since an `IDENT` naming another is
  /// refused, or empty when it named none.
  final String receiver;

  /// The credential's identity string.
  String get identity => credential.identity;

  /// The credential's kind.
  CredentialKind get kind => credential.kind;

  /// The credential's scopes.
  List<Scope> get scopes => credential.scopes;

  /// Whether the peer proved possession of the credential's holder key
  /// (false for a bearer credential).
  bool get provedPossession => !credential.isBearer;

  /// Whether the credential grants [right] for [name]
  /// ([Credential.allows]).
  bool allows(Right right, Name name) => credential.allows(right, name);

  /// Whether the credential has expired at [now] ([Credential.isExpired]).
  bool isExpired([DateTime? now]) => credential.isExpired(now);

  @override
  String toString() =>
      'PeerIdentity(${kind.name} "$identity"'
      '${intent.isEmpty ? '' : ', intent of ${intent.length} bytes'}'
      '${receiver.isEmpty ? '' : ', to "$receiver"'})';
}
