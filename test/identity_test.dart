// Credentials (issuer, verifier, key rotation, the cache) and connection
// identity on the mux control channel (NONCE and IDENT), over
// MemoryTransport. Platform independent: also runs on Node.js with
// `dart test -P node`. The byte layouts are in
// test/vectors/identity_vectors_test.dart.

import 'dart:async';
import 'dart:typed_data';

import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/identity/credential.dart';
import 'package:switchboard/src/identity/credential_issuer.dart';
import 'package:switchboard/src/identity/credential_verifier.dart';
import 'package:switchboard/src/identity/holder_key.dart';
import 'package:switchboard/src/identity/peer_identity.dart';
import 'package:switchboard/src/mux/mux_connection.dart';
import 'package:switchboard/src/mux/mux_frame.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/status.dart';
import 'package:test/test.dart';

import 'mux_harness.dart';

final meshKey = Uint8List.fromList(List.generate(32, (i) => i));
final otherKey = Uint8List.fromList(List.generate(32, (i) => 100 + i));
final authoritySeed = Uint8List.fromList(List.generate(32, (i) => 7 * i));

late CredentialIssuer hmacIssuer;
late CredentialIssuer edIssuer;
late HolderKey holder;

/// A bearer credential for `npc-7`.
Future<Credential> bearer({
  CredentialIssuer? issuer,
  String identity = 'npc-7',
  DateTime? issuedAt,
  Duration? lifetime = const Duration(hours: 1),
}) => (issuer ?? hmacIssuer).issue(
  kind: CredentialKind.node,
  identity: identity,
  scopes: [Scope.of(Right.open, 'npc'), Scope.of(Right.register, 'npc')],
  issuedAt: issuedAt,
  lifetime: lifetime,
);

/// A credential for `worker-a1` naming [holder]'s key.
Future<Credential> held({String identity = 'worker-a1'}) => edIssuer.issue(
  kind: CredentialKind.node,
  identity: identity,
  scopes: [Scope.of(Right.register, 'worker-*')],
  holderKey: holder.publicKey,
);

Future<CredentialVerifier> verifierFor(
  List<CredentialIssuer> issuers, {
  int cacheSize = CredentialVerifier.defaultCacheSize,
}) async {
  final verifier = CredentialVerifier(cacheSize: cacheSize);
  for (final issuer in issuers) {
    await verifier.addIssuer(issuer);
  }
  return verifier;
}

/// Two connected muxes; [acceptorVerifier] checks the initiator's IDENT,
/// [initiatorVerifier] the acceptor's.
(MuxConnection, MuxConnection) identityPair({
  CredentialVerifier? acceptorVerifier,
  CredentialVerifier? initiatorVerifier,
  Duration identityTimeout = const Duration(seconds: 5),
}) => muxPair(
  initiator: quiet.copyWith(
    identityVerifier: initiatorVerifier,
    identityTimeout: identityTimeout,
  ),
  acceptor: quiet.copyWith(
    identityVerifier: acceptorVerifier,
    identityTimeout: identityTimeout,
  ),
);

/// The frame of a control message of [type] carrying [payload].
String control(MuxControlType type, Uint8List payload) =>
    hexString(MuxControlMessage(type.code, payload).toFrame().encode());

