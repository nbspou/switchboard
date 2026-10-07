// Test vectors from the wiki page "Switchboard Test Vectors", section
// "Credentials" and the NONCE and IDENT rows of "Mux frames". Platform
// independent: runs on the VM and, compiled to JavaScript, with
// `dart test -P node`, which checks the u32 times and the pure Dart Ed25519
// on the web.

import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/identity/credential.dart';
import 'package:switchboard/src/identity/credential_issuer.dart';
import 'package:switchboard/src/identity/credential_verifier.dart';
import 'package:switchboard/src/identity/holder_key.dart';
import 'package:switchboard/src/mux/mux_frame.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/status.dart';
import 'package:test/test.dart';

/// 2026-01-01T00:00:00Z.
const issuedAt = 1767225600;

/// Eight hours later.
const expiresAt = issuedAt + 8 * 3600;

final hmacKey = Uint8List.fromList(List.generate(32, (i) => i));

/// RFC 8032, section 7.1, test 1 (the authority) and test 2 (the holder).
final authoritySeed = hexBytes(
  '9D 61 B1 9D EF FD 5A 60 BA 84 4A F4 92 EC 2C C4 '
  '44 49 C5 69 7B 32 69 19 70 3B AC 03 1C AE 7F 60',
);
const authorityPublic =
    'D7 5A 98 01 82 B1 0A B7 D5 4B FE D3 C9 64 07 3A '
    '0E E1 72 F3 DA A6 23 25 AF 02 1A 68 F7 07 51 1A';
final holderSeed = hexBytes(
  '4C CD 08 9B 28 FF 96 DA 9D B6 C3 46 EC 11 4E 0F '
  '5B 8A 31 9F 35 AB A6 24 DA 8C F6 ED 4F B8 A6 FB',
);
const holderPublic =
    '3D 40 17 C3 E8 43 89 5A 92 B7 0A A7 4D 1B 7E BC '
    '9C 98 2C CF 2E C4 96 8C C0 CD 55 F1 2A F4 66 0C';

const hmacCredential =
    '01 01 6B 31 00 00 00 00 00 00 05 6E 70 63 2D 37 '
    '00 B9 55 69 80 29 56 69 00 03 01 6E 70 63 00 00 '
    '00 00 00 02 2A 00 00 00 00 00 00 00 03 6E 70 63 '
    '2D 2A 00 00 00 01 84 DB E9 02 5A 34 E5 C3 7A C8 '
    'BC C2 B7 7C 7B 6D E6 84 51 7A F1 7B C8 41 66 34 '
    '8A BE 22 D9 E3 C9';

const ed25519Credential =
    '01 01 61 75 74 68 31 00 00 00 09 77 6F 72 6B 65 '
    '72 2D 61 31 00 B9 55 69 80 29 56 69 20 3D 40 17 '
    'C3 E8 43 89 5A 92 B7 0A A7 4D 1B 7E BC 9C 98 2C '
    'CF 2E C4 96 8C C0 CD 55 F1 2A F4 66 0C 01 01 77 '
    '6F 72 6B 65 72 2D 2A 02 AF F7 12 8F FF 57 0A 4F '
    'F6 08 6D F4 20 36 FF 70 29 30 5D E6 86 32 D5 E2 '
    '95 CC 95 0E 78 B8 FC D9 E2 65 6D F2 AE 58 CB 87 '
    '43 28 A1 73 DD 13 77 56 DF 89 91 45 74 59 E4 91 '
    'FE AC 35 CB EC A3 2F 0A';

final senderNonce = Uint8List(32)..fillRange(0, 32, 0x11);
final receiverNonce = Uint8List(32)..fillRange(0, 32, 0x22);
final intent = hexBytes('01 02 03 04');

/// The receiver `consumer`, in UTF-8.
final receiver = hexBytes('63 6F 6E 73 75 6D 65 72');

const proof =
    '4A 11 15 AE FE D7 6E 3A 3E 00 0A FA C8 64 73 BC '
    'D5 16 3C 32 7E 54 80 8F 44 A2 34 9E 33 C5 36 DF '
    '05 A5 BA 33 FD 04 F2 81 E3 11 11 25 45 23 48 37 '
    'B3 6B DB 22 CA 8A 17 45 00 23 9F D7 1D EC 8B 0B';

final at = DateTime.fromMillisecondsSinceEpoch(
  (issuedAt + 60) * 1000,
  isUtc: true,
);

