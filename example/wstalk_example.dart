
import 'dart:io';
import 'package:wstalk/wstalk.dart';
/*
runServer() async {
  try {
    HttpServer server = await HttpServer.bind('127.0.0.1', 9090);
    try {
      await for (HttpRequest request in server) {
        try {
          if (request.uri.path == '/ws') {
            WebSocket ws = await WebSocketTransformer.upgrade(request);
            TalkSocket ts = new TalkSocket(ws);
            ts.stream(42).listen((TalkMessage) {
              ts.close();
              server.close();
            });
            () async { try {
              await ts.listen();
            } catch (ex) {
              print("Server socket listen exception:");
              print(ex);
            } }();
          } else {
            // ...
          }
        } catch (ex) {
          print("Request handling exception:");
          print(ex);
        }
      }
    } catch (ex) {
      print("Server listen exception:");
      print(ex);
    }
  } catch (ex) {
    print("Server bind exception:");
    print(ex);
  }
  print("Server exited");
}

runClient() async {
  try {
    TalkSocket ts = await TalkSocket.connect("ws://localhost:9090/ws");
    try {
      testClient(ts);
    } catch (ex) {
      print("Client test exception (should not occur):");
      print(ex);
    }
    try {
      await ts.listen();
    } catch (ex) {
      print("Client listen exception:");
      print(ex);
    }
  } catch (ex) {
    print("Client connect exception:");
    print(ex);
  }
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
*/
main() {
  /*
  runServer();
  runClient();
  */
}
