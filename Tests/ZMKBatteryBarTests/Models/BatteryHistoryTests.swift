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
  private func expectClose(_ actual: TimeInterval?, _ expected: TimeInterval) {
    #expect(actual != nil && abs(actual! - expected) < 1)
  }

  private func entries(_ points: [(hoursAgo: Double, level: Int)], now: Date) -> [BatteryHistoryEntry] {
    points.map {
      BatteryHistoryEntry(date: now.addingTimeInterval(-$0.hoursAgo * 3600), keyboard: "kb", role: "central", level: $0.level)
    }
  }

  @Test("linear estimate from a steady discharge")
  func steadyDischarge() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    // 10 points in 10 hours -> 1 point/hour; latest 80 logged 1 h ago.
    let e = entries([(11, 90), (6, 85), (1, 80)], now: now)
    expectClose(BatteryEstimator.remainingTime(entries: e, now: now), 79 * 3600)
  }

  @Test("estimate restarts after a charge")
  func restartsAfterCharge() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    // Slow discharge, then charged to 100, then 2 points in 2 hours.
    let e = entries([(100, 50), (50, 20), (4, 100), (2, 99), (0, 98)], now: now)
    expectClose(BatteryEstimator.remainingTime(entries: e, now: now), 98 * 2 * 3600)
  }

  @Test("no estimate without enough span or drop")
  func insufficientData() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    #expect(BatteryEstimator.remainingTime(entries: [], now: now) == nil)
    #expect(BatteryEstimator.remainingTime(entries: entries([(5, 50)], now: now), now: now) == nil)
    #expect(BatteryEstimator.remainingTime(entries: entries([(0.5, 50), (0, 40)], now: now), now: now) == nil)
    #expect(BatteryEstimator.remainingTime(entries: entries([(5, 50), (0, 49)], now: now), now: now) == nil)
  }

  @Test("jitter of a point or two does not count as charging")
  func jitterIgnored() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let e = entries([(10, 60), (6, 58), (5, 59), (0, 50)], now: now)
    expectClose(BatteryEstimator.remainingTime(entries: e, now: now), 50 * 3600)
  }

  @Test("remaining time never goes negative and is measured from now")
  func clampsAtZero() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let e = entries([(200, 10), (100, 2)], now: now)
    #expect(BatteryEstimator.remainingTime(entries: e, now: now) == 0)
  }

  @Test(
    "compact duration format",
    arguments: [(1800.0, "<1h"), (3600.0, "1h"), (5 * 3600.0, "5h"), (26 * 3600.0, "1d 2h"), (72 * 3600.0, "3d 0h")]
  )
  func format(seconds: TimeInterval, expected: String) {
    #expect(BatteryEstimator.format(seconds) == expected)
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