Matcher throwsCode(StatusCode code) =>
    throwsA(isA<SwitchboardException>().having((e) => e.code, 'code', code));

void main() {
  group('credential layout', () {
    test('HMAC-SHA256 credential with a fixed key', () async {
      final issuer = CredentialIssuer.hmac(Name('k1'), hmacKey);
      final issued = await issuer.issue(
        kind: CredentialKind.node,
        identity: 'npc-7',
        scopes: [
          Scope.of(Right.register, 'npc'),
          Scope.of(Right.open, '*'),
          Scope.of(Right.watch, 'npc-*'),
        ],
        issuedAt: DateTime.fromMillisecondsSinceEpoch(
          issuedAt * 1000,
          isUtc: true,
        ),
        lifetime: const Duration(hours: 8),
      );
      expect(hexString(issued.encode()), hmacCredential);

      final decoded = Credential.decode(hexBytes(hmacCredential));
      expect(decoded.version, 1);
      expect(decoded.kind, CredentialKind.node);
      expect(decoded.keyId, Name('k1'));
      expect(decoded.identity, 'npc-7');
      expect(decoded.issuedAt, issuedAt);
      expect(decoded.expiresAt, expiresAt);
      expect(decoded.holderKey, isNull);
      expect(decoded.isBearer, isTrue);
      expect(decoded.scopes, [
        Scope.of(Right.register, 'npc'),
        Scope.of(Right.open, '*'),
        Scope.of(Right.watch, 'npc-*'),
      ]);
      expect(decoded.signatureKind, SignatureKind.hmacSha256);
      expect(decoded, issued);
      expect(hexString(decoded.encode()), hmacCredential);
      expect(
        hexString(decoded.signedBytes),
        hmacCredential.substring(0, 54 * 3 - 1),
      );
      expect(decoded.issuedAtTime, DateTime.utc(2026));
      expect(decoded.expiresAtTime, DateTime.utc(2026, 1, 1, 8));

      final verifier = CredentialVerifier(hmacKeys: {Name('k1'): hmacKey});
      expect(await verifier.verify(hexBytes(hmacCredential), now: at), decoded);
    });

    test('Ed25519 credential with a holder key, from fixed seeds', () async {
      // The pure Dart implementation throughout: the default SHA-512 of
      // package:cryptography is a platform one, unusable on Node.js.
      final authority = await DartEd25519(sha512: const DartSha512())
          .newKeyPairFromSeed(authoritySeed);
      final issuer = CredentialIssuer.ed25519(Name('auth1'), authority);
      expect(hexString(await issuer.publicKey()), authorityPublic);
      final fromSeed = await CredentialIssuer.ed25519FromSeed(
        Name('auth1'),
        authoritySeed,
      );
      expect(hexString(await fromSeed.publicKey()), authorityPublic);
      final holder = await HolderKey.fromSeed(holderSeed);
      expect(hexString(holder.publicKey), holderPublic);
      final issued = await issuer.issue(
        kind: CredentialKind.node,
        identity: 'worker-a1',
        scopes: [Scope.of(Right.register, 'worker-*')],
        holderKey: holder.publicKey,
        issuedAt: DateTime.fromMillisecondsSinceEpoch(
          issuedAt * 1000,
          isUtc: true,
        ),
      );
      expect(hexString(issued.encode()), ed25519Credential);

      final decoded = Credential.decode(hexBytes(ed25519Credential));
      expect(decoded.keyId, Name('auth1'));
      expect(decoded.identity, 'worker-a1');
      expect(hexString(decoded.holderKey!), holderPublic);
      expect(decoded.isBearer, isFalse);
      expect(decoded.scopes, [Scope.of(Right.register, 'worker-*')]);
      expect(decoded.signatureKind, SignatureKind.ed25519);

      final verifier = CredentialVerifier(
        ed25519Keys: {Name('auth1'): hexBytes(authorityPublic)},
      );
      expect(
        await verifier.verify(hexBytes(ed25519Credential), now: at),
        decoded,
      );
    });

    test('a scope with an unknown right is ignored, the bytes kept', () {
      // The HMAC vector with the third scope's right changed to 0x08.
      final bytes = hexBytes(hmacCredential);
      bytes[44] = 0x08;
      final decoded = Credential.decode(bytes);
      expect(decoded.scopes, [
        Scope.of(Right.register, 'npc'),
        Scope.of(Right.open, '*'),
      ]);
      expect(decoded.encode(), bytes);
      expect(hexString(decoded.signedBytes), hexString(bytes.sublist(0, 54)));
    });

    group('negative (malformed)', () {
      void negative(String name, Uint8List Function() bytes) {
        test(name, () async {
          expect(
            () => Credential.decode(bytes()),
            throwsA(isA<ProtocolException>()),
          );
          final verifier = CredentialVerifier(hmacKeys: {Name('k1'): hmacKey});
          await expectLater(
            verifier.verify(bytes(), now: at),
            throwsCode(StatusCode.unauthenticated),
          );
        });
      }

      Uint8List patched(int offset, int value) =>
          hexBytes(hmacCredential)..[offset] = value;

      negative('version 2', () => patched(0, 0x02));
      negative('kind 0', () => patched(1, 0x00));
      negative('kind 4', () => patched(1, 0x04));
      negative('key id with a byte after a zero', () => patched(5, 0x62));
      negative('identity that is not UTF-8', () => patched(11, 0xFF));
      negative('holder key length 5', () => patched(24, 0x05));
      negative('signature kind 3', () => patched(53, 0x03));
      negative(
        'signature kind 2 with a 32-byte signature',
        () => patched(53, 0x02),
      );
      negative('truncated signature', () {
        final bytes = hexBytes(hmacCredential);
        return Uint8List.sublistView(bytes, 0, bytes.length - 1);
      });
      negative(
        'a byte after the signature',
        () => Uint8List.fromList([...hexBytes(hmacCredential), 0x00]),
      );
      negative('empty', () => Uint8List(0));
      negative('longer than 637 bytes', () => Uint8List(638));
    });

    group('negative (signature)', () {
      test('a flipped signature bit', () async {
        final verifier = CredentialVerifier(hmacKeys: {Name('k1'): hmacKey});
        final bytes = hexBytes(hmacCredential);
        bytes[bytes.length - 1] ^= 0x01;
        await expectLater(
          verifier.verify(bytes, now: at),
          throwsCode(StatusCode.unauthenticated),
        );
      });

      test('a flipped bit in a signed field', () async {
        final verifier = CredentialVerifier(
          ed25519Keys: {Name('auth1'): hexBytes(authorityPublic)},
        );
        final bytes = hexBytes(ed25519Credential);
        // The last byte of the scope pattern: worker-* becomes worker-+.
        bytes[70] ^= 0x01;
        expect(
          Credential.decode(bytes).scopes.single.pattern,
          Name('worker-+'),
        );
        await expectLater(
          verifier.verify(bytes, now: at),
          throwsCode(StatusCode.unauthenticated),
        );
      });

      test('an HMAC credential that names a holder key', () async {
        final draft = Credential(
          kind: CredentialKind.node,
          keyId: Name('k1'),
          identity: 'x',
          issuedAt: issuedAt,
          expiresAt: expiresAt,
          holderKey: hexBytes(holderPublic),
          signatureKind: SignatureKind.hmacSha256,
          signature: Uint8List(32),
        );
        final signed = Credential(
          kind: draft.kind,
          keyId: draft.keyId,
          identity: draft.identity,
          issuedAt: draft.issuedAt,
          expiresAt: draft.expiresAt,
          holderKey: draft.holderKey,
          signatureKind: draft.signatureKind,
          signature: hmacSha256(hmacKey, draft.signedBytes),
        );
        final verifier = CredentialVerifier(hmacKeys: {Name('k1'): hmacKey});
        await expectLater(
          verifier.verify(signed.encode(), now: at),
          throwsCode(StatusCode.unauthenticated),
        );
      });
    });
  });

  group('scope patterns', () {
    for (final (pattern, name, matches) in [
      ('*', 'anything', true),
      ('*', '', true),
      ('*', '_ns', true),
      ('npc', 'npc', true),
      ('npc', 'npc-1', false),
      ('npc', 'np', false),
      ('npc-*', 'npc-1', true),
      ('npc-*', 'npc-', true),
      ('npc-*', 'npc', false),
      ('npc-*', 'npcx', false),
      ('n*c', 'n*c', true),
      ('n*c', 'nxc', false),
      ('abcdefg*', 'abcdefgh', true),
      ('abcdefg*', 'abcdefg', true),
      ('abcdefgh', 'abcdefgh', true),
      ('', '', true),
      ('', 'a', false),
    ]) {
      test('"$pattern" ${matches ? 'matches' : 'does not match'} "$name"', () {
        expect(Scope.of(Right.open, pattern).matches(Name(name)), matches);
      });
    }

    test('admin allows everything', () {
      final credential = Credential(
        kind: CredentialKind.node,
        keyId: Name('k'),
        identity: 'root',
        issuedAt: 0,
        expiresAt: 0,
        scopes: [Scope.of(Right.admin, 'nothing')],
        signatureKind: SignatureKind.hmacSha256,
        signature: Uint8List(32),
      );
      expect(credential.allows(Right.open, Name('x')), isTrue);
      expect(credential.allows(Right.broker, Name('_ns')), isTrue);
    });
  });

  group('connection identity control messages', () {
    test('NONCE', () {
      expect(
        hexString(MuxControlMessage.nonce(senderNonce).toFrame().encode()),
        '02 00 00 05 ${hexString(senderNonce)}',
      );
    });

    test('IDENT, bearer credential, no intent, no receiver, no proof', () {
      final ident = MuxIdent(credential: hexBytes(hmacCredential));
      expect(
        hexString(MuxControlMessage.ident(ident).toFrame().encode()),
        '02 00 00 06 56 00 $hmacCredential 00 00',
      );
      final decoded = MuxIdent.decode(hexBytes('56 00 $hmacCredential 00 00'));
      expect(hexString(decoded.credential), hmacCredential);
      expect(decoded.intent, isEmpty);
      expect(decoded.receiver, isEmpty);
      expect(decoded.proof, isEmpty);
    });

    test('IDENT, holder-key credential, intent, receiver, proof', () async {
      final message = MuxIdent.proofMessage(
        senderNonce,
        receiverNonce,
        intent,
        receiver,
      );
      expect(
        hexString(message),
        '53 57 42 49 44 45 4E 54 ${hexString(senderNonce)} '
        '${hexString(receiverNonce)} 04 01 02 03 04 '
        '08 63 6F 6E 73 75 6D 65 72',
      );
      expect(message, hasLength(86));
      final holder = await HolderKey.fromSeed(holderSeed);
      expect(hexString(await holder.sign(message)), proof);
      final ident = MuxIdent(
        credential: hexBytes(ed25519Credential),
        intent: intent,
        receiver: receiver,
        proof: hexBytes(proof),
      );
      const frame =
          '02 00 00 06 88 00 $ed25519Credential 04 01 02 03 04 '
          '08 63 6F 6E 73 75 6D 65 72 $proof';
      expect(
        hexString(MuxControlMessage.ident(ident).toFrame().encode()),
        frame,
      );
      final decoded = MuxIdent.decode(
        MuxControlMessage.decode(MuxFrame.decode(hexBytes(frame)).payload)
            .payload,
      );
      expect(hexString(decoded.credential), ed25519Credential);
      expect(hexString(decoded.intent), '01 02 03 04');
      expect(hexString(decoded.receiver), hexString(receiver));
      expect(hexString(decoded.proof), proof);
    });

    test('the proof covers the field lengths', () {
      // The same bytes split differently between intent and receiver sign
      // differently: an IDENT naming `consumer` cannot be passed off as
      // one naming nobody, with the name moved into the intent.
      expect(
        hexString(
          MuxIdent.proofMessage(
            senderNonce,
            receiverNonce,
            Uint8List.fromList([...intent, ...receiver]),
            Uint8List(0),
          ),
        ),
        isNot(
          hexString(
            MuxIdent.proofMessage(senderNonce, receiverNonce, intent, receiver),
          ),
        ),
      );
    });

    group('negative (protocol error)', () {
      for (final (name, hex) in [
        ('truncated credential length', '56'),
        ('credential longer than the payload', '56 00 01 01'),
        ('missing intent length', '02 00 AA BB'),
        ('intent longer than the payload', '00 00 05 01 02'),
        ('intent of 65 bytes', '00 00 41 ${List.filled(65, '00').join(' ')}'),
        ('missing receiver length', '00 00 01 AA'),
        ('receiver longer than the payload', '00 00 00 04 61 62'),
      ]) {
        test(name, () {
          expect(
            () => MuxIdent.decode(hexBytes(hex)),
            throwsA(isA<ProtocolException>()),
          );
        });
      }
    });
  });
}
