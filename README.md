# Switchboard

Microservice communication protocol. 

## Frames

The base connection is any framed messaging protocol. The current WSTalk2 protocol target is WebSockets since it's ubiquitously available everywhere.

## Channels

The message frame connection is multiplexed into channels for arbitrary usage. Both sides of the connection can arbitrarily open new channels. When opening a channel, an arbitrary payload blob is included for the application to interpret and process. The payload can be used for authentication, identification, and addressing purposes.

These multiplexed channels are effectively a framed messaging protocol, and technically can be recursively multiplexed into more channels.

An entire channel can be transparantly proxied to another host without parsing it's contents.

## Message Chain

The message chain protocol is defined to run on top of any framed messaging protocol. This is similar to an RPC protocol, but rather than being purely request-response, each message can be a response to a previous message, and multiple messages can be sent as a response to form a streamed response. The message chain can recursively respond with streams to individual stream responses, and so on.

An entire message chain starting from any message can be transparantly proxied to another host without parsing it's contents.

## Usage

```

```

## Future Plans

Redesign to target both QUIC and WebSockets as primary transport layers.
