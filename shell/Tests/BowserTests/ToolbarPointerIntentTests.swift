import AppKit
import XCTest
@testable import Bowser

final class ToolbarPointerIntentTests: XCTestCase {
    private let target = NSRect(x: 100, y: 700, width: 320, height: 40)

    func testBacktrackingYieldsUntilPointerLeavesOrDeliberatelyDwellsAtTopEdge() {
        var intent = ToolbarPointerIntent()
        _ = intent.update(point: NSPoint(x: 200, y: 660), time: 0, target: target, active: true)
        XCTAssertTrue(intent.update(point: NSPoint(x: 200, y: 690), time: 0.04, target: target, active: true))
        XCTAssertFalse(intent.update(point: NSPoint(x: 200, y: 674), time: 0.08, target: target, active: true))
        XCTAssertTrue(intent.yielded)
        for (point, time) in [(NSPoint(x: 200, y: 710), 0.12), (NSPoint(x: 200, y: 710), 3.0)] {
            XCTAssertFalse(intent.update(point: point, time: time, target: target, active: true))
        }
        XCTAssertFalse(intent.update(point: NSPoint(x: 200, y: 739), time: 3.1, target: target, active: true))
        XCTAssertTrue(intent.update(point: NSPoint(x: 200, y: 739), time: 3.5, target: target, active: true))
        XCTAssertFalse(intent.yielded)
    }

    func testJitterAndNativeInteractionDoNotShooControls() {
        var intent = ToolbarPointerIntent()
        _ = intent.update(point: NSPoint(x: 200, y: 695), time: 0, target: target, active: true)
        XCTAssertTrue(intent.update(point: NSPoint(x: 200, y: 690), time: 0.03, target: target, active: true))
        XCTAssertFalse(intent.yielded)
        XCTAssertTrue(intent.update(point: NSPoint(x: 200, y: 665), time: 0.06, target: target, active: true, interacting: true))
        XCTAssertFalse(intent.yielded)
    }

    func testLeavingShooAreaAllowsNextNormalApproach() {
        var intent = ToolbarPointerIntent()
        _ = intent.update(point: NSPoint(x: 200, y: 698), time: 0, target: target, active: true)
        _ = intent.update(point: NSPoint(x: 200, y: 680), time: 0.03, target: target, active: true)
        XCTAssertTrue(intent.yielded)
        _ = intent.update(point: NSPoint(x: 200, y: 400), time: 0.1, target: target, active: true)
        XCTAssertFalse(intent.yielded)
        XCTAssertTrue(intent.update(point: NSPoint(x: 200, y: 690), time: 1, target: target, active: true))
    }

    func testReferenceHidesOnApproachAndStaysAwayUntilPointerClearsIt() {
        var intent = ToolbarPointerIntent(mode: .reference)
        XCTAssertTrue(intent.update(point: NSPoint(x: 200, y: 570), time: 0, target: target, active: true))
        XCTAssertFalse(intent.update(point: NSPoint(x: 200, y: 625), time: 0.05, target: target, active: true))
        XCTAssertFalse(intent.update(point: NSPoint(x: 200, y: 715), time: 1, target: target, active: true))
        XCTAssertFalse(intent.update(point: NSPoint(x: 200, y: 660), time: 2, target: target, active: true))
        XCTAssertFalse(intent.update(point: NSPoint(x: 200, y: 400), time: 2.1, target: target, active: true))
        XCTAssertTrue(intent.update(point: NSPoint(x: 200, y: 400), time: 2.5, target: target, active: true))
    }

    func testUpwardAndDiagonalApproachesRevealBeforeArrival() {
        for x: CGFloat in [240, 450] {
            var intent = ToolbarPointerIntent()
            XCTAssertFalse(intent.update(point: NSPoint(x: x, y: 520), time: 0, target: target, active: true))
            XCTAssertTrue(intent.update(point: NSPoint(x: x - 40, y: 580), time: 0.05, target: target, active: true))
        }
    }

    func testParallelAwayAndWrongDestinationDoNotReveal() {
        for points in [
            [NSPoint(x: 180, y: 600), NSPoint(x: 250, y: 600)],
            [NSPoint(x: 180, y: 600), NSPoint(x: 180, y: 540)],
            [NSPoint(x: 700, y: 540), NSPoint(x: 700, y: 600)]
        ] {
            var intent = ToolbarPointerIntent()
            for (i, point) in points.enumerated() {
                XCTAssertFalse(intent.update(point: point, time: Double(i) * 0.05, target: target, active: true))
            }
        }
    }

    func testSlowProximityHoldAndInactiveReset() {
        var intent = ToolbarPointerIntent()
        XCTAssertTrue(intent.update(point: NSPoint(x: 180, y: 685), time: 1, target: target, active: true))
        XCTAssertTrue(intent.update(point: NSPoint(x: 500, y: 400), time: 1.3, target: target, active: true))
        XCTAssertFalse(intent.update(point: NSPoint(x: 500, y: 400), time: 1.6, target: target, active: true))
        XCTAssertTrue(intent.update(point: .zero, time: 2, target: target, active: true, interacting: true))
        XCTAssertFalse(intent.update(point: target.origin, time: 2.1, target: target, active: false))
        XCTAssertFalse(intent.update(point: .zero, time: 2.2, target: target, active: true))
    }

    func testStalePointerSampleDoesNotPredictAnApproach() {
        var intent = ToolbarPointerIntent()
        XCTAssertFalse(intent.update(point: NSPoint(x: 200, y: 520), time: 0, target: target, active: true))
        XCTAssertFalse(intent.update(point: NSPoint(x: 200, y: 600), time: 2, target: target, active: true))
    }

    func testHighFrequencyMouseSamplesStillPredictArrival() {
        var intent = ToolbarPointerIntent()
        for i in 0...16 {
            _ = intent.update(point: NSPoint(x: 200, y: 540 + i), time: Double(i) / 1000,
                              target: target, active: true)
        }
        XCTAssertTrue(intent.revealed)
    }
}
