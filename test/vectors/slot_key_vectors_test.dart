/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// The reference key-to-slot function: FNV-1a 32 of the key bytes modulo
// the slot count. Runs on the VM and, with `dart test -P node`, compiled
// to JavaScript, where the 32-bit multiplication must stay exact.

import 'package:switchboard/core.dart';
import 'package:test/test.dart';

void main() {
  test('FNV-1a 32 vectors', () {
    expect(fnv1a32([]), 0x811c9dc5);
    expect(fnv1a32('a'.codeUnits), 0xe40c292c);
    expect(fnv1a32('foobar'.codeUnits), 0xbf9cf968);
    expect(fnv1a32('user:42'.codeUnits), 0x2f6b7b82);
    expect(fnv1a32([for (var i = 0; i < 256; i++) i]), 0x90a458c5);
    // Elements are taken modulo 256.
    expect(fnv1a32([0x161]), fnv1a32('a'.codeUnits));
  });

  test('slot of a key', () {
    expect(slotForText('user:42', 65536), 0x2f6b7b82 % 65536);
    expect(slotForText('user:42', 65536), 31618);
    expect(slotForKey('foobar'.codeUnits, 1), 0);
    expect(slotForText('é', 7), slotForKey([0xc3, 0xa9], 7));
    expect(() => slotForKey([1], 0), throwsRangeError);
  });
}
