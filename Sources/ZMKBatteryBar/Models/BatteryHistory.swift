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
  /// Relative standard error of the discharge rate (0 = perfectly straight).
  let relativeError: Double
  /// Battery points seen discharging across all cycles.
  let observedDrop: Int
  /// Current level, the part the estimate still has to extrapolate over.
  let level: Int

  /// Share of the extrapolation that is backed by observation. sqrt keeps the
  /// early numbers from sitting near zero for a week.
  var coverage: Double {
    let total = observedDrop + level
    return total > 0 ? (Double(observedDrop) / Double(total)).squareRoot() : 0
  }

  /// 0...1: how straight the fit is, times how much of the battery has been
  /// watched. Never reaches 1 while there is battery left to extrapolate.
  var confidence: Double {
    remaining == nil ? 0 : max(0, 1 - min(relativeError, 1)) * coverage
  }

  /// Half-width of the "± N" range: the estimate scaled by what confidence
  /// leaves uncovered, so the range shrinks as confidence grows.
  // ponytail: not a statistical interval; slope SE and coverage are folded
  // into one number so the display and the ⓘ text agree.
  var halfWidth: TimeInterval? {
    remaining.map { $0 * (1 - confidence) }
  }
}

/// Estimation follows what UPower, Android's BatteryStats and the usage-based
/// patents do for percent-only data: discharge rate over the current cycle,
/// blended with the rate seen in previous cycles, then `level / rate`.
///
/// - The log is split into discharge cycles at charge events (see `cycles`).
/// - The current cycle's rate is a least-squares slope through its readings
///   plus a pseudo-reading at `now` (the level still holds), so a long flat
///   stretch pulls the estimate up instead of being ignored.
/// - Previous cycles contribute a span-weighted mean slope. The two are
///   blended with a weight that moves to the current cycle as it accumulates
///   time, so an estimate is available right after a charge and converges to
///   this cycle's real usage over a few days.
/// - The fit's standard error and the share of battery actually observed
///   drive `BatteryEstimate.confidence` and the ± range.
enum BatteryEstimator {
  /// A level increase of at least this many points between consecutive
  /// entries is treated as the start of a charge; readings can jitter by a
  /// point or two under load, so single-point bumps are not.
  static let chargeJump = 3
  /// A cycle contributes a rate (as history, or on its own as the current
  /// cycle) only with at least this much time and this much drop; a
  /// half-hour blip before a charge would otherwise dominate the blend.
  static let minimumSpan: TimeInterval = 6 * 3600
  static let minimumDrop = 2
  /// Current-cycle span at which it carries equal weight with history.
  static let blendHalfLife: TimeInterval = 2 * 86400
  /// Relative error assumed for a history made of a single cycle (no spread
  /// to measure) and for a current fit with too few points for a residual.
  static let unknownRelativeError = 0.5

  struct Fit: Equatable {
    /// Points per second, negative while discharging.
    let slope: Double
    /// Standard error of `slope`; nil with fewer than 3 points.
    let standardError: Double?
  }

  /// `entries` must be for one keyboard/role, sorted by date ascending.
  static func estimate(entries: [BatteryHistoryEntry], now: Date) -> BatteryEstimate {
    func none(observed: TimeInterval = 0, drop: Int = 0, level: Int = 0) -> BatteryEstimate {
      BatteryEstimate(
        remaining: nil, points: entries.count, observedDischarge: observed,
        relativeError: 1, observedDrop: drop, level: level)
    }
    guard let last = entries.last else { return none() }

    var cycles = cycles(entries)
    var current = cycles.removeLast()
    current.append(BatteryHistoryEntry(date: now, keyboard: last.keyboard, role: last.role, level: last.level))

    let currentSpan = span(current)
    let observed = cycles.reduce(currentSpan) { $0 + span($1) }
    let observedDrop = (cycles + [current]).reduce(0) { $0 + max(($1.first?.level ?? 0) - ($1.last?.level ?? 0), 0) }

    let currentFit = fit(current)
    let history = cycles.compactMap { cycle -> (rate: Double, weight: Double)? in
      guard isUsable(cycle), let f = fit(cycle), f.slope < 0 else { return nil }
      return (f.slope, span(cycle))
    }
    let historyWeight = history.reduce(0) { $0 + $1.weight }
    var historyRate: Double?
    var historyRelativeError = unknownRelativeError
    if historyWeight > 0 {
      let mean = history.reduce(0) { $0 + $1.rate * $1.weight } / historyWeight
      historyRate = mean
      if history.count > 1 {
        let variance = history.reduce(0) { $0 + $1.weight * ($1.rate - mean) * ($1.rate - mean) } / historyWeight
        historyRelativeError = variance.squareRoot() / -mean
      }
    }

    let rate: Double?
    let relativeError: Double
    switch (currentFit, historyRate) {
    case let (c?, h?):
      let w = currentSpan / (currentSpan + blendHalfLife)
      rate = w * c.slope + (1 - w) * h
      relativeError = w * currentRelativeError(c) + (1 - w) * historyRelativeError
    case let (c?, nil):
      rate = isUsable(current) ? c.slope : nil
      relativeError = currentRelativeError(c)
    case let (nil, h?):
      rate = h
      relativeError = historyRelativeError
    case (nil, nil):
      rate = nil
      relativeError = 1
    }

    guard let rate, rate < 0 else {
      return none(observed: observed, drop: observedDrop, level: last.level)
    }
    return BatteryEstimate(
      remaining: Double(last.level) / -rate,
      points: entries.count,
      observedDischarge: observed,
      relativeError: relativeError,
      observedDrop: observedDrop,
      level: last.level
    )
  }

