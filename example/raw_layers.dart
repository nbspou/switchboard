// The lower layers alone: mux and Talk over an in-memory transport.
import 'dart:convert';
import 'dart:typed_data';

import 'package:switchboard/core.dart';

Future<void> main() async {
  // Two connected transports. Any StreamChannel<Uint8List> carrying one
  // mux frame per event works the same way.
  final (left, right) = MemoryTransport.pair();
  final initiator = MuxConnection(left, isInitiator: true);
  final acceptor = MuxConnection(right, isInitiator: false);

  // The acceptor answers Talk requests on every channel the peer opens.
  acceptor.incoming.listen((channel) {
    final address = ChannelAddress.decode(channel.openPayload);
    print('acceptor: channel ${channel.id} opened for ${address.address}');
    TalkChannel(channel).messages.listen((message) {
      if (message.expectsReply) {
        message.reply(utf8.encode('pong'));
      }
    });
  });

  // The mux does not interpret the OPEN payload; this one is an address
  // header, as a Switchboard node would send.
  final channel = initiator.open(ChannelAddress(type: Name('demo')).encode());
  final talk = TalkChannel(channel);
  final reply = await talk.request('PING', Uint8List(0));
  print('initiator: PING -> ${utf8.decode(reply.payload)}');
  print('initiator: mux round trip ${await initiator.ping()}');

  await talk.close();
  await initiator.goAway();
  print('acceptor: connection ended with ${await acceptor.done}');
}
