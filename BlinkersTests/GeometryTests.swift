import CoreGraphics
import Foundation
import Testing
@testable import Blinkers

@MainActor
struct WindowWidthTests {
    private func snapshot(_ mode: WidthMode, pixels: Double = 1600, window: Double = 60, sides: Double = 40) -> Settings.Snapshot {
        Settings.Snapshot(widthMode: mode, pixelsWidth: pixels, windowPercent: window, sidesPercent: sides, color: .black, opacity: 100)
    }

    @Test func pixelsUsesFixedWidth() {
        #expect(snapshot(.pixels, pixels: 1600).windowWidth(screenWidth: 2560) == 1600)
    }

    @Test func pixelsWiderThanScreenFillsScreen() {
        #expect(snapshot(.pixels, pixels: 3000).windowWidth(screenWidth: 2560) == 2560)
    }

    @Test func pixelsBelowMinimumIsClamped() {
        #expect(snapshot(.pixels, pixels: 100).windowWidth(screenWidth: 2560) == 400)
    }

    @Test func windowIsPercentOfScreen() {
        #expect(snapshot(.window, window: 60).windowWidth(screenWidth: 2560) == 1536)
        #expect(snapshot(.window, window: 100).windowWidth(screenWidth: 2560) == 2560)
    }

    @Test func sidesIsRemainderOfScreen() {
        #expect(snapshot(.sides, sides: 40).windowWidth(screenWidth: 2560) == 1536)
        #expect(snapshot(.sides, sides: 0).windowWidth(screenWidth: 2560) == 2560)
    }
}

@MainActor
struct LayoutTests {
    // A 2560 × 1440 screen with a 25 pt menu bar.
    let area = CGRect(x: 0, y: 0, width: 2560, height: 1415)

    @Test func centeredWindowSitsInTheMiddle() {
        let frame = FocusController.centered(CGSize(width: 1536, height: 1391), in: area)
        #expect(frame == CGRect(x: 512, y: 12, width: 1536, height: 1391))
    }

    @Test func centeringRespectsAreaOffset() {
        // A second screen to the right of the first, with the Dock below.
        let other = CGRect(x: 2560, y: 80, width: 1920, height: 1000)
        let frame = FocusController.centered(CGSize(width: 960, height: 976), in: other)
        #expect(frame == CGRect(x: 3040, y: 92, width: 960, height: 976))
    }

    @Test func closedHoleSitsInTheMiddleOfTheWindow() {
        let window = CGRect(x: 512, y: 12, width: 1536, height: 1391)
        let hole = CurtainSurface.closed(at: window)
        #expect(window.contains(hole.rect))
        #expect(hole.rect.midX == window.midX && hole.rect.midY == window.midY)
    }

    @Test func holeAroundWindowCoversItsCorners() {
        let window = CGRect(x: 512, y: 12, width: 1536, height: 1391)
        let hole = CurtainSurface.hole(around: window)
        #expect(hole.rect == window)
        #expect(hole.radius >= 12)
    }

    @Test func openHoleLeavesNothingCovered() {
        #expect(CurtainSurface.open(around: area).rect.contains(area))
    }
}

@MainActor
struct RecoveryTests {
    @Test func roundTripsThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "BlinkersTests.recovery"))
        defer { defaults.removePersistentDomain(forName: "BlinkersTests.recovery") }

        let recovery = FocusRecovery(pid: 42, savedFrame: CGRect(x: 10, y: 20, width: 800, height: 600),
                                     currentFrame: CGRect(x: 512, y: 12, width: 1536, height: 1391))
        recovery.save(to: defaults)
        #expect(FocusRecovery.load(from: defaults) == recovery)

        FocusRecovery.clear(in: defaults)
        #expect(FocusRecovery.load(from: defaults) == nil)
    }
}
