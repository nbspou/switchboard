## 3.0.0-dev.1

- Restart of the project on Dart 3.13 with a completed protocol design.
- New wire format details: control channel, status codes, cancellation,
  channel id reuse, service addressing header, naming service protocol,
  stream transport binding. Not compatible with 2.x, which was never deployed.
- Protocol specification lives in the project wiki (`switchboard/` section).

## 2.1.7

- Use `WebSocketChannel` and `StreamChannel` interfaces.

## 2.0.6

- Don't reset payload if identical.

## 2.0.5

- Fix issue reconnecting after previous error.

## 2.0.4

- Rebranding
- Rewrite from scratch with simplified interface.
- Support channels for allowing virtual services or protocols on the same host (virtual hosts, etc.)

## 1.3.3

- Can now request for streams. Stream responses can recursively be requests as well.

## 1.2.1

- Request messages can be replied to with an exception using `sendException`.
- Request message timeout can be extended through the `sendExtend` function.
- Formatted source.
- Fixed some minor issues.

## 0.9.3

- Initial version.
