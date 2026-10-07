/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';

import '../bytes.dart';
import '../name.dart';
import '../status.dart';

/// What a [Credential] identifies.
enum CredentialKind {
  /// A mesh node, which presents its credential with `IDENT` on the
  /// control channel of its connections.
  node(1),

  /// A client session (a user of a frontend), which presents its
  /// credential in the application payload of its channels.
  client(2),

  /// A device, which presents its credential in the application payload
  /// of its channels.
  device(3);

  const CredentialKind(this.code);

  /// Wire value.
  final int code;

  /// The kind for [code], or null if there is none.
  static CredentialKind? fromCode(int code) =>
      code >= 1 && code <= values.length ? values[code - 1] : null;
}

/// A right a [Scope] grants for the service types its pattern matches.
///
/// See the wiki page "Switchboard Identity and Credentials".
enum Right {
  /// May register records of matching types, its own endpoints or others'.
  register(1),

  /// May open channels to matching types on any peer that checks scopes.
  open(2),

  /// May `WATCH`, `UNWATCH` and `LOOKUP` matching types.
  watch(3),

  /// May `CLAIM`, `RELEASE` and declare `HOLDING` for matching types.
  claim(4),

  /// May request `MIGRATE` for matching types.
  migrate(5),

  /// May ask the naming service to make instances of matching types connect
  /// back to it (`CONNECT`).
  broker(6),

  /// Everything, whatever the pattern.
  admin(7);

  const Right(this.code);

  /// Wire value.
  final int code;

  /// The right for [code], or null for a code this implementation does not
  /// know (a scope with such a right is ignored when decoding).
  static Right? fromCode(int code) =>
      code >= 1 && code <= values.length ? values[code - 1] : null;
}

/// How a [Credential] is signed.
enum SignatureKind {
  /// HMAC-SHA256 with a key shared by the mesh; bearer credentials only.
  hmacSha256(1, 32),

  /// Ed25519 with the authority's key pair.
  ed25519(2, 64);

  const SignatureKind(this.code, this.signatureLength);

  /// Wire value.
  final int code;

  /// Length of the signature in bytes.
  final int signatureLength;

  /// The kind for [code], or null if there is none.
  static SignatureKind? fromCode(int code) =>
      code >= 1 && code <= values.length ? values[code - 1] : null;
}

/// A right over the service types a name pattern matches.
///
/// A pattern is a name. A `*` as its last non-zero byte matches any
/// suffix, the empty one included: `worker-*` matches `worker-a1` and
/// `worker-` but not `worker`; `*` alone matches every name, the empty
/// name too. Any other pattern matches exactly that name. A `*` anywhere
/// else is an ordinary byte.
class Scope {
  /// A scope granting [right] for the names [pattern] matches.
  const Scope(this.right, this.pattern);

  /// A scope granting [right] for [pattern] given as text, such as
  /// `Scope.of(Right.register, 'worker-*')`. Throws [ArgumentError] like
  /// [Name.new].
  Scope.of(Right right, String pattern) : this(right, Name(pattern));

  /// The right granted.
  final Right right;

  /// The name pattern.
  final Name pattern;

  /// Encoded size: the right byte and the 8-byte pattern.
  static const int encodedLength = 1 + Name.byteLength;

  /// The wildcard byte, `*`.
  static const int wildcard = 0x2A;

  /// Whether [pattern] matches [name] (see [Scope]).
  bool matches(Name name) => patternMatches(pattern, name);

  /// Whether the name pattern [pattern] matches [name] (see [Scope]).
  static bool patternMatches(Name pattern, Name name) {
    final p = pattern.bytes;
    final n = pattern.length;
    if (n > 0 && p[n - 1] == wildcard) {
      final q = name.bytes;
      for (var i = 0; i < n - 1; i++) {
        if (q[i] != p[i]) {
          return false;
        }
      }
      return true;
    }
    return pattern == name;
  }

  @override
  bool operator ==(Object other) =>
      other is Scope && other.right == right && other.pattern == pattern;

  @override
  int get hashCode => Object.hash(right, pattern);

  /// The right and the pattern, as in `register worker-*`.
  @override
  String toString() => '${right.name} $pattern';
}

