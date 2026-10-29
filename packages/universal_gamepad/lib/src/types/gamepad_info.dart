/// Information about a connected gamepad.
class GamepadInfo {
  const GamepadInfo({
    required this.id,
    required this.name,
    this.vendorId,
    this.productId,
  });

  /// Unique identifier for this gamepad within the current session.
  final int id;

  /// Human-readable name of the gamepad (e.g. "Xbox Wireless Controller").
  final String name;

  /// USB vendor ID, if available.
  final int? vendorId;

  /// USB product ID, if available.
  final int? productId;

  factory GamepadInfo.fromMap(Map<String, dynamic> map) {
    return GamepadInfo(
      id: map['id'] as int,
      name: map['name'] as String,
      vendorId: map['vendorId'] as int?,
      productId: map['productId'] as int?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      if (vendorId != null) 'vendorId': vendorId,
      if (productId != null) 'productId': productId,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GamepadInfo &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          vendorId == other.vendorId &&
          productId == other.productId;

  @override
  int get hashCode => Object.hash(id, name, vendorId, productId);

  @override
  String toString() =>
      'GamepadInfo(id: $id, name: $name, vendorId: $vendorId, productId: $productId)';
}
