import Foundation
import Testing

@testable import ZMKBatteryBar

@Suite("LayerIndicator")
struct LayerIndicatorTests {
  private let names = ["BASE", "SYM", "BRC", "FN", "GAME", "GNUM", "KBD"]
  private let labels = ["GAME": "G"]

  @Test("mask is uint32 little-endian")
  func parsesMask() {
    #expect(LayerIndicator.parseActiveMask(from: Data([0x11, 0x00, 0x00, 0x00])) == 0b1_0001)
    #expect(LayerIndicator.parseActiveMask(from: Data([0x00, 0x01, 0x00, 0x80])) == 0x8000_0100)
    #expect(LayerIndicator.parseActiveMask(from: Data([0x01])) == nil)
    #expect(LayerIndicator.parseActiveMask(from: nil) == nil)
  }

  @Test("names split on newline, empty names get a positional fallback")
  func parsesNames() {
    let data = Data("BASE\n\nGAME".utf8)
    #expect(LayerIndicator.parseNames(from: data) == ["BASE", "Layer 1", "GAME"])
    #expect(LayerIndicator.parseNames(from: Data()) == [])
  }

  @Test("toggled GAME shows its label")
  func gameOn() {
    #expect(LayerIndicator.label(activeMask: 0b1_0001, names: names, labels: labels) == "G")
  }

  @Test("held unlabeled layers over GAME keep the GAME label")
  func heldOverGame() {
    // BASE + GAME + GNUM (held) + KBD (combo)
    #expect(LayerIndicator.label(activeMask: 0b111_0001, names: names, labels: labels) == "G")
  }

  @Test("GAME off clears the label, even with a held layer")
  func gameOff() {
    #expect(LayerIndicator.label(activeMask: 0b0001, names: names, labels: labels) == nil)
    #expect(LayerIndicator.label(activeMask: 0b0011, names: names, labels: labels) == nil)
  }

  @Test("highest labeled active layer wins")
  func highestWins() {
    let both = ["GAME": "G", "GNUM": "#"]
    #expect(LayerIndicator.label(activeMask: 0b11_0001, names: names, labels: both) == "#")
    #expect(LayerIndicator.label(activeMask: 0b01_0001, names: names, labels: both) == "G")
  }

  @Test("no data yet means no label")
  func noData() {
    #expect(LayerIndicator.label(activeMask: nil, names: names, labels: labels) == nil)
    #expect(LayerIndicator.label(activeMask: 0b1_0001, names: [], labels: labels) == nil)
  }
}
