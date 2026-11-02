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
  /// Calendar days with at least one reported drop. ZMK only samples the
  /// battery while the keyboard is active, so a drop means it was used.
  let usageDays: Int
  /// Previous cycles behind the per-band curve; 0 when `remaining` comes from
  /// a straight line.
  let curveCycles: Int

  /// Share of one full charge (100 points) seen discharging. Once a whole
  /// battery's worth has been watched the rate is known across the curve.
  /// sqrt keeps the early numbers from sitting near zero for a week.
  var coverage: Double {
    min(Double(observedDrop) / 100, 1).squareRoot()
  }

  /// 0...1: how straight the fit is, times how much of a charge has been
  /// watched.
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

  /// Days of actual use a 100% charge lasts at the observed drain per used
  /// day. Idle days (weekends, holidays) are left out, unlike `remaining`,
  /// which runs on calendar time.
  // ponytail: a lightly used day with no 1-point drop is not counted, which
  // shortens this a little on low-drain sides.
  var daysPerFullCharge: Double? {
    guard remaining != nil, usageDays > 0, observedDrop > 0 else { return nil }
    return 100 * Double(usageDays) / Double(observedDrop)
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
/// - Once previous cycles cover enough of the range, the straight line is
///   replaced by a `Curve`: ZMK maps voltage to percent linearly, so the
///   reported level falls fast near the top, slowly through the middle and
///   several times faster again below ~60%. One slope over that overestimates
///   the remaining time by 2-3x mid-cycle.
enum BatteryEstimator {
  /// A level increase of at least this many points between consecutive
  /// entries is treated as the start of a charge. Readings jitter by a point
  /// or two under load and the voltage can rebound a few points at rest
  /// (seen: +3 over 8 h with no charger), while a charge from any useful
  /// depth climbs well past this.
  static let chargeJump = 10
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
  /// 10-point bands previous cycles must have measured before the curve is
  /// used; with less, a curve is mostly guesses from the nearest band.
  static let minimumCurveBands = 5

  /// Discharge pace per 10-point band (levels 1-10, 11-20, ..., 91-100),
  /// learned from previous cycles. Bands without data borrow the nearest
  /// measured band's pace.
  struct Curve: Equatable {
    /// Seconds per point, keyed by band index 0...9.
    let secondsPerPoint: [Int: TimeInterval]
    /// Previous cycles that measured at least one band.
    let cycles: Int

    /// Time to discharge from level `high` down to `low` at the learned pace.
    func time(from high: Int, to low: Int) -> TimeInterval {
      (0..<10).reduce(0) { total, band in
        let points = min(high, band * 10 + 10) - max(low, band * 10)
        guard points > 0 else { return total }
        let nearest = secondsPerPoint.keys.min { (abs($0 - band), $0) < (abs($1 - band), $1) }!
        return total + Double(points) * secondsPerPoint[nearest]!
      }
    }
  }

  /// Learns a `Curve` from closed cycles, or nil when they measure fewer than
  /// `minimumCurveBands` bands. A band counts only when a cycle ran from its
  /// top (or the cycle's starting peak) to its bottom; a cycle charged mid-band
  /// may have sat idle there, which says nothing about the band's pace.
  static func curve(_ cycles: [[BatteryHistoryEntry]]) -> Curve? {
    var points: [Int: Int] = [:]
    var time: [Int: TimeInterval] = [:]
    var contributing = 0
    for cycle in cycles {
      guard let start = cycle.first else { continue }
      func reached(_ level: Int) -> Date? { cycle.first { $0.level <= level }?.date }
      var measured = false
      for band in 0..<10 {
        let low = band * 10
        let top = min(low + 10, start.level)
        guard top > low, let from = reached(top), let to = reached(low) else { continue }
        points[band, default: 0] += top - low
        time[band, default: 0] += to.timeIntervalSince(from)
        measured = true
      }
      if measured { contributing += 1 }
    }
    var secondsPerPoint: [Int: TimeInterval] = [:]
    for (band, t) in time where t > 0 { secondsPerPoint[band] = t / Double(points[band]!) }
    guard secondsPerPoint.count >= minimumCurveBands else { return nil }
    return Curve(secondsPerPoint: secondsPerPoint, cycles: contributing)
  }

  struct Fit: Equatable {
    /// Points per second, negative while discharging.
    let slope: Double
    /// Standard error of `slope`; nil with fewer than 3 points.
    let standardError: Double?
  }

  /// ZMK's split central reports level 0 for a peripheral whose link dropped
  /// (`split_central_disconnected()` in `split/bluetooth/central.c`), and the
  /// real level returns once it reconnects. A genuine discharge passes 3, 2, 1
  /// first, so dropping every 0 loses nothing and keeps the blip out of the
  /// cycle split, the fit, and the reading count.
  static func readings(_ entries: [BatteryHistoryEntry]) -> [BatteryHistoryEntry] {
    entries.filter { $0.level > 0 }
  }

  /// `entries` must be for one keyboard/role, sorted by date ascending.
  static func estimate(
    entries: [BatteryHistoryEntry], now: Date, calendar: Calendar = .current
  ) -> BatteryEstimate {
    let entries = readings(entries)
    func none(observed: TimeInterval = 0, drop: Int = 0, level: Int = 0, days: Int = 0) -> BatteryEstimate {
      BatteryEstimate(
        remaining: nil, points: entries.count, observedDischarge: observed,
        relativeError: 1, observedDrop: drop, level: level, usageDays: days, curveCycles: 0)
    }
    guard let last = entries.last else { return none() }

    var cycles = cycles(entries)
    var current = cycles.removeLast()
    current.append(BatteryHistoryEntry(date: now, keyboard: last.keyboard, role: last.role, level: last.level))

    let currentSpan = span(current)
    let observed = cycles.reduce(currentSpan) { $0 + span($1) }
    let observedDrop = (cycles + [current]).reduce(0) { $0 + max(($1.first?.level ?? 0) - ($1.last?.level ?? 0), 0) }
    let usageDays = Set((cycles + [current]).flatMap { cycle in
      zip(cycle, cycle.dropFirst()).filter { $1.level < $0.level }.map { calendar.startOfDay(for: $1.date) }
    }).count

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
      return none(observed: observed, drop: observedDrop, level: last.level, days: usageDays)
    }
    // Curve: the history's per-band pace, scaled by how fast this cycle has
    // run against the curve so far, blended in as the cycle accumulates time.
    // ponytail: relativeError still comes from the straight-line fits; it
    // tracks scatter, not curve error. Derive it from per-cycle pace spread if
    // the ± range proves too narrow.
    let curve = Self.curve(cycles.filter(isUsable))
    var remaining = Double(last.level) / -rate
    if let curve, let topBand = curve.secondsPerPoint.keys.max() {
      // Pace is measured from the top of the highest measured band: a band
      // the curve only borrows (e.g. 90-100 when no previous cycle started
      // that high) falls at a different pace and would skew it.
      // ponytail: a cycle below the lowest measured band still compares
      // against borrowed pace there; the tail is short, so it is left in.
      let from = min(current[0].level, topBand * 10 + 10)
      var factor = 1.0
      if let start = current.first(where: { $0.level <= from })?.date {
        let span = now.timeIntervalSince(start)
        let expected = curve.time(from: from, to: last.level)
        if span >= minimumSpan, from - last.level >= minimumDrop, expected > 0 {
          let w = span / (span + blendHalfLife)
          factor = w * span / expected + 1 - w
        }
      }
      remaining = curve.time(from: last.level, to: 0) * factor
    }
    return BatteryEstimate(
      remaining: remaining,
      points: entries.count,
      observedDischarge: observed,
      relativeError: relativeError,
      observedDrop: observedDrop,
      level: last.level,
      usageDays: usageDays,
      curveCycles: curve?.cycles ?? 0
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
    let entries = readings(entries)
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
    let entries = BatteryEstimator.readings(entries)
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