  private static func isUsable(_ cycle: [BatteryHistoryEntry]) -> Bool {
    guard let first = cycle.first, let last = cycle.last else { return false }
    return span(cycle) >= minimumSpan && first.level - last.level >= minimumDrop
  }

  private static func currentRelativeError(_ f: Fit) -> Double {
    guard f.slope < 0 else { return 1 }
    guard let se = f.standardError else { return unknownRelativeError }
    return se / -f.slope
  }

  /// Splits into discharge cycles. A charge is a cumulative rise of
  /// `chargeJump` or more above the cycle's lowest level, so a charger that
  /// reports +1 every few minutes is detected as well as a single jump. The
  /// closed cycle ends at its last lowest reading, the rising run is skipped,
  /// and the next cycle starts at its peak, so the charging ramp never enters
  /// a fit.
  static func cycles(_ entries: [BatteryHistoryEntry]) -> [[BatteryHistoryEntry]] {
    var result: [[BatteryHistoryEntry]] = []
    var i = 0
    while i < entries.count {
      var cycle = [entries[i]]
      var lowest = entries[i].level
      var j = i + 1
      while j < entries.count, entries[j].level - lowest < chargeJump {
        cycle.append(entries[j])
        lowest = min(lowest, entries[j].level)
        j += 1
      }
      if j < entries.count {
        // A charge follows: its first +1/+2 steps are already in the cycle,
        // so cut the cycle at its last lowest reading.
        let lastLow = cycle.lastIndex { $0.level == lowest }!
        cycle.removeSubrange((lastLow + 1)...)
      }
      result.append(cycle)
      // Charging: advance to the peak of the non-decreasing run.
      while j + 1 < entries.count, entries[j + 1].level >= entries[j].level {
        j += 1
      }
      i = j
    }
    return result
  }

  private static func span(_ cycle: [BatteryHistoryEntry]) -> TimeInterval {
    guard let first = cycle.first, let last = cycle.last else { return 0 }
    return last.date.timeIntervalSince(first.date)
  }

  /// Ordinary least-squares fit of level over time.
  static func fit(_ cycle: [BatteryHistoryEntry]) -> Fit? {
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
    let slope = sxy / sxx
    guard xs.count >= 3 else { return Fit(slope: slope, standardError: nil) }
    let intercept = meanY - slope * meanX
    let sse = zip(xs, ys).reduce(0.0) { acc, p in
      let r = p.1 - (intercept + slope * p.0)
      return acc + r * r
    }
    return Fit(slope: slope, standardError: (sse / (n - 2) / sxx).squareRoot())
  }

  /// Compact "3d 4h" / "5h" / "<1h" rendering.
  static func format(_ seconds: TimeInterval) -> String {
    let hours = Int(seconds / 3600)
    if hours < 1 { return "<1h" }
    if hours < 24 { return "\(hours)h" }
    return "\(hours / 24)d \(hours % 24)h"
  }

  /// Coarser "12d" / "5h" rendering for the estimate and its ± range.
  static func formatCoarse(_ seconds: TimeInterval) -> String {
    let hours = Int((seconds / 3600).rounded())
    if hours < 24 { return "\(hours)h" }
    return "\((seconds / 86400).rounded())d".replacingOccurrences(of: ".0d", with: "d")
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