/// A signed statement of the mesh authority: who the holder is
/// ([identity], [kind]) and what it may do ([scopes]), until [expiresAt].
///
/// The binary layout is the one of the wiki page "Switchboard Identity and
/// Credentials", section "Credential": every field in order, then the
/// signature over every preceding byte. [CredentialIssuer] signs
/// credentials and [CredentialVerifier] checks them; this class is the
/// codec and does not verify anything.
class Credential {
  /// A credential with the given fields; [signature] is not checked.
  ///
  /// [issuedAt] and [expiresAt] are unix seconds (`u32`); an [expiresAt]
  /// of 0 means never. [holderKey] is null for a bearer credential, or the
  /// 32-byte Ed25519 public key of the holder. Lists are copied.
  ///
  /// Throws [ArgumentError] for an [identity] over 255 bytes of UTF-8, a
  /// time outside `u32`, a [holderKey] that is not 32 bytes, more than 255
  /// scopes, a [signature] whose length is not the one of [signatureKind],
  /// or an encoding longer than [maxLength].
  Credential({
    required this.kind,
    required this.keyId,
    required this.identity,
    required this.issuedAt,
    required this.expiresAt,
    List<int>? holderKey,
    List<Scope> scopes = const [],
    required this.signatureKind,
    required List<int> signature,
  }) : version = currentVersion,
       holderKey = holderKey == null ? null : Uint8List.fromList(holderKey),
       scopes = List.unmodifiable(scopes),
       signature = Uint8List.fromList(signature),
       _signedLength = null {
    _check();
    final length = _encodeSigned().length + this.signature.length;
    if (length > maxLength) {
      throw ArgumentError(
        'credential of $length bytes exceeds the maximum of $maxLength',
      );
    }
  }

  Credential._decoded(
    this.kind,
    this.keyId,
    this.identity,
    this.issuedAt,
    this.expiresAt,
    this.holderKey,
    List<Scope> scopes,
    this.signatureKind,
    this.signature,
    Uint8List encoded,
    int signedLength,
  ) : version = currentVersion,
      scopes = List.unmodifiable(scopes),
      _encoded = encoded,
      _signedLength = signedLength;

  /// The layout version this implementation reads and writes.
  static const int currentVersion = 1;

  /// Largest encoded credential: 637 bytes, so that an `IDENT` carrying it
  /// with the largest intent (64 bytes), the longest receiver (255 bytes)
  /// and a proof (64 bytes) fits the 1024-byte limit of a control payload
  /// (`2 + 637 + 1 + 64 + 1 + 255 + 64`).
  static const int maxLength = 637;

  /// Length of a holder key (an Ed25519 public key).
  static const int holderKeyLength = 32;

  /// The layout version, [currentVersion].
  final int version;

  /// What the credential identifies.
  final CredentialKind kind;

  /// Which issuer key signed it; the verifier looks the key up by this.
  final Name keyId;

  /// The holder's identity, such as `npc-7` or `worker-a1`.
  final String identity;

  /// When it was issued, in unix seconds. Informational: receivers check
  /// only [expiresAt].
  final int issuedAt;

  /// When it expires, in unix seconds; 0 means never (discouraged).
  final int expiresAt;

  /// The holder's Ed25519 public key (32 bytes), or null for a bearer
  /// credential. Must not be modified.
  final Uint8List? holderKey;

  /// What the holder may do. Unmodifiable.
  final List<Scope> scopes;

  /// How it is signed.
  final SignatureKind signatureKind;

  /// The signature over [signedBytes]. Must not be modified.
  final Uint8List signature;

  // The exact bytes a decoded credential came from, kept so that encode()
  // and signedBytes reproduce them even when decoding dropped scopes with
  // unknown rights.
  Uint8List? _encoded;
  final int? _signedLength;

  /// Whether the credential is a bearer credential: whoever has the bytes
  /// is the holder. False when it names a [holderKey].
  bool get isBearer => holderKey == null;

  /// [issuedAt] as a UTC time.
  DateTime get issuedAtTime =>
      DateTime.fromMillisecondsSinceEpoch(issuedAt * 1000, isUtc: true);

