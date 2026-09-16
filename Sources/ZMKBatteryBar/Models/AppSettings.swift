import Foundation

/// What each row of the menu bar item shows.
enum StatusBarDisplayMode: String, CaseIterable {
  case icon
  case both
  case percentage

  var showsIcon: Bool { self != .percentage }
  var showsPercentage: Bool { self != .icon }
}

final class AppSettings {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  private enum Keys {
    static let selectedKeyboardUUID = "selectedKeyboardUUID"
    static let savedKeyboards = "savedKeyboards"
    static let showBatteryIcon = "showBatteryIcon"
    static let swapBatteryIconPositions = "swapBatteryIconPositions"
    static let singleLineLayout = "singleLineLayout"
    static let statusBarDisplayMode = "statusBarDisplayMode"
  }

  /// What the menu bar rows show: icon only, icon + percentage, or percentage
  /// only. Defaults to `.both`. Migrates the legacy `showBatteryIcon == false`
  /// setting to `.percentage`.
  var statusBarDisplayMode: StatusBarDisplayMode {
    get {
      if let raw = defaults.string(forKey: Keys.statusBarDisplayMode),
         let mode = StatusBarDisplayMode(rawValue: raw) {
        return mode
      }
      if defaults.object(forKey: Keys.showBatteryIcon) != nil,
         defaults.bool(forKey: Keys.showBatteryIcon) == false {
        return .percentage
      }
      return .both
    }
    set { defaults.set(newValue.rawValue, forKey: Keys.statusBarDisplayMode) }
  }

  /// Whether the Central/Peripheral rows are swapped (reordered) in the menu
  /// bar icon. Affects the icon only; the popover order and the label-to-data
  /// mapping (including L/R labels) are unchanged. Defaults to false.
  var swapBatteryIconPositions: Bool {
    get { defaults.bool(forKey: Keys.swapBatteryIconPositions) }
    set { defaults.set(newValue, forKey: Keys.swapBatteryIconPositions) }
  }

  /// Whether the menu bar icon shows both battery rows on a single line
  /// (e.g. "C50% P50%") instead of stacked on two lines. The slightly larger
  /// label font and taller battery icon are applied only in this mode. Battery
  /// position swapping and icon hiding still apply. Defaults to false.
  var singleLineLayout: Bool {
    get { defaults.bool(forKey: Keys.singleLineLayout) }
    set { defaults.set(newValue, forKey: Keys.singleLineLayout) }
  }

  var selectedKeyboardUUID: String? {
    get { defaults.string(forKey: Keys.selectedKeyboardUUID) }
    set { defaults.set(newValue, forKey: Keys.selectedKeyboardUUID) }
  }

  var savedKeyboards: [KeyboardDevice] {
    get {
      guard let data = defaults.data(forKey: Keys.savedKeyboards),
            let devices = try? JSONDecoder().decode([KeyboardDevice].self, from: data)
      else { return [] }
      return devices
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        defaults.set(data, forKey: Keys.savedKeyboards)
      }
    }
  }

  var selectedKeyboard: KeyboardDevice? {
    guard let uuid = selectedKeyboardUUID else { return nil }
    return savedKeyboards.first { $0.uuid == uuid }
  }

  func addKeyboard(uuid: String, name: String) {
    var keyboards = savedKeyboards
    if !keyboards.contains(where: { $0.uuid == uuid }) {
      keyboards.append(KeyboardDevice(uuid: uuid, name: name))
      savedKeyboards = keyboards
    }
  }

  func updateKeyboard(uuid: String, mutate: (inout KeyboardDevice) -> Void) {
    var keyboards = savedKeyboards
    guard let idx = keyboards.firstIndex(where: { $0.uuid == uuid }) else { return }
    mutate(&keyboards[idx])
    savedKeyboards = keyboards
  }

  func removeKeyboard(uuid: String) {
    var keyboards = savedKeyboards
    keyboards.removeAll { $0.uuid == uuid }
    savedKeyboards = keyboards

    if selectedKeyboardUUID == uuid {
      selectedKeyboardUUID = nil
    }
  }
}
