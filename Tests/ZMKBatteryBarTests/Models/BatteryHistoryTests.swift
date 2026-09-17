import Foundation
import Testing

@testable import ZMKBatteryBar

@Suite("BatteryHistoryCSV")
struct BatteryHistoryCSVTests {
  @Test("encode/decode round trip")
  func roundTrip() {
    let entry = BatteryHistoryEntry(
      date: Date(timeIntervalSince1970: 1_700_000_000), keyboard: "ABC-123", role: "peripheral1", level: 42)
    let line = BatteryHistoryCSV.encode(entry)
    #expect(line == "2023-11-14T22:13:20Z,ABC-123,peripheral1,42")
    #expect(BatteryHistoryCSV.decode(line) == entry)
  }

  @Test("decode rejects header, malformed and out-of-range lines")
  func decodeRejects() {
    #expect(BatteryHistoryCSV.decode(BatteryHistoryCSV.header) == nil)
    #expect(BatteryHistoryCSV.decode("2023-11-14T22:13:20Z,kb,central") == nil)
    #expect(BatteryHistoryCSV.decode("2023-11-14T22:13:20Z,kb,central,101") == nil)
    #expect(BatteryHistoryCSV.decode("nope,kb,central,50") == nil)
    #expect(BatteryHistoryCSV.decode("") == nil)
  }
}

@Suite("BatteryEstimator")
struct BatteryEstimatorTests {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  private func expectClose(_ actual: TimeInterval?, _ expected: TimeInterval, tolerance: Double = 1) {
    #expect(actual != nil && abs(actual! - expected) <= tolerance)
  }

  private func entries(_ points: [(hoursAgo: Double, level: Int)]) -> [BatteryHistoryEntry] {
    points.map {
      BatteryHistoryEntry(date: now.addingTimeInterval(-$0.hoursAgo * 3600), keyboard: "kb", role: "central", level: $0.level)
    }
  }

  @Test("cycles split at charge jumps, jitter stays in the cycle")
  func cycles() {
    let e = entries([(10, 60), (9, 58), (8, 59), (7, 50), (6, 100), (5, 99)])
    #expect(BatteryEstimator.cycles(e).map { $0.map(\.level) } == [[60, 58, 59, 50], [100, 99]])
  }

  @Test("a +1-step charging ramp is detected and excluded from the new cycle")
  func steppedChargeRamp() {
    let e = entries([(30, 85), (29, 84), (28, 85), (27, 86), (26, 87), (25, 88), (24, 96), (23, 97), (1, 96)])
    #expect(BatteryEstimator.cycles(e).map { $0.map(\.level) } == [[85, 84], [97, 96]])
  }

  @Test("steady discharge: 1 point/hour, estimate measured from now")
  func steadyDischarge() {
    // Exactly linear, latest point at now, so the pseudo-point changes nothing.
    let e = entries([(10, 90), (5, 85), (0, 80)])
    let est = BatteryEstimator.estimate(entries: e, now: now)
    expectClose(est.remaining, 80 * 3600)
    #expect(est.points == 3)
    expectClose(est.observedDischarge, 10 * 3600)
  }

  @Test("no estimate without enough data")
  func insufficientData() {
    #expect(BatteryEstimator.estimate(entries: [], now: now).remaining == nil)
    #expect(BatteryEstimator.estimate(entries: entries([(5, 50)]), now: now).remaining == nil)
    // 2 hours is below minimumSpan when there is no history.
    let short = BatteryEstimator.estimate(entries: entries([(2, 50), (1, 49)]), now: now)
    #expect(short.remaining == nil)
    #expect(short.points == 2)
    // Flat level for a long time: slope 0, no history -> nothing to divide by.
    #expect(BatteryEstimator.estimate(entries: entries([(100, 50), (0, 50)]), now: now).remaining == nil)
    // Jitter with no net drop over a long time must not yield an estimate.
    #expect(BatteryEstimator.estimate(entries: entries([(18, 89), (15, 90), (1, 89)]), now: now).remaining == nil)
  }