void main() {
  setUpAll(() async {
    hmacIssuer = CredentialIssuer.hmac(Name('mesh1'), meshKey);
    edIssuer = await CredentialIssuer.ed25519FromSeed(
      Name('auth1'),
      authoritySeed,
    );
    holder = await HolderKey.generate();
  });

  group('issuer', () {
    test('lifetime, issue time and never expiring', () async {
      final at = DateTime.utc(2026, 3, 1, 12, 0, 0, 999);
      final credential = await bearer(
        issuedAt: at,
        lifetime: const Duration(minutes: 90),
      );
      expect(credential.issuedAtTime, DateTime.utc(2026, 3, 1, 12));
      expect(credential.expiresAtTime, DateTime.utc(2026, 3, 1, 13, 30));
      expect(credential.isExpired(DateTime.utc(2026, 3, 1, 13, 29)), isFalse);
      expect(credential.isExpired(DateTime.utc(2026, 3, 1, 13, 30)), isTrue);
      final forever = await bearer(lifetime: null);
      expect(forever.expiresAt, 0);
      expect(forever.expiresAtTime, isNull);
      expect(forever.isExpired(DateTime.utc(2100)), isFalse);
    });

    test('refuses what the layout or the signature kind cannot carry', () {
      expect(
        () => CredentialIssuer.hmac(Name('k'), Uint8List(15)),
        throwsArgumentError,
      );
      expect(
        () => hmacIssuer.issue(
          kind: CredentialKind.node,
          identity: 'x',
          holderKey: holder.publicKey,
        ),
        throwsArgumentError,
      );
      expect(
        () => hmacIssuer.issue(kind: CredentialKind.node, identity: 'x' * 256),
        throwsArgumentError,
      );
      expect(
        () => hmacIssuer.issue(
          kind: CredentialKind.node,
          identity: 'x',
          lifetime: Duration.zero,
        ),
        throwsArgumentError,
      );
      // 22 bytes of fields, 95 scopes of 9 bytes, the signature kind and a
      // 32-byte MAC: longer than an IDENT can carry.
      expect(
        () => hmacIssuer.issue(
          kind: CredentialKind.node,
          identity: 'x',
          scopes: List.filled(95, Scope.of(Right.open, 'x')),
        ),
        throwsArgumentError,
      );
      expect(
        () => edIssuer.issue(
          kind: CredentialKind.node,
          identity: 'x',
          holderKey: Uint8List(31),
        ),
        throwsArgumentError,
      );
      expect(() => hmacIssuer.publicKey(), throwsStateError);
    });

    test(
      'the largest credential fits an IDENT with intent and proof',
      () async {
        final credential = await edIssuer.issue(
          kind: CredentialKind.node,
          identity: 'x' * 255,
          holderKey: holder.publicKey,
          // 308 bytes of fields, the signature kind and a 64-byte
          // signature leave room for 57 scopes.
          scopes: List.filled(
            (Credential.maxLength - 373) ~/ Scope.encodedLength,
            Scope.of(Right.open, 'x'),
          ),
        );
        expect(
          credential.encode().length,
          lessThanOrEqualTo(Credential.maxLength),
        );
        final ident = MuxIdent(
          credential: credential.encode(),
          intent: Uint8List(MuxIdent.maxIntentLength),
          proof: Uint8List(MuxIdent.proofLength),
        );
        expect(
          ident.encode().length,
          lessThanOrEqualTo(MuxControlMessage.maxControlPayload),
        );
      },
    );
  });

  group('verifier', () {
    test('verifies both kinds and caches by bytes', () async {
      final verifier = await verifierFor([hmacIssuer, edIssuer]);
      expect(verifier.keyIds, {Name('mesh1'), Name('auth1')});
      final a = await bearer();
      final b = await held();
      expect(await verifier.verify(a.encode()), a);
      expect(await verifier.verify(b.encode()), b);
      expect(verifier.cachedCount, 2);
      expect(await verifier.verify(b.encode()), b);
      expect(verifier.cachedCount, 2);
      // Concurrent checks of new bytes share one check and all succeed.
      final c = await held(identity: 'worker-a2');
      final results = await Future.wait([
        for (var i = 0; i < 5; i++) verifier.verify(c.encode()),
      ]);
      expect(results, everyElement(c));
      expect(verifier.cachedCount, 3);
    });

    test('the cache is bounded, least recently used first', () async {
      final verifier = await verifierFor([hmacIssuer], cacheSize: 2);
      final one = await bearer(identity: 'one');
      final two = await bearer(identity: 'two');
      final three = await bearer(identity: 'three');
      await verifier.verify(one.encode());
      await verifier.verify(two.encode());
      await verifier.verify(one.encode());
      await verifier.verify(three.encode());
      expect(verifier.cachedCount, 2);
      final none = await verifierFor([hmacIssuer], cacheSize: 0);
      await none.verify(one.encode());
      expect(none.cachedCount, 0);
    });

    test('key rotation: current and previous key, then removal', () async {
      final next = CredentialIssuer.hmac(Name('mesh2'), otherKey);
      final verifier = await verifierFor([hmacIssuer, next]);
      final old = await bearer();
      final renewed = await bearer(issuer: next);
      expect(await verifier.verify(old.encode()), old);
      expect(await verifier.verify(renewed.encode()), renewed);
      expect(verifier.removeKey(Name('mesh1')), isTrue);
      expect(verifier.removeKey(Name('mesh1')), isFalse);
      expect(verifier.cachedCount, 0);
      await expectLater(
        verifier.verify(old.encode()),
        throwsStatus(StatusCode.unauthenticated),
      );
      expect(await verifier.verify(renewed.encode()), renewed);
    });

    test('a replaced key no longer verifies what the old one signed', () async {
      final verifier = await verifierFor([hmacIssuer]);
      final credential = await bearer();
      await verifier.verify(credential.encode());
      verifier.addHmacKey(Name('mesh1'), otherKey);
      await expectLater(
        verifier.verify(credential.encode()),
        throwsStatus(StatusCode.unauthenticated),
      );
    });

    test('unknown key id, wrong key kind, expired, generic reason', () async {
      final verifier = await verifierFor([hmacIssuer]);
      final unknown = await bearer(
        issuer: CredentialIssuer.hmac(Name('mesh9'), meshKey),
      );
      // An Ed25519 credential under the id of the HMAC key.
      final mismatched = await (await CredentialIssuer.ed25519FromSeed(
        Name('mesh1'),
        authoritySeed,
      )).issue(kind: CredentialKind.node, identity: 'x');
      final expired = await bearer(
        issuedAt: DateTime.now().subtract(const Duration(hours: 2)),
      );
      for (final credential in [unknown, mismatched, expired]) {
        await expectLater(
          verifier.verify(credential.encode()),
          throwsA(
            isA<SwitchboardException>()
                .having((e) => e.code, 'code', StatusCode.unauthenticated)
                .having((e) => e.status.reason, 'reason', 'invalid credential'),
          ),
        );
      }
      // Expiry is checked against the given time, cached or not.
      final current = await bearer();
      await verifier.verify(current.encode());
      await expectLater(
        verifier.verify(
          current.encode(),
          now: DateTime.now().add(const Duration(hours: 2)),
        ),
        throwsStatus(StatusCode.unauthenticated),
      );
    });

    test('refuses bad keys', () {
      expect(
        () => CredentialVerifier(hmacKeys: {Name('k'): Uint8List(8)}),
        throwsArgumentError,
      );
      expect(
        () => CredentialVerifier(ed25519Keys: {Name('k'): Uint8List(31)}),
        throwsArgumentError,
      );
      expect(
        () => CredentialVerifier(
          hmacKeys: {Name('k'): meshKey},
          ed25519Keys: {Name('k'): Uint8List(32)},
        ),
        throwsArgumentError,
      );
    });
  });

  group('connection identity', () {
    test('bearer credential: identified without a proof', () async {
      final verifier = await verifierFor([hmacIssuer]);
      final (a, b) = identityPair(acceptorVerifier: verifier);
      final credential = await bearer();
      var requested = false;
      unawaited(b.identityRequested.then((_) => requested = true));
      await a.identify(credential);
      final identity = await b.peerIdentified;
      expect(identity.identity, 'npc-7');
      expect(identity.kind, CredentialKind.node);
      expect(identity.provedPossession, isFalse);
      expect(identity.intent, isEmpty);
      expect(identity.credential, credential);
      expect(identity.allows(Right.open, Name('npc')), isTrue);
      expect(identity.allows(Right.open, Name('chat')), isFalse);
      expect(b.peerIdentity, same(identity));
      expect(a.peerIdentity, isNull);
      expect(requested, isTrue);
      expect(a.isOpen && b.isOpen, isTrue);
      await a.close();
      await b.done;
    });

    test('holder-key credential with a proof and an intent', () async {
      final verifier = await verifierFor([edIssuer]);
      final (a, b) = identityPair(acceptorVerifier: verifier);
      await a.identify(
        await held(),
        holderKey: holder,
        intent: hexBytes('01 02 03'),
      );
      final identity = b.peerIdentity!;
      expect(identity.identity, 'worker-a1');
      expect(identity.provedPossession, isTrue);
      expect(hexString(identity.intent), '01 02 03');
      await a.close();
      await b.done;
    });

    test('both directions, independently and at once', () async {
      final verifier = await verifierFor([hmacIssuer, edIssuer]);
      final (a, b) = identityPair(
        acceptorVerifier: verifier,
        initiatorVerifier: verifier,
      );
      await Future.wait([
        a.identify(await bearer(identity: 'left')),
        b.identify(await held(), holderKey: holder),
      ]);
      expect(b.peerIdentity!.identity, 'left');
      expect(a.peerIdentity!.identity, 'worker-a1');
      expect(a.peerIdentity!.provedPossession, isTrue);
      await a.close();
      await b.done;
    });

    test('a second valid IDENT replaces the first', () async {
      final verifier = await verifierFor([hmacIssuer]);
      final (a, b) = identityPair(acceptorVerifier: verifier);
      await a.identify(await bearer(identity: 'first'));
      await a.identify(await bearer(identity: 'second'));
      expect(b.peerIdentity!.identity, 'second');
      expect((await b.peerIdentified).identity, 'first');
      await a.close();
      await b.done;
    });

    test('frames after an IDENT wait for its verification', () async {
      final verifier = await verifierFor([edIssuer]);
      final (b, raw) = rawPair(
        muxIsInitiator: false,
        options: rawOptions.copyWith(identityVerifier: verifier),
      );
      final senderNonce = Uint8List(32)..fillRange(0, 32, 0x11);
      raw.send(control(MuxControlType.nonce, senderNonce));
      final answer = await raw.nextControl(MuxControlType.nonce);
      final credential = await held();
      final intent = Uint8List(0);
      final proof = await holder.sign(
        MuxIdent.proofMessage(senderNonce, answer.payload, intent),
      );
      PeerIdentity? seen;
      final opened = Completer<void>();
      b.incoming.listen((channel) {
        seen = channel.connection.peerIdentity;
        opened.complete();
      });
      // IDENT and OPEN in one burst: the Ed25519 check takes a while, and
      // the OPEN must not overtake it.
      raw
        ..send(
          control(
            MuxControlType.ident,
            MuxIdent(
              credential: credential.encode(),
              intent: intent,
              proof: proof,
            ).encode(),
          ),
        )
        ..send('12 02 00 00');
      await opened.future;
      expect(seen?.identity, 'worker-a1');
      await b.close();
    });

    test('a replayed IDENT from another connection is rejected', () async {
      // First connection: an honest identification, captured by a raw
      // peer that answers with its own nonce.
      final (a, first) = rawPair();
      final identifying = a.identify(await held(), holderKey: holder);
      final aNonce = await first.nextControl(MuxControlType.nonce);
      first.send(
        control(MuxControlType.nonce, Uint8List(32)..fillRange(0, 32, 0x22)),
      );
      final ident = await first.nextControl(MuxControlType.ident);
      final ping = await first.nextControl(MuxControlType.ping);
      first.send(control(MuxControlType.pong, ping.payload));
      await identifying;
      await a.close();

      // Second connection: the attacker replays the nonce and the IDENT of
      // the first, but the receiver's nonce is a new one.
      final verifier = await verifierFor([edIssuer]);
      final (b, raw) = rawPair(
        muxIsInitiator: false,
        options: rawOptions.copyWith(identityVerifier: verifier),
      );
      raw.send(control(MuxControlType.nonce, aNonce.payload));
      final bNonce = await raw.nextControl(MuxControlType.nonce);
      expect(hexString(bNonce.payload), isNot(hexString(aNonce.payload)));
      raw.send(control(MuxControlType.ident, ident.payload));
      final goAway = await raw.nextControl(MuxControlType.goAway);
      expect(goAway.goAwayStatus, hasCode(StatusCode.unauthenticated));
      expect(goAway.goAwayStatus.reason, 'identification failed');
      expect(await b.done, hasCode(StatusCode.unauthenticated));
      expect(b.peerIdentity, isNull);
    });

    test('a bearer IDENT with a proof is rejected', () async {
      final verifier = await verifierFor([hmacIssuer]);
      final (b, raw) = rawPair(
        muxIsInitiator: false,
        options: rawOptions.copyWith(identityVerifier: verifier),
      );
      raw.send(control(MuxControlType.nonce, Uint8List(32)));
      await raw.nextControl(MuxControlType.nonce);
      raw.send(
        control(
          MuxControlType.ident,
          MuxIdent(
            credential: (await bearer()).encode(),
            proof: Uint8List(64),
          ).encode(),
        ),
      );
      expect(await b.done, hasCode(StatusCode.unauthenticated));
    });

    for (final (name, make) in <(String, Future<Credential> Function())>[
      (
        'an expired credential',
        () =>
            bearer(issuedAt: DateTime.now().subtract(const Duration(hours: 2))),
      ),
      (
        'an unknown key id',
        () => bearer(issuer: CredentialIssuer.hmac(Name('mesh9'), meshKey)),
      ),
      (
        'a forged signature',
        () async {
          final good = (await bearer()).encode();
          good[good.length - 1] ^= 0x80;
          return Credential.decode(good);
        },
      ),
    ]) {
      test('$name ends the connection with GOAWAY UNAUTHENTICATED', () async {
        final verifier = await verifierFor([hmacIssuer]);
        final (a, b) = identityPair(acceptorVerifier: verifier);
        final peerStatus = a.peerGoAwayStatus;
        await expectLater(
          a.identify(await make()),
          throwsStatus(StatusCode.unauthenticated),
        );
        expect(await peerStatus, hasCode(StatusCode.unauthenticated));
        expect(await b.done, hasCode(StatusCode.unauthenticated));
        expect(b.peerIdentity, isNull);
        await a.done;
      });
    }

    test('without a verifier an IDENT is ignored', () async {
      final (a, b) = identityPair();
      await a.identify(await bearer());
      expect(b.peerIdentity, isNull);
      expect(b.isOpen, isTrue);
      // A NONCE is still answered: both sides have one.
      await b.identify(await bearer(identity: 'other'));
      await a.close();
      await b.done;
    });

    test('no NONCE from the peer within the timeout', () async {
      final (a, raw) = rawPair(
        options: rawOptions.copyWith(
          identityTimeout: const Duration(milliseconds: 50),
        ),
      );
      await expectLater(
        a.identify(await bearer()),
        throwsStatus(StatusCode.deadlineExceeded),
      );
      expect(isControl(await raw.next(), MuxControlType.nonce), isTrue);
      await a.close();

      // An explicit timeout wins over the option.
      final (b, _) = rawPair(
        options: rawOptions.copyWith(
          identityTimeout: const Duration(seconds: 20),
        ),
      );
      final watch = Stopwatch()..start();
      await expectLater(
        b.identify(await bearer(), timeout: const Duration(milliseconds: 20)),
        throwsStatus(StatusCode.deadlineExceeded),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      await b.close();
    });

    test('no confirmation within the timeout', () async {
      final (a, raw) = rawPair(
        options: rawOptions.copyWith(
          identityTimeout: const Duration(milliseconds: 100),
        ),
      );
      final identifying = expectLater(
        a.identify(await bearer()),
        throwsStatus(StatusCode.deadlineExceeded),
      );
      await raw.nextControl(MuxControlType.nonce);
      raw.send(control(MuxControlType.nonce, Uint8List(32)));
      await raw.nextControl(MuxControlType.ident);
      await raw.nextControl(MuxControlType.ping);
      await identifying;
      await a.close();
    });

    test('the connection ending fails identify with its status', () async {
      final (a, raw) = rawPair();
      final identifying = expectLater(
        a.identify(await bearer()),
        throwsStatus(StatusCode.connectionLost),
      );
      await raw.nextControl(MuxControlType.nonce);
      await raw.transport.sink.close();
      await identifying;
      await expectLater(
        a.identify(await bearer()),
        throwsStatus(StatusCode.failedPrecondition),
      );
    });

    test('argument checks', () async {
      final (a, b) = identityPair();
      final credential = await held();
      expect(() => a.identify(credential), throwsArgumentError);
      expect(
        () async =>
            a.identify(credential, holderKey: await HolderKey.generate()),
        throwsArgumentError,
      );
      expect(
        () async => a.identify(await bearer(), intent: Uint8List(65)),
        throwsArgumentError,
      );
      await a.close();
      await b.done;
    });

    group('protocol errors', () {
      Future<void> expectProtocolError(List<String> frames) async {
        final verifier = await verifierFor([hmacIssuer]);
        final (b, raw) = rawPair(
          muxIsInitiator: false,
          options: rawOptions.copyWith(identityVerifier: verifier),
        );
        frames.forEach(raw.send);
        final goAway = await raw.nextControl(MuxControlType.goAway);
        expect(goAway.goAwayStatus, hasCode(StatusCode.protocolError));
        expect(await b.done, hasCode(StatusCode.protocolError));
      }

      test('NONCE of 31 bytes', () async {
        await expectProtocolError([
          control(MuxControlType.nonce, Uint8List(31)),
        ]);
      });

      test('a second NONCE', () async {
        await expectProtocolError([
          control(MuxControlType.nonce, Uint8List(32)),
          control(MuxControlType.nonce, Uint8List(32)),
        ]);
      });

      test('IDENT before the nonces', () async {
        await expectProtocolError([
          control(
            MuxControlType.ident,
            MuxIdent(credential: (await bearer()).encode()).encode(),
          ),
        ]);
      });

      test('a truncated IDENT', () async {
        await expectProtocolError([
          control(MuxControlType.nonce, Uint8List(32)),
          control(MuxControlType.ident, hexBytes('05 00 01 02')),
        ]);
      });
    });
  });
}
