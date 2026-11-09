import Foundation

/// Pure logic for the layer indicator, fed by the layer status GATT service
/// of a ZMK firmware built with the `layer_status_gatt` module.
///
/// The firmware reports the full set of active layers (not only the top one),
/// so a toggled layer stays visible underneath momentary ones held over it.
enum LayerIndicator {
  /// Active-layer bitmask: uint32 little-endian, bit i = layer at index i.
  static func parseActiveMask(from data: Data?) -> UInt32? {
    guard let data, data.count >= 4 else { return nil }
    return data.prefix(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
  }

  /// Layer names in index order, '\n'-separated. Unnamed layers become
  /// "Layer N" so every layer has a stable, non-empty key for its label.
  static func parseNames(from data: Data?) -> [String] {
    guard let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
      .map { i, name in name.isEmpty ? "Layer \(i)" : String(name) }
  }

  /// The label of the highest active layer that has one, or nil.
  /// `labels` is keyed by layer name (see `KeyboardDevice.layerLabels`).
  static func label(activeMask: UInt32?, names: [String], labels: [String: String]) -> String? {
    guard let activeMask else { return nil }
    for i in names.indices.reversed() where i < 32 && activeMask & (1 << i) != 0 {
      if let label = labels[names[i]], !label.isEmpty { return label }
    }
    return nil
  }
}
