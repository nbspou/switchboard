# WSTalk

Library providing a natural interface to asynchronous network messaging by implementing a back-and-forth binary messaging protocol on top of WebSocket.

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
  // Tell the server to close
  ts.sendMessage(42, new List<int>());
}

main() {
  runServer();
  runClient(); 
}
```
