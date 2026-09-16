import Foundation
import Observation

/// One logged battery reading. Only level *changes* are recorded, so a run of
/// entries is a step function: each level holds until the next entry.
struct BatteryHistoryEntry: Equatable {
  let date: Date
  let keyboard: String
  let role: String
  let level: Int
}

/// CSV encoding of the history file: `timestamp,keyboard,role,level` with an
/// ISO 8601 timestamp. Neither the keyboard UUID nor the role can contain a
/// comma, so no quoting is needed.
enum BatteryHistoryCSV {
  static let header = "timestamp,keyboard,role,level"

  private static let dateStyle = Date.ISO8601FormatStyle()

  static func encode(_ entry: BatteryHistoryEntry) -> String {
    "\(entry.date.formatted(dateStyle)),\(entry.keyboard),\(entry.role),\(entry.level)"
  }

  static func decode(_ line: String) -> BatteryHistoryEntry? {
    let parts = line.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 4,
          let date = try? dateStyle.parse(String(parts[0])),
          let level = Int(parts[3]),
          (0...100).contains(level)
    else { return nil }
    return BatteryHistoryEntry(date: date, keyboard: String(parts[1]), role: String(parts[2]), level: level)
  }
}

/// Linear runtime estimate over the current discharge cycle.
enum BatteryEstimator {
  /// A level increase of at least this many points between consecutive
  /// entries is treated as the start of a charge; readings can jitter by a
  /// point or two under load, so single-point bumps are not.
  static let chargeJump = 3
  /// Minimum observed discharge before an estimate is offered.
  static let minimumSpan: TimeInterval = 3600
  static let minimumDrop = 2

  /// Seconds until the level reaches 0 at the average discharge rate observed
  /// since the last charge, measured from `now`. `nil` when there is not
  /// enough discharge data yet. `entries` must be for one keyboard/role and
  /// sorted by date ascending.
  // ponytail: straight-line fit from the last charge; a per-segment or
  // weighted-recent model can replace this if the estimate proves too jumpy.
  static func remainingTime(entries: [BatteryHistoryEntry], now: Date) -> TimeInterval? {
    guard let last = entries.last else { return nil }
    var start = entries.count - 1
    while start > 0, entries[start].level - entries[start - 1].level < chargeJump {
      start -= 1
    }
    let first = entries[start]
    let drop = first.level - last.level
    let span = last.date.timeIntervalSince(first.date)
    guard drop >= minimumDrop, span >= minimumSpan else { return nil }
    let secondsPerPoint = span / Double(drop)
    let remaining = Double(last.level) * secondsPerPoint - now.timeIntervalSince(last.date)
    return max(remaining, 0)
  }

  /// Compact "3d 4h" / "5h" / "<1h" rendering.
  static func format(_ seconds: TimeInterval) -> String {
    let hours = Int(seconds / 3600)
    if hours < 1 { return "<1h" }
    if hours < 24 { return "\(hours)h" }
    return "\(hours / 24)d \(hours % 24)h"
  }
}

/// Append-only battery level log backed by a CSV file, plus the in-memory
/// copy the panel reads for estimates and the chart.
@MainActor
@Observable
final class BatteryHistory {
  static let centralRole = "central"
  static func peripheralRole(_ index: Int) -> String { "peripheral\(index + 1)" }
  static func displayName(role: String) -> String {
    role == centralRole ? "Central" : "Peripheral \(role.dropFirst("peripheral".count))"
  }

  static var defaultFileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ZMK Battery Bar", isDirectory: true)
      .appendingPathComponent("battery-history.csv")
  }

  // ponytail: whole file kept in memory; at most a few rows per hour this
  // stays tiny for years. Prune on load if it ever matters.
  private(set) var entries: [BatteryHistoryEntry] = []
  private let fileURL: URL?

  /// `fileURL == nil` keeps the log in memory only.
  init(fileURL: URL?) {
    self.fileURL = fileURL
    guard let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
    entries = text.split(whereSeparator: \.isNewline).compactMap { BatteryHistoryCSV.decode(String($0)) }
  }

  /// Appends a reading if it differs from the last one logged for the same
  /// keyboard and role. Returns true when an entry was written.
  @discardableResult
  func record(keyboard: String, role: String, level: Int, at date: Date = Date()) -> Bool {
    let previous = entries.last { $0.keyboard == keyboard && $0.role == role }
    guard previous?.level != level else { return false }
    let entry = BatteryHistoryEntry(date: date, keyboard: keyboard, role: role, level: level)
    entries.append(entry)
    append(line: BatteryHistoryCSV.encode(entry))
    return true
  }

  func series(keyboard: String, role: String) -> [BatteryHistoryEntry] {
    entries.filter { $0.keyboard == keyboard && $0.role == role }
  }

  /// Roles seen for a keyboard, central first.
  func roles(keyboard: String) -> [String] {
    var seen: [String] = []
    for e in entries where e.keyboard == keyboard && !seen.contains(e.role) {
      seen.append(e.role)
    }
    return seen.sorted { $0 == Self.centralRole || ($1 != Self.centralRole && $0 < $1) }
  }

  private func append(line: String) {
    guard let fileURL else { return }
    do {
      let fm = FileManager.default
      if !fm.fileExists(atPath: fileURL.path) {
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (BatteryHistoryCSV.header + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
      }
      let handle = try FileHandle(forWritingTo: fileURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data((line + "\n").utf8))
    } catch {
      print("[BatteryHistory] Failed to append to \(fileURL.path): \(error.localizedDescription)")
    }
  }
}