  @Test("a short blip before a charge is not used as history")
  func shortCycleIgnoredAsHistory() {
    // 85 -> 84 in half an hour, charge to 97, then 97 -> 95 over 16 h.
    let e = entries([(17, 85), (16.5, 84), (16, 97), (6, 96), (0, 95)])
    let est = BatteryEstimator.estimate(entries: e, now: now)
    // Rate must come from the current cycle alone, roughly 2 points / 16 h
    // (the least-squares slope is not exactly the endpoint rate).
    expectClose(est.remaining, 95 / (2.0 / 16) * 3600, tolerance: 10 * 3600)
  }

  @Test("a flat stretch since the last reading lengthens the estimate")
  func flatStretchCounts() {
    // 1 point/hour for 10 h, then nothing for 10 h: fit through the pseudo-point is shallower.
    let e = entries([(20, 90), (15, 85), (10, 80)])
    let est = BatteryEstimator.estimate(entries: e, now: now)
    #expect(est.remaining! > 80 * 3600)
  }

  @Test("right after a charge the previous cycle's rate is used")
  func historyRateAfterCharge() {
    // Previous cycle: 50 points over 100 h = 0.5/h. Charged to 100 one hour ago, no drop yet.
    let e = entries([(200, 70), (100, 20), (1, 100)])
    let est = BatteryEstimator.estimate(entries: e, now: now)
    // w = 1h / (1h + 48h); current slope 0, so rate = (1-w) * 0.5/h.
    let w = 3600.0 / (3600.0 + BatteryEstimator.blendHalfLife)
    expectClose(est.remaining, 100 / ((1 - w) * 0.5) * 3600, tolerance: 2)
    expectClose(est.observedDischarge, 101 * 3600)
  }

  @Test("blend converges to the current cycle as it grows")
  func blendConverges() {
    // History: 1/h. Current cycle: 0.05/h over 20 days (24 points).
    let hours = 20.0 * 24
    let e = entries([(hours + 100, 100), (hours + 1, 1), (hours, 100), (0, 76)])
    let est = BatteryEstimator.estimate(entries: e, now: now)
    let w = hours * 3600 / (hours * 3600 + BatteryEstimator.blendHalfLife)
    let rate = w * 0.05 + (1 - w) * 1.0
    expectClose(est.remaining, 76 / rate * 3600, tolerance: 2)
    #expect(est.confidence > 0 && est.confidence < 1)
  }

  @Test("a perfectly straight fit has zero error; confidence is then coverage")
  func straightFit() {
    let e = entries([(30, 100), (20, 90), (10, 80), (0, 70)])
    let est = BatteryEstimator.estimate(entries: e, now: now)
    #expect(est.relativeError < 1e-9)
    #expect(est.observedDrop == 30)
    #expect(est.level == 70)
    #expect(abs(est.coverage - (30.0 / 100).squareRoot()) < 1e-9)
    #expect(abs(est.confidence - est.coverage) < 1e-9)
    #expect(abs(est.halfWidth! - est.remaining! * (1 - est.confidence)) < 1e-6)
  }

  @Test("a jittery fit lowers confidence and widens the range")
  func jitteryFit() {
    let straight = BatteryEstimator.estimate(entries: entries([(30, 100), (20, 90), (10, 80), (0, 70)]), now: now)
    let jittery = BatteryEstimator.estimate(entries: entries([(30, 100), (20, 84), (10, 86), (0, 70)]), now: now)
    #expect(jittery.relativeError > 0.01)
    #expect(jittery.confidence < straight.confidence)
    #expect(jittery.halfWidth! / jittery.remaining! > straight.halfWidth! / straight.remaining!)
  }

  @Test("confidence is zero without an estimate and never reaches one with battery left")
  func confidenceBounds() {
    #expect(BatteryEstimator.estimate(entries: entries([(5, 50)]), now: now).confidence == 0)
    let e = entries([(300, 100), (200, 60), (100, 20), (0, 2)])
    let est = BatteryEstimator.estimate(entries: e, now: now)
    #expect(est.confidence > 0.9 && est.confidence < 1)
  }