  /// [expiresAt] as a UTC time, or null for a credential that never
  /// expires.
  DateTime? get expiresAtTime => expiresAt == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000, isUtc: true);

  /// Whether the credential has expired at [now] (default: the current
  /// time of `package:clock`): [expiresAt] is not 0 and [now] is at or
  /// after it.
  bool isExpired([DateTime? now]) =>
      expiresAt != 0 &&
      (now ?? clock.now()).millisecondsSinceEpoch ~/ 1000 >= expiresAt;

  /// Whether a scope grants [right] for [name]. A scope with
  /// [Right.admin] grants everything.
  bool allows(Right right, Name name) {
    for (final scope in scopes) {
      if (scope.right == Right.admin ||
          (scope.right == right && scope.matches(name))) {
        return true;
      }
    }
    return false;
  }

  /// The bytes the signature covers: every byte of the encoding before the
  /// signature, the signature kind included.
  Uint8List get signedBytes {
    final encoded = _encoded;
    final signedLength = _signedLength;
    if (encoded != null && signedLength != null) {
      return Uint8List.fromList(
        Uint8List.sublistView(encoded, 0, signedLength),
      );
    }
    return _encodeSigned();
  }

  /// The encoding: [signedBytes] followed by the [signature]. A decoded
  /// credential encodes to exactly the bytes it was decoded from.
  Uint8List encode() {
    final encoded = _encoded ??=
        (BytesBuilder(copy: false)
              ..add(_encodeSigned())
              ..add(signature))
            .toBytes();
    return Uint8List.fromList(encoded);
  }

  void _check() {
    if (utf8.encode(identity).length > 0xFF) {
      throw ArgumentError.value(
        identity,
        'identity',
        'longer than 255 bytes of UTF-8',
      );
    }
    for (final (name, value) in [
      ('issuedAt', issuedAt),
      ('expiresAt', expiresAt),
    ]) {
      if (value < 0 || value > 0xFFFFFFFF) {
        throw ArgumentError.value(value, name, 'must fit in u32');
      }
    }
    final holder = holderKey;
    if (holder != null && holder.length != holderKeyLength) {
      throw ArgumentError.value(
        holder.length,
        'holderKey',
        'must be $holderKeyLength bytes',
      );
    }
    if (scopes.length > 0xFF) {
      throw ArgumentError.value(scopes.length, 'scopes', 'at most 255 scopes');
    }
    if (signature.length != signatureKind.signatureLength) {
      throw ArgumentError.value(
        signature.length,
        'signature',
        '${signatureKind.name} signatures are '
            '${signatureKind.signatureLength} bytes',
      );
    }
  }

  Uint8List _encodeSigned() {
    final holder = holderKey;
    final w = ByteWriter(64 + scopes.length * Scope.encodedLength)
      ..u8(version)
      ..u8(kind.code)
      ..name(keyId)
      ..string8(identity)
      ..u32(issuedAt)
      ..u32(expiresAt)
      ..u8(holder?.length ?? 0);
    if (holder != null) {
      w.bytes(holder);
    }
    w.u8(scopes.length);
    for (final scope in scopes) {
      w
        ..u8(scope.right.code)
        ..name(scope.pattern);
    }
    w.u8(signatureKind.code);
    return w.toBytes();
  }

  /// Decodes a credential. Does not verify the signature.
  ///
  /// Scopes with a right this implementation does not know are dropped
  /// (they could only grant more); [encode] still returns [bytes] exactly.
  ///
  /// Throws [ProtocolException] for an encoding longer than [maxLength], a
  /// version other than [currentVersion], an unknown kind or signature
  /// kind, an identity that is not UTF-8, an invalid name (key id or
  /// pattern), a holder key length other than 0 or 32, truncation, and
  /// bytes after the signature.
  static Credential decode(Uint8List bytes) {
    if (bytes.length > maxLength) {
      throw ProtocolException(
        'credential of ${bytes.length} bytes exceeds $maxLength',
      );
    }
    final r = ByteReader(bytes);
    try {
      final version = r.u8('version');
      if (version != currentVersion) {
        throw ProtocolException('unsupported credential version $version');
      }
      final kindCode = r.u8('kind');
      final kind =
          CredentialKind.fromCode(kindCode) ??
          (throw ProtocolException('unknown credential kind $kindCode'));
      final keyId = r.name('key id');
      final identityLength = r.u8('identity length');
      final identity = utf8.decode(r.take(identityLength, 'identity'));
      final issuedAt = r.u32('issued at');
      final expiresAt = r.u32('expires at');
      final holderLength = r.u8('holder key length');
      if (holderLength != 0 && holderLength != holderKeyLength) {
        throw ProtocolException('holder key of $holderLength bytes');
      }
      final holderKey = holderLength == 0
          ? null
          : Uint8List.fromList(r.take(holderLength, 'holder key'));
      final count = r.u8('scope count');
      final scopes = <Scope>[];
      for (var i = 0; i < count; i++) {
        final right = Right.fromCode(r.u8('right'));
        final pattern = r.name('pattern');
        if (right != null) {
          scopes.add(Scope(right, pattern));
        }
      }
      final signatureCode = r.u8('signature kind');
      final signatureKind =
          SignatureKind.fromCode(signatureCode) ??
          (throw ProtocolException('unknown signature kind $signatureCode'));
      final signedLength = r.offset;
      final signature = Uint8List.fromList(
        r.take(signatureKind.signatureLength, 'signature'),
      );
      if (!r.isDone) {
        throw ProtocolException('${r.remaining} bytes after the signature');
      }
      return Credential._decoded(
        kind,
        keyId,
        identity,
        issuedAt,
        expiresAt,
        holderKey,
        scopes,
        signatureKind,
        signature,
        Uint8List.fromList(bytes),
        signedLength,
      );
    } on FormatException catch (e) {
      throw ProtocolException('malformed credential: ${e.message}');
    }
  }

  /// Equal when the encodings are equal.
  @override
  bool operator ==(Object other) {
    if (other is! Credential) {
      return false;
    }
    final a = encode();
    final b = other.encode();
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(signature);

  /// The kind, identity, key id, expiry and scopes, for logs. Never the
  /// signature.
  @override
  String toString() =>
      'Credential(${kind.name} "$identity", key $keyId, '
      '${expiresAt == 0 ? 'never expires' : 'expires $expiresAtTime'}'
      '${isBearer ? ', bearer' : ''}'
      '${scopes.isEmpty ? '' : ', ${scopes.join(', ')}'})';
}
