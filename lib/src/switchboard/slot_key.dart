/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:convert';

/// FNV-1a 32 of [bytes] (offset basis `0x811c9dc5`, prime `16777619`), as
/// an unsigned 32-bit value. Each element is taken modulo 256.
///
/// Exact on the web too: the multiplication by the prime is split as
/// `h * 2^24 + h * 403`, which stays within the 53 bits of a JavaScript
/// number.
int fnv1a32(List<int> bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash ^= byte & 0xFF;
    hash = (((hash << 24) & 0xFFFFFFFF) + hash * 403) & 0xFFFFFFFF;
  }
  return hash;
}

/// The reference key-to-slot function of the wiki page "Switchboard
/// Sharding": [fnv1a32] of the key bytes modulo [count]. A peer in another
/// language that hashes the same bytes the same way gets the same slot.
///
/// Throws [RangeError] unless [count] is at least 1.
int slotForKey(List<int> key, int count) {
  RangeError.checkValueInInterval(count, 1, 0xFFFFFFFF, 'count');
  return fnv1a32(key) % count;
}

/// [slotForKey] of the UTF-8 encoding of [key].
int slotForText(String key, int count) => slotForKey(utf8.encode(key), count);
