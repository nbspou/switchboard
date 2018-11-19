# WSTalk

Library providing a natural interface to asynchronous network messaging by implementing a message chain protocol on top of WebSocket.

TalkMessage responses themselves can also be requests, which differs from plain RPC protocols, in that it allows back-and-forth message chains between server and client without having to manually track conversation states. Additionally, requests can also be made for streams, which allows for efficient list queries to be easily implemented. Stream responses can recursively be requests in themselves, and so forth.

# Frames

The base connection is any framed messaging protocol. The current target is WebSockets since it's ubiquitously available everywhere.

# Channels

The message frame connection is multiplexed into channels for arbitrary usage. Both sides of the connection can arbitrarily open new channels. When opening a channel, an arbitrary payload blob is included for the application to interpret and process. The payload can be used for authentication, identification, and addressing purposes.

These multiplexed channels are effectively a framed messaging protocol, and technically can be recursively multiplexed into more channels.

An entire channel can be transparantly proxied to another host without parsing it's contents.

# Message Chain

The message chain protocol is defined to run on top of any framed messaging protocol. This is similar to an RPC protocol, but rather than being purely request-response, each message can be a response to a previous message, and multiple messages can be sent as a response to form a streamed response. The message chain can recursively respond with streams to individual stream responses, and so on.

An entire message chain starting from any message can be transparantly proxied to another host without parsing it's contents.

## Usage

```
import 'dart:io';
import 'package:wstalk/wstalk.dart';

runServer() async {
  HttpServer server = await HttpServer.bind('127.0.0.1', 9090);
  await for (HttpRequest request in server) {
    if (request.uri.path == '/ws') {
      // Upgrade to WSTalk socket
      WebSocket ws = await WebSocketTransformer.upgrade(request);
      TalkSocket ts = new TalkSocket(ws);
      // Register incoming message types
      ts.stream(42).listen((TalkMessage) {
        ts.close();
        server.close();
      });
      // Listen
      ts.listen();
    } else {
      // ...
    }
  }
  print("Server exited");
}

runClient() async {
  TalkSocket ts = await TalkSocket.connect("ws://localhost:9090/ws");
  testClient(ts);
  await ts.listen();
  print("Client exited");
}

testClient(TalkSocket ts) async {
  // Ping three times
  for (int i = 0; i < 3; ++i) {
    print(await ts.ping());
  }
  // Multi-ping three times
  for (int i = 0; i < 3; ++i) {
    // Receive four responses for each
    await for (int dt in ts.multiPing()) {
      print(dt);
    }
  }
  // Tell the server to close
  ts.sendMessage(42, new List<int>());
}

main() {
  runServer();
  runClient(); 
}
```