  @Test("fit reports the slope standard error from the residuals")
  func fitStandardError() {
    let f = BatteryEstimator.fit(entries([(3, 4), (2, 2), (1, 3), (0, 1)]))!
    // OLS on x=0,1,2,3 (hours) y=4,2,3,1: slope -0.8/h, residuals 0.3,-0.9,0.9,-0.3,
    // SE = sqrt(SSE/(n-2)/Sxx) with SSE=1.8, Sxx=5.
    #expect(abs(f.slope * 3600 + 0.8) < 1e-9)
    #expect(abs(f.standardError! * 3600 - (1.8 / 2 / 5).squareRoot()) < 1e-9)
    #expect(BatteryEstimator.fit(entries([(1, 4), (0, 2)]))!.standardError == nil)
  }

  @Test(
    "coarse format",
    arguments: [(1800.0, "1h"), (5 * 3600.0, "5h"), (23.6 * 3600.0, "1d"), (12.4 * 86400.0, "12d")]
  )
  func formatCoarse(seconds: TimeInterval, expected: String) {
    #expect(BatteryEstimator.formatCoarse(seconds) == expected)
  }

  @Test(
    "compact duration format",
    arguments: [(1800.0, "<1h"), (3600.0, "1h"), (5 * 3600.0, "5h"), (26 * 3600.0, "1d 2h"), (72 * 3600.0, "3d 0h")]
  )
  func format(seconds: TimeInterval, expected: String) {
    #expect(BatteryEstimator.format(seconds) == expected)
  }
}

@Suite("BatteryHistoryDaily")
struct BatteryHistoryDailyTests {
  @Test("one bucket per day with carry-forward, none before the first reading")
  func buckets() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let day: TimeInterval = 86400
    let now = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13 UTC
    let today = calendar.startOfDay(for: now)
    let e = [
      BatteryHistoryEntry(date: today.addingTimeInterval(-2 * day + 3600), keyboard: "kb", role: "central", level: 80),
      BatteryHistoryEntry(date: today.addingTimeInterval(-2 * day + 7200), keyboard: "kb", role: "central", level: 78),
      BatteryHistoryEntry(date: today.addingTimeInterval(600), keyboard: "kb", role: "central", level: 70),
    ]
    let buckets = BatteryHistoryDaily.buckets(entries: e, days: 5, now: now, calendar: calendar)
    #expect(buckets.map(\.level) == [78, 78, 70])
    #expect(buckets.map(\.day) == [today.addingTimeInterval(-2 * day), today.addingTimeInterval(-day), today])
    #expect(BatteryHistoryDaily.buckets(entries: [], days: 5, now: now, calendar: calendar).isEmpty)
  }
}

@Suite("BatteryHistory")
@MainActor
struct BatteryHistoryTests {
  private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ZMKBatteryBarTests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("history.csv")
  }

  @Test("record skips unchanged levels per keyboard and role")
  func dedup() {
    let history = BatteryHistory(fileURL: nil)
    #expect(history.record(keyboard: "kb", role: "central", level: 80))
    #expect(!history.record(keyboard: "kb", role: "central", level: 80))
    #expect(history.record(keyboard: "kb", role: "peripheral1", level: 80))
    #expect(history.record(keyboard: "kb", role: "central", level: 79))
    #expect(history.entries.count == 3)
    #expect(history.series(keyboard: "kb", role: "central").map(\.level) == [80, 79])
    #expect(history.roles(keyboard: "kb") == ["central", "peripheral1"])
  }

  @Test("entries are appended to the CSV file and reloaded on init")
  func persistence() throws {
    let url = tempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    let first = BatteryHistory(fileURL: url)
    first.record(keyboard: "kb", role: "central", level: 80, at: t0)
    first.record(keyboard: "kb", role: "central", level: 79, at: t0.addingTimeInterval(60))

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.hasPrefix(BatteryHistoryCSV.header + "\n"))
    #expect(text.split(separator: "\n").count == 3)

    let reloaded = BatteryHistory(fileURL: url)
    #expect(reloaded.entries == first.entries)
    // The last logged level survives restarts, so the same value is not re-logged.
    #expect(!reloaded.record(keyboard: "kb", role: "central", level: 79))
  }
}
