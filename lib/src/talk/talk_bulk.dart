/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

/// The wire structures of Talk bulk payloads (wiki page "Polyverse
/// Switchboard Talk", section "Bulk payloads"): the reference a `BULK`
/// message carries, and the open payload of a `_bulk` channel.
library;

import 'dart:typed_data';

import '../address/channel_address.dart';
import '../bytes.dart';
import '../name.dart';
import '../status.dart';

/// The payload field of a Talk message with the `BULK` flag
/// ([TalkFrame.bulk]): which bulk channel carries the payload, and how
/// long it is.
///
/// ```
/// u32   bulk number   among the bulk channels the sender opened for the
///                     message's channel, from 1
/// u48   length        payload bytes to expect; 0xFFFFFFFFFFFF unknown
/// ```
class TalkBulkReference {
  /// A reference to bulk channel [number] carrying [length] bytes (null:
  /// not known in advance).
  ///
  /// Throws [RangeError] for a [number] outside 1 to [maxNumber] or a
  /// [length] outside 0 to [maxLength].
  TalkBulkReference(this.number, {this.length}) {
    RangeError.checkValueInInterval(number, 1, maxNumber, 'number');
    final length = this.length;
    if (length != null) {
      RangeError.checkValueInInterval(length, 0, maxLength, 'length');
    }
  }

  /// Bytes of an encoded reference: the whole payload field of a `BULK`
  /// message. Any other length is a channel protocol error.
  static const int encodedLength = 10;

  /// The length field meaning "not known in advance".
  static const int unknownLength = 0xFFFFFFFFFFFF;

  /// The largest declared length.
  static const int maxLength = unknownLength - 1;

  /// The largest bulk number (`u32`).
  static const int maxNumber = 0xFFFFFFFF;

  /// The number of the bulk channel among those the sender opened for the
  /// channel the message travels on, from 1.
  final int number;

  /// The payload length in bytes, or null when the sender did not know it.
  final int? length;

  /// The 10 bytes of the payload field.
  Uint8List encode() {
    final w = ByteWriter(encodedLength)
      ..u32(number)
      ..u48(length ?? unknownLength);
    return w.toBytes();
  }

  /// Decodes the payload field of a `BULK` message. Throws
  /// [ProtocolException] unless it is exactly [encodedLength] bytes with a
  /// bulk number of at least 1.
  static TalkBulkReference decode(Uint8List payload) {
    if (payload.length != encodedLength) {
      throw ProtocolException('bulk reference of ${payload.length} bytes');
    }
    final r = ByteReader(payload);
    final number = r.u32('bulk number');
    final length = r.u48('bulk length');
    if (number == 0) {
      throw ProtocolException('bulk number 0');
    }
    return TalkBulkReference(
      number,
      length: length == unknownLength ? null : length,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TalkBulkReference &&
      other.number == number &&
      other.length == length;

  @override
  int get hashCode => Object.hash(number, length);

  @override
  String toString() =>
      'TalkBulkReference($number, ${length ?? 'unknown'} bytes)';
}

/// The open payload of a bulk channel: an address header of the reserved
/// type `_bulk` (instance 0, no shard), whose application payload names
/// the parent channel and the bulk number.
///
/// ```
/// u48   parent channel id   the channel the message travels on, as the
///                           receiver of the OPEN sees it (a channel has
///                           the same id at both ends of a connection)
/// u32   bulk number         the number the message's reference carries
/// ```
///
/// A receiver admits a `_bulk` channel only while its parent is open on
/// the connection the OPEN arrived on, without consulting any listener
/// policy, and hands it to the parent's Talk layer (see
/// `TalkChannel.adoptBulk`).
class TalkBulkOpen {
  /// The open payload of bulk channel [number] for the channel [parentId].
  ///
  /// Throws [RangeError] for a [parentId] outside `u48` or a [number]
  /// outside 1 to [TalkBulkReference.maxNumber].
  TalkBulkOpen(this.parentId, this.number) {
    RangeError.checkValueInInterval(parentId, 0, 0xFFFFFFFFFFFF, 'parentId');
    RangeError.checkValueInInterval(
      number,
      1,
      TalkBulkReference.maxNumber,
      'number',
    );
  }

  /// The reserved service type of bulk channels.
  static final Name type = Name('_bulk');

  /// Bytes of the application payload.
  static const int payloadLength = 10;

  /// The id of the channel whose message the bulk channel carries.
  final int parentId;

  /// The bulk number, as the message's [TalkBulkReference] carries it.
  final int number;

  /// The address header and application payload of the OPEN.
  ChannelAddress get address =>
      ChannelAddress(type: type, payload: _applicationPayload());

  /// The complete OPEN payload.
  Uint8List encode() => address.encode();

  Uint8List _applicationPayload() {
    final w = ByteWriter(payloadLength)
      ..u48(parentId)
      ..u32(number);
    return w.toBytes();
  }

  /// Whether [address] is that of a bulk channel.
  static bool isBulk(ChannelAddress address) => address.type == type;

  /// Decodes the application payload of a `_bulk` OPEN ([address] must be
  /// of [type]); bytes after the two fields are ignored. Throws
  /// [ProtocolException] when it is shorter, or names bulk number 0.
  static TalkBulkOpen decode(ChannelAddress address) {
    final payload = address.payload;
    if (payload.length < payloadLength) {
      throw ProtocolException('_bulk open payload of ${payload.length} bytes');
    }
    final r = ByteReader(payload);
    final parent = r.u48('parent channel id');
    final number = r.u32('bulk number');
    if (number == 0) {
      throw ProtocolException('bulk number 0');
    }
    return TalkBulkOpen(parent, number);
  }

  @override
  String toString() => 'TalkBulkOpen(parent $parentId, number $number)';
}
