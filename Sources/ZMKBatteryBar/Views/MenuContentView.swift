import Charts
import Combine
import SwiftUI

struct MenuContentView: View {
  @ObservedObject var bleManager: BLEManager
  let appSettings: AppSettings
  let batteryState: BatteryState
  let batteryHistory: BatteryHistory
  let navigation: PanelNavigation
  var onLabelChange: () -> Void = {}

  @State private var hideBatteryIcon = false
  @State private var singleLineLayout = false
  @State private var swapBatteryIconPositions = false
  @State private var launchAtLogin = LaunchAtLogin.isEnabled
  @State private var now = Date()
  @State private var labelStyleTick = 0
  @State private var showEstimateDetails = false

  private let updateTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

  var body: some View {
    if navigation.showKeyboardList {
      KeyboardListView(
        bleManager: bleManager,
        appSettings: appSettings,
        onDismiss: { navigation.showKeyboardList = false },
        onSelectionChange: {
          labelStyleTick &+= 1
          onLabelChange()
        }
      )
    } else {
      mainContent
    }
  }

  @ViewBuilder
  private var mainContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let keyboard = appSettings.selectedKeyboard {
        Text(keyboard.name)
          .font(.headline)
      } else {
        Text("Not Connected")
          .font(.headline)
          .foregroundStyle(.secondary)
      }

      Divider()

      let keyboard = appSettings.selectedKeyboard
      let stale = batteryState.isStale(now: now)
      batteryRow(label: "Central", level: stale ? nil : batteryState.centralLevel, peripheralIndex: nil, keyboard: keyboard)
      ForEach(batteryState.peripherals) { p in
        let label = batteryState.peripherals.count > 1 ? "Peripheral \(p.index + 1)" : "Peripheral"
        batteryRow(label: label, level: stale ? nil : p.level, peripheralIndex: p.index, keyboard: keyboard)
      }

      if let keyboard {
        historySection(keyboard: keyboard.uuid)
      }

