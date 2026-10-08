/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// Connections a node makes to its own listeners (Switchboard
// localConnections): an in-process memory pair instead of a socket, accepted
// as the designated listener accepts a connection (its policy, dispatch,
// `connections`, GOAWAY on close) and otherwise established like any
// initiated connection (pool, outgoing policy, identity, credentialFor,
// flow control), over tcp, ws and mem listeners; and the socket path with
// localConnections false.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const fast = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);
const limit = Duration(seconds: 5);

final svc = Name('svc');
final other = Name('other');
final back = Name('back');

final meshKey = Uint8List.fromList(List.generate(32, (i) => 7 * i + 3));

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

Matcher hasCode(StatusCode code) =>
    isA<Status>().having((s) => s.known, 'code', code);

Matcher throwsCode(StatusCode code) =>
    throwsA(isA<SwitchboardException>().having((e) => e.code, 'code', code));

Future<void> until(bool Function() condition, [String? what]) async {
  final deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('${what ?? 'condition'} not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// A node closed after the test.
Switchboard node({
  Resolver? resolver,
  bool localConnections = true,
  ChannelPolicy? outgoingPolicy,
  EndpointPolicy? endpointPolicy,
  EndpointCredential? credentialFor,
}) {
  final s = Switchboard(
    resolver: resolver,
    muxOptions: fast,
    localConnections: localConnections,
    outgoingPolicy: outgoingPolicy,
    endpointPolicy: endpointPolicy,
    credentialFor: credentialFor,
  );
  addTearDown(s.close);
  return s;
}

/// A listener of [scheme] on [node].
Future<Uri> listen(Switchboard node, String scheme, {ChannelPolicy? policy}) =>
    switch (scheme) {
      'tcp' => node.listenTcp(InternetAddress.loopbackIPv4, 0, policy: policy),
      'ws' => node.listenWebSocket(
        '127.0.0.1',
        0,
        path: '/mesh',
        policy: policy,
      ),
      _ => node.listenMemory(policy: policy),
    };

/// A handler that sends [tag] and closes.
ChannelHandler tagged(String tag) => (incoming) {
  incoming.channel.send(bytes(tag));
  unawaited(incoming.channel.close());
};

/// Reads the tag sent by a [tagged] handler, or the close status.
Future<String> tagOf(MuxChannel channel) async {
  final frames = await channel.stream.toList().timeout(limit);
  final status = await channel.done.timeout(limit);
  if (frames.isEmpty) {
    return 'closed ${status.known?.name ?? status.code}';
  }
  return utf8.decode(frames.single);
}

/// A handler recording every channel it gets in [seen], then like
/// [tagged].
ChannelHandler recording(List<IncomingChannel> seen, String tag) => (incoming) {
  seen.add(incoming);
  return tagged(tag)(incoming);
};

void main() {
  for (final scheme in ['tcp', 'ws', 'mem']) {
    group('to its own $scheme listener', () {
      test('a node opens a channel to a service it hosts in-process; '
          'connections reports both ends', () async {
        final n = node();
        final uri = await listen(n, scheme);
        final reported = <MuxConnection>[];
        n.connections.listen(reported.add);
        final seen = <IncomingChannel>[];
        n.registerService(svc, recording(seen, 'hello'));

        final channel = await n.openChannelAt(uri, ChannelAddress(type: svc));
        expect(await tagOf(channel), 'hello');
        final incoming = seen.single;
        expect(incoming.remote, 'local');
        expect(incoming.connection.isInitiator, isFalse);
        expect(channel.connection.isInitiator, isTrue);
        expect(incoming.connection, isNot(same(channel.connection)));
        await until(() => reported.length == 2, 'both ends reported');
        expect(
          reported,
          unorderedEquals([incoming.connection, channel.connection]),
        );
        expect(n.isOwnEndpoint(uri), isTrue);
      });

      test('the listener policy applies', () async {
        final n = node();
        final uri = await listen(
          n,
          scheme,
          policy: ChannelPolicies.allowTypes({svc}),
        );
        n.registerService(svc, tagged('svc'));
        n.registerService(other, tagged('other'));
        expect(
          await tagOf(await n.openChannelAt(uri, ChannelAddress(type: svc))),
          'svc',
        );
        expect(
          await tagOf(await n.openChannelAt(uri, ChannelAddress(type: other))),
          'closed permissionDenied',
        );
      });

      test('a denying listener policy refuses the channel', () async {
        final n = node();
        final uri = await listen(n, scheme, policy: ChannelPolicies.denyAll);
        final seen = <IncomingChannel>[];
        n.registerService(svc, recording(seen, 'svc'));
        final channel = await n.openChannelAt(uri, ChannelAddress(type: svc));
        expect(await tagOf(channel), 'closed permissionDenied');
        expect(seen, isEmpty);
      });

      test('the pool reuses the pair; close ends both ends', () async {
        final n = node();
        final uri = await listen(n, scheme);
        final reported = <MuxConnection>[];
        n.connections.listen(reported.add);
        final held = <IncomingChannel>[];
        n.registerService(svc, held.add);

        final connection = await n.connect(uri);
        expect(await n.connect(uri), same(connection));
        final first = await n.openChannelAt(uri, ChannelAddress(type: svc));
        final second = await n.openChannelAt(uri, ChannelAddress(type: svc));
        expect(first.connection, same(connection));
        expect(second.connection, same(connection));
        await until(() => held.length == 2, 'both channels arrived');
        final accepted = held.first.connection;
        expect(held.last.connection, same(accepted));
        await Future<void>.delayed(Duration.zero);
        expect(reported, hasLength(2));

        await n.close();
        expect(await connection.done.timeout(limit), isA<Status>());
        expect(await accepted.done.timeout(limit), isA<Status>());
        expect(connection.isOpen, isFalse);
        expect(accepted.isOpen, isFalse);
        expect(await first.done.timeout(limit), isA<Status>());
        // The listener stopped: no longer this node's, and nothing is
        // dialled.
        expect(n.isOwnEndpoint(uri), isFalse);
        await expectLater(
          n.connect(uri),
          throwsCode(StatusCode.failedPrecondition),
        );
      });

      test('a connection to itself ending ends the other side', () async {
        final n = node();
        final uri = await listen(n, scheme);
        final held = <IncomingChannel>[];
        n.registerService(svc, held.add);
        final channel = await n.openChannelAt(uri, ChannelAddress(type: svc));
        await until(() => held.isNotEmpty, 'the channel arrived');
        final accepted = held.single.connection;
        unawaited(channel.connection.goAway());
        expect(await accepted.done.timeout(limit), isA<Status>());
        expect(await channel.connection.done.timeout(limit), isA<Status>());
        // The pool replaces it with a new pair.
        final again = await n.openChannelAt(uri, ChannelAddress(type: svc));
        expect(again.connection, isNot(same(channel.connection)));
        await until(() => held.length == 2, 'the second channel arrived');
        expect(held.last.remote, 'local');
      });

      test('dial gives a new in-process connection each time', () async {
        final n = node();
        final uri = await listen(n, scheme);
        final seen = <IncomingChannel>[];
        n.registerService(svc, recording(seen, 'svc'));
        final one = await n.dial(uri);
        final two = await n.dial(uri);
        expect(two, isNot(same(one)));
        expect(await n.connect(uri), isNot(anyOf(same(one), same(two))));
        for (final connection in [one, two]) {
          expect(
            await tagOf(n.openChannelOn(connection, ChannelAddress(type: svc))),
            'svc',
          );
        }
        expect(seen.map((s) => s.remote), ['local', 'local']);
        expect(seen.first.connection, isNot(same(seen.last.connection)));
        await one.goAway();
        await two.goAway();
      });

      test('with localConnections false, a socket as before', () async {
        final n = node(localConnections: false);
        final uri = await listen(n, scheme);
        final seen = <IncomingChannel>[];
        n.registerService(svc, recording(seen, 'svc'));
        final channel = await n.openChannelAt(uri, ChannelAddress(type: svc));
        expect(await tagOf(channel), 'svc');
        expect(n.isOwnEndpoint(uri), isTrue);
        final remote = seen.single.remote;
        if (scheme == 'mem') {
          // Through the isolate's registry: the remote names the
          // initiator's mem endpoint.
          expect(remote, uri.toString());
        } else {
          expect(remote, startsWith('127.0.0.1:'));
        }
      });
    });
  }

  test('the listener the endpoint designates is the one whose policy '
      'applies', () async {
    final n = node();
    final tcp = await n.listenTcp(
      InternetAddress.loopbackIPv4,
      0,
      policy: ChannelPolicies.denyAll,
    );
    final ws = await n.listenWebSocket('127.0.0.1', 0);
    n.registerService(svc, tagged('svc'));
    expect(
      await tagOf(await n.openChannelAt(tcp, ChannelAddress(type: svc))),
      'closed permissionDenied',
    );
    expect(
      await tagOf(await n.openChannelAt(ws, ChannelAddress(type: svc))),
      'svc',
    );
    // Another spelling of the TCP listener: its own pooled connection,
    // in-process too, under the same listener policy.
    final localhost = Uri.parse('tcp://localhost:${tcp.port}');
    expect(n.isOwnEndpoint(localhost), isTrue);
    final spelled = await n.openChannelAt(localhost, ChannelAddress(type: svc));
    expect(await tagOf(spelled), 'closed permissionDenied');
    expect(spelled.connection, isNot(same(await n.connect(tcp))));
  });

  test('the initiated side has the outgoing policy', () async {
    final n = node(outgoingPolicy: ChannelPolicies.denyAll);
    final uri = await listen(n, 'tcp');
    n.registerService(back, tagged('back'));
    final answered = Completer<String>();
    n.registerService(svc, (incoming) {
      // Symmetric dispatch: a channel back on the accepted side reaches
      // the initiated side, under its policy.
      final channel = incoming.connection.open(
        ChannelAddress(type: back).encode(),
      );
      answered.complete(tagOf(channel));
      unawaited(incoming.channel.close());
    });
    await n.openChannelAt(uri, ChannelAddress(type: svc));
    expect(await answered.future.timeout(limit), 'closed permissionDenied');
    // The accepted side has the listener's policy (none): the same channel
    // the other way is admitted.
    final channel = await n.openChannelAt(uri, ChannelAddress(type: back));
    expect(await tagOf(channel), 'back');
  });

  test('endpointPolicy and credentialFor are asked about the endpoint as '
      'given', () async {
    final asked = <Uri>[];
    final n = node(
      endpointPolicy: (endpoint) {
        asked.add(endpoint);
        return null;
      },
      credentialFor: (endpoint, record) => bytes('for $endpoint'),
    );
    final uri = await listen(n, 'tcp');
    final payloads = <String>[];
    n.registerService(svc, (incoming) {
      payloads.add(utf8.decode(incoming.address.payload));
      unawaited(incoming.channel.close());
    });
    final localhost = Uri.parse('tcp://LOCALHOST:${uri.port}');
    await (await n.openChannelAt(
      localhost,
      ChannelAddress(type: svc),
    )).done.timeout(limit);
    expect(asked, [Uri.parse('tcp://localhost:${uri.port}')]);
    expect(payloads.single, 'for $localhost');
  });

  group('identity', () {
    late CredentialIssuer issuer;
    late CredentialVerifier verifier;
    late Credential credential;

    setUpAll(() async {
      issuer = CredentialIssuer.hmac(Name('mesh1'), meshKey);
      verifier = CredentialVerifier();
      await verifier.addIssuer(issuer);
      credential = await issuer.issue(
        kind: CredentialKind.node,
        identity: 'hub',
        scopes: [Scope.of(Right.open, 'svc')],
      );
    });

    Switchboard identified({
      bool identifyOutgoing = true,
      Duration identityTimeout = limit,
    }) {
      final s = Switchboard(
        muxOptions: fast.copyWith(requireNamedIdent: true),
        credential: credential,
        verifier: verifier,
        identifyOutgoing: identifyOutgoing,
        identityTimeout: identityTimeout,
        expectedIdentityFor: (endpoint, record) => 'hub',
      );
      addTearDown(s.close);
      return s;
    }

    for (final scheme in ['tcp', 'ws']) {
      test('the node identifies to itself; a scoped listener admits what '
          'its credential allows ($scheme)', () async {
        final n = identified();
        final uri = await listen(n, scheme, policy: ChannelPolicies.scoped());
        final seen = <IncomingChannel>[];
        n.registerService(svc, recording(seen, 'svc'));
        n.registerService(other, recording(seen, 'other'));
        final channel = await n.openChannelAt(uri, ChannelAddress(type: svc));
        expect(await tagOf(channel), 'svc');
        final incoming = seen.single;
        expect(incoming.remote, 'local');
        expect(incoming.peerIdentity?.identity, 'hub');
        expect(incoming.peerIdentity?.receiver, 'hub');
        expect(channel.connection.localIdentity, 'hub');
        expect(
          await tagOf(await n.openChannelAt(uri, ChannelAddress(type: other))),
          'closed permissionDenied',
        );
        expect(seen, hasLength(1));
      });
    }

    test('without identifyOutgoing, a scoped listener refuses the node '
        'once the identity wait is over', () async {
      final n = identified(
        identifyOutgoing: false,
        identityTimeout: const Duration(milliseconds: 100),
      );
      final uri = await listen(n, 'tcp', policy: ChannelPolicies.scoped());
      n.registerService(svc, tagged('svc'));
      final channel = await n.openChannelAt(uri, ChannelAddress(type: svc));
      expect(await tagOf(channel), 'closed unauthenticated');
      expect(channel.connection.peerIdentity, isNull);
    });
  });

  test('a large bulk payload to itself, both ways, under flow '
      'control', () async {
    final n = node();
    final uri = await listen(n, 'tcp');
    n.registerService(svc, (incoming) {
      incoming.talk().messages.listen((message) {
        expect(message.isBulk, isTrue);
        message.reply(message.payload);
      });
    });
    final talk = await n.openTalkAt(uri, ChannelAddress(type: svc));
    final payload = Uint8List(3 * 1024 * 1024 + 17);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = (i * 31 + (i >> 11)) & 0xFF;
    }
    final reply = await talk
        .request('ECHO', payload)
        .timeout(const Duration(seconds: 20));
    expect(reply.isBulk, isTrue);
    final echoed = reply.payload;
    expect(echoed.length, payload.length);
    var same = true;
    for (var i = 0; same && i < payload.length; i++) {
      same = echoed[i] == payload[i];
    }
    expect(same, isTrue, reason: 'the echo differs');
    await talk.close();
  });

  test('a PeerSet over its own instance comes online in-process', () async {
    final table = StaticResolver();
    addTearDown(table.close);
    final n = node(resolver: table);
    final uri = await listen(n, 'tcp');
    final seen = <IncomingChannel>[];
    n.registerService(svc, (incoming) {
      seen.add(incoming);
      incoming.talk().messages.listen((message) {
        if (message.expectsReply) {
          message.reply(bytes('pong'));
        }
      });
    }, instance: 1);
    table.add(ServiceRecord(ServiceAddress(svc, 1), endpoints: [uri]));
    final set = PeerSet.watch(
      n,
      svc,
      channel: ChannelAddress(type: svc),
      policy: ChannelPolicies.denyAll,
    );
    addTearDown(set.close);
    await until(() => set.online.isNotEmpty, 'the peer online');
    final peer = set.peers[1]!;
    expect(peer.endpoint, uri);
    expect(seen.single.remote, 'local');
    expect(seen.single.address.address, ServiceAddress(svc, 1));
    // The set's connection is its own, not the pooled one.
    expect(peer.connection, isNot(same(await n.connect(uri))));
    final talk = await set.openTalk(1);
    expect(
      utf8.decode((await talk.request('PING', Uint8List(0))).payload),
      'pong',
    );
    await talk.close();
  });

  test('the proxy still refuses to forward to its own listener', () async {
    final table = StaticResolver();
    addTearDown(table.close);
    final proxyNode = node(resolver: table);
    final hits = <IncomingChannel>[];
    proxyNode.registerService(svc, recording(hits, 'direct'), instance: 1);
    final proxy = proxyHandler(proxyNode);
    proxyNode.catchAll = proxy;
    final uri = await listen(proxyNode, 'tcp');
    // A record of `other` pointing back at the proxy itself.
    table.add(ServiceRecord(ServiceAddress(other, 1), endpoints: [uri]));
    final client = node();
    final channel = await client.openChannelAt(
      uri,
      ChannelAddress(type: other),
    );
    expect(await tagOf(channel), 'closed unavailable');
    expect(hits, isEmpty);
  });

  test('an endpoint of a port the node does not listen on is dialled as '
      'usual', () async {
    final n = node();
    await listen(n, 'tcp');
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    final elsewhere = Uri.parse('tcp://127.0.0.1:$port');
    expect(n.isOwnEndpoint(elsewhere), isFalse);
    await expectLater(n.connect(elsewhere), throwsCode(StatusCode.unavailable));
  });
}
