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

/// Time-to-empty estimate from the level log.
struct BatteryEstimate: Equatable {
  /// Seconds until 0% measured from `now`; nil when there is not enough data.
  let remaining: TimeInterval?
  /// Number of logged readings for this side.
  let points: Int
  /// Total discharge time observed across all cycles.
  let observedDischarge: TimeInterval
  /// 0...1, grows with `observedDischarge`; 1 after `fullConfidenceSpan`.
  var confidence: Double { min(observedDischarge / BatteryEstimator.fullConfidenceSpan, 1) }
}

/// Estimation follows what UPower, Android's BatteryStats and the usage-based
/// patents do for percent-only data: discharge rate over the current cycle,
/// blended with the rate seen in previous cycles, then `level / rate`.
///
/// - The log is split into discharge cycles at charge events.
/// - The current cycle's rate is a least-squares slope through its readings
///   plus a pseudo-reading at `now` (the level still holds), so a long flat
///   stretch pulls the estimate up instead of being ignored.
/// - Previous cycles contribute a span-weighted mean slope. The two are
///   blended with a weight that moves to the current cycle as it accumulates
///   time, so an estimate is available right after a charge and converges to
///   this cycle's real usage over a few days.
enum BatteryEstimator {
  /// A level increase of at least this many points between consecutive
  /// entries is treated as the start of a charge; readings can jitter by a
  /// point or two under load, so single-point bumps are not.
  static let chargeJump = 3
  /// A current cycle without history needs at least this much time before
  /// its slope is trusted on its own.
  static let minimumSpan: TimeInterval = 6 * 3600
  /// Current-cycle span at which it carries equal weight with history.
  static let blendHalfLife: TimeInterval = 2 * 86400
  /// Observed discharge time that counts as full confidence.
  static let fullConfidenceSpan: TimeInterval = 14 * 86400

  /// `entries` must be for one keyboard/role, sorted by date ascending.
  static func estimate(entries: [BatteryHistoryEntry], now: Date) -> BatteryEstimate {
    let none = BatteryEstimate(remaining: nil, points: entries.count, observedDischarge: 0)
    guard let last = entries.last else { return none }

    var cycles = cycles(entries)
    var current = cycles.removeLast()
    current.append(BatteryHistoryEntry(date: now, keyboard: last.keyboard, role: last.role, level: last.level))

    let currentSpan = span(current)
    let observed = cycles.reduce(currentSpan) { $0 + span($1) }

    // Points per second, negative while discharging.
    let currentRate = slope(current)
    var historyRate: Double?
    let weightedHistory = cycles.compactMap { cycle -> (rate: Double, weight: Double)? in
      guard let rate = slope(cycle), rate < 0 else { return nil }
      return (rate, span(cycle))
    }
    let historyWeight = weightedHistory.reduce(0) { $0 + $1.weight }
    if historyWeight > 0 {
      historyRate = weightedHistory.reduce(0) { $0 + $1.rate * $1.weight } / historyWeight
    }

    let rate: Double?
    switch (currentRate, historyRate) {
    case let (c?, h?):
      let w = currentSpan / (currentSpan + blendHalfLife)
      rate = w * c + (1 - w) * h
    case let (c?, nil):
      rate = currentSpan >= minimumSpan ? c : nil
    case let (nil, h?):
      rate = h
    case (nil, nil):
      rate = nil
    }

    guard let rate, rate < 0 else {
      return BatteryEstimate(remaining: nil, points: entries.count, observedDischarge: observed)
    }
    return BatteryEstimate(
      remaining: Double(last.level) / -rate,
      points: entries.count,
      observedDischarge: observed
    )
  }

  /// Splits at every level increase of `chargeJump` or more.
  static func cycles(_ entries: [BatteryHistoryEntry]) -> [[BatteryHistoryEntry]] {
    var result: [[BatteryHistoryEntry]] = []
    for entry in entries {
      if let previous = result.last?.last, entry.level - previous.level < chargeJump {
        result[result.count - 1].append(entry)
      } else {
        result.append([entry])
      }
    }
    return result
  }

  private static func span(_ cycle: [BatteryHistoryEntry]) -> TimeInterval {
    guard let first = cycle.first, let last = cycle.last else { return 0 }
    return last.date.timeIntervalSince(first.date)
  }

  /// Ordinary least-squares slope of level over time (points per second).
  static func slope(_ cycle: [BatteryHistoryEntry]) -> Double? {
    guard cycle.count >= 2, let t0 = cycle.first?.date else { return nil }
    let xs = cycle.map { $0.date.timeIntervalSince(t0) }
    let ys = cycle.map { Double($0.level) }
    let n = Double(xs.count)
    let meanX = xs.reduce(0, +) / n
    let meanY = ys.reduce(0, +) / n
    var sxx = 0.0, sxy = 0.0
    for (x, y) in zip(xs, ys) {
      sxx += (x - meanX) * (x - meanX)
      sxy += (x - meanX) * (y - meanY)
    }
    guard sxx > 0 else { return nil }
    return sxy / sxx
  }

  /// Compact "3d 4h" / "5h" / "<1h" rendering.
  static func format(_ seconds: TimeInterval) -> String {
    let hours = Int(seconds / 3600)
    if hours < 1 { return "<1h" }
    if hours < 24 { return "\(hours)h" }
    return "\(hours / 24)d \(hours % 24)h"
  }
}

/// Daily buckets for the history chart: the last known level on each calendar
/// day, carried forward across days without readings.
enum BatteryHistoryDaily {
  struct Bucket: Equatable {
    let day: Date
    let level: Int
  }

  /// One bucket per day from `days - 1` days before `now` through today.
  /// Days before the first reading are omitted. `entries` must be sorted.
  static func buckets(
    entries: [BatteryHistoryEntry], days: Int, now: Date, calendar: Calendar = .current
  ) -> [Bucket] {
    guard let first = entries.first else { return [] }
    let today = calendar.startOfDay(for: now)
    var result: [Bucket] = []
    var index = 0
    var level: Int?
    for offset in stride(from: days - 1, through: 0, by: -1) {
      guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
      let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
      while index < entries.count, entries[index].date < dayEnd {
        level = entries[index].level
        index += 1
      }
      if let level, first.date < dayEnd {
        result.append(Bucket(day: day, level: level))
      }
    }
    return result
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
