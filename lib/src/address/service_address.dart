/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import '../name.dart';

/// Largest valid instance id (`u48`).
const int maxInstance = 0xFFFFFFFFFFFF;

/// A service address: a `(type, instance)` pair.
///
/// Instance 0 means "any instance". Non-zero instances are unique across
/// the mesh. The text form is `type/instance` with the instance in lowercase
/// hexadecimal without leading zeros (`npc/1a2b`), or just `type` when the
/// instance is 0. The text form is never sent on the wire.
class ServiceAddress {
  /// Creates an address. Throws [RangeError] if [instance] is outside
  /// 0 to 0xFFFFFFFFFFFF.
  ServiceAddress(this.type, [this.instance = 0]) {
    if (instance < 0 || instance > maxInstance) {
      throw RangeError.range(instance, 0, maxInstance, 'instance');
    }
  }

  /// Service type.
  final Name type;

  /// Instance id (`u48`), 0 for any instance.
  final int instance;

  /// True when the instance is 0, meaning any instance.
  bool get isAny => instance == 0;

  /// Parses `type`, `type/0` or `type/<hex>`.
  ///
  /// Throws [FormatException] for an empty or invalid type, a non-hex or
  /// over-long instance, or an instance out of range.
  static ServiceAddress parse(String text) {
    final slash = text.indexOf('/');
    final typeText = slash < 0 ? text : text.substring(0, slash);
    if (typeText.isEmpty) {
      throw FormatException('empty service type', text);
    }
    final Name type;
    try {
      type = Name(typeText);
    } on ArgumentError catch (e) {
      throw FormatException('invalid service type: ${e.message}', text);
    }
    if (slash < 0) {
      return ServiceAddress(type);
    }
    final hex = text.substring(slash + 1);
    if (!RegExp(r'^[0-9a-fA-F]{1,12}$').hasMatch(hex)) {
      throw FormatException('invalid instance (1 to 12 hex digits)', text);
    }
    return ServiceAddress(type, int.parse(hex, radix: 16));
  }

  @override
  bool operator ==(Object other) =>
      other is ServiceAddress &&
      other.type == type &&
      other.instance == instance;

  @override
  int get hashCode => Object.hash(type, instance);

  @override
  String toString() =>
      isAny ? type.toString() : '$type/${instance.toRadixString(16)}';
}