      if let lastUpdated = batteryState.lastUpdated {
        Text("Updated: \(TimeAgoFormatter.format(from: lastUpdated, now: now))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Divider()

      Toggle("Hide Battery Icon", isOn: $hideBatteryIcon)
        .onChange(of: hideBatteryIcon) { _, newValue in
          appSettings.showBatteryIcon = !newValue
          onLabelChange()
        }

      Toggle("Single Line Layout", isOn: $singleLineLayout)
        .onChange(of: singleLineLayout) { _, newValue in
          appSettings.singleLineLayout = newValue
          onLabelChange()
        }

      Toggle("Swap Battery Positions", isOn: $swapBatteryIconPositions)
        .onChange(of: swapBatteryIconPositions) { _, newValue in
          appSettings.swapBatteryIconPositions = newValue
          onLabelChange()
        }

      Toggle("Launch at Login", isOn: $launchAtLogin)
        .onChange(of: launchAtLogin) { _, newValue in
          do {
            if newValue {
              try LaunchAtLogin.enable()
            } else {
              try LaunchAtLogin.disable()
            }
          } catch {
            launchAtLogin = !newValue
          }
        }

      Button("Keyboards...") {
        navigation.showKeyboardList = true
      }

      Divider()

      HStack {
        Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Quit") {
          NSApplication.shared.terminate(nil)
        }
      }
    }
    .padding(12)
    .frame(width: 260)
    .onReceive(updateTimer) { now = $0 }
    .onAppear {
      now = Date()
      hideBatteryIcon = !appSettings.showBatteryIcon
      singleLineLayout = appSettings.singleLineLayout
      swapBatteryIconPositions = appSettings.swapBatteryIconPositions
    }
  }

  private func batteryRow(
    label: String,
    level: Int?,
    peripheralIndex: Int?,
    keyboard: KeyboardDevice?
  ) -> some View {
    HStack(spacing: 2) {
      Text(label)
        .lineLimit(1)
        .frame(width: 85, alignment: .leading)
      BatteryIconView(level: level)
      Text(level.map { "\($0)%" } ?? "--")
        .monospacedDigit()
      Spacer()
      if let keyboard {
        if batteryState.peripherals.count <= 1 {
          // Legacy 1-peripheral: L/R toggles central/peripheral together
          let side: KeyboardSide = peripheralIndex != nil ? .peripheral : .central
          let current = keyboard.labelStyle == .leftRight ? keyboard.labelShort(for: side) : nil
          HStack(spacing: 2) {
            letterButton("L", selected: current == "L") { applyLegacy(letter: "L", to: side, for: keyboard.uuid) }
            letterButton("R", selected: current == "R") { applyLegacy(letter: "R", to: side, for: keyboard.uuid) }
          }
          .id(labelStyleTick)
        } else if let index = peripheralIndex {
          // Multi-peripheral: L/R per peripheral
          let current = index < keyboard.peripheralLabels.count ? keyboard.peripheralLabels[index] : ""
          HStack(spacing: 2) {
            letterButton("L", selected: current == "L") { applyPeripheralLabel("L", at: index, for: keyboard.uuid, current: current) }
            letterButton("R", selected: current == "R") { applyPeripheralLabel("R", at: index, for: keyboard.uuid, current: current) }
          }
          .id(labelStyleTick)
        }
      }
    }
  }

  private static let chartDays = 8 * 7

  /// Per side: a one-bar-per-day chart of the last 8 weeks (week boundaries
  /// as gridlines, like the macOS battery panel) and the runtime estimate.
  @ViewBuilder
  private func historySection(keyboard: String) -> some View {
    let roles = batteryHistory.roles(keyboard: keyboard)
    if !roles.isEmpty {
      Divider()
      ForEach(Array(roles.enumerated()), id: \.element) { index, role in
        let entries = batteryHistory.series(keyboard: keyboard, role: role)
        let estimate = BatteryEstimator.estimate(entries: entries, now: now)
        HStack(spacing: 4) {
          Text(BatteryHistory.displayName(role: role))
          Spacer()
          Text(estimateText(estimate))
            .foregroundStyle(.secondary)
          // Tooltips do not show in the non-key panel, so the details toggle.
          Button {
            showEstimateDetails.toggle()
          } label: {
            Image(systemName: "info.circle")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
        .font(.caption)
        if showEstimateDetails {
          Text(estimateDetail(estimate))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        // Only the bottom chart carries dates; the others count weeks.
        dailyChart(entries: entries, weekNumbers: index < roles.count - 1)
      }
    }
  }

  private func estimateText(_ estimate: BatteryEstimate) -> String {
    guard let remaining = estimate.remaining, let halfWidth = estimate.halfWidth else {
      return "Est: not enough data"
    }
    return "Est: ~\(BatteryEstimator.formatCoarse(remaining)) ± \(BatteryEstimator.formatCoarse(halfWidth))"
  }

  private func estimateDetail(_ estimate: BatteryEstimate) -> String {
    let facts = "\(estimate.points) readings, \(BatteryEstimator.format(estimate.observedDischarge)) of discharge observed."
    guard estimate.remaining != nil else { return facts }
    let confidence = Int((estimate.confidence * 100).rounded())
    let slopeError = Int((min(estimate.relativeError, 1) * 100).rounded())
    return facts + " Estimation confidence \(confidence)%: discharge rate uncertain by ±\(slopeError)%, "
      + "\(estimate.observedDrop) of \(estimate.observedDrop + estimate.level) battery points watched. "
      + "The ± range is the estimate times the remaining \(100 - confidence)%."
  }

  private func dailyChart(entries: [BatteryHistoryEntry], weekNumbers: Bool) -> some View {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    let start = calendar.date(byAdding: .day, value: -(Self.chartDays - 1), to: today) ?? today
    let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
    let buckets = BatteryHistoryDaily.buckets(entries: entries, days: Self.chartDays, now: now, calendar: calendar)
    // Week boundaries as separators.
    var weekStarts: [Date] = []
    var cursor = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? start
    while cursor < end {
      if cursor >= start { weekStarts.append(cursor) }
      cursor = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor) ?? end
    }
    return Chart(buckets, id: \.day) { bucket in
      BarMark(
        x: .value("Day", bucket.day, unit: .day),
        y: .value("Level", bucket.level),
        width: .ratio(0.6)
      )
      .foregroundStyle(Color.green)
    }
    .chartXScale(domain: start...end)
    .chartYScale(domain: 0...100)
    .chartYAxis { AxisMarks(values: [0, 50, 100]) }
    .chartXAxis {
      AxisMarks(values: weekStarts) { value in
        AxisGridLine()
        if weekNumbers {
          AxisValueLabel {
            if let date = value.as(Date.self), let week = weekStarts.firstIndex(of: date) {
              Text("W\(week + 1)")
            }
          }
        } else {
          AxisValueLabel(format: .dateTime.month(.abbreviated).day(), collisionResolution: .greedy)
        }
      }
    }
    .chartLegend(.hidden)
    .frame(height: 48)
  }

  private func letterButton(_ letter: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(letter)
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .frame(width: 16, height: 16)
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 4)
            .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1)
        )
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
    }
    .buttonStyle(.plain)
  }

  private func applyLegacy(letter: String, to side: KeyboardSide, for uuid: String) {
    appSettings.updateKeyboard(uuid: uuid) { device in
      let current = device.labelStyle == .leftRight ? device.labelShort(for: side) : nil
      device.assignLetter(current == letter ? nil : letter, to: side)
    }
    labelStyleTick &+= 1
    onLabelChange()
  }

  private func applyPeripheralLabel(_ letter: String, at index: Int, for uuid: String, current: String) {
    appSettings.updateKeyboard(uuid: uuid) { device in
      device.assignPeripheralLabel(current == letter ? nil : letter, at: index)
    }
    labelStyleTick &+= 1
    onLabelChange()
  }
}
