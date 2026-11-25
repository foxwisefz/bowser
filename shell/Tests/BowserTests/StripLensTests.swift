import XCTest
@testable import Bowser

final class StripLensTests: XCTestCase {
    func testFocusStaysUnderPointerAndNeighborsOpenSymmetrically() {
        let lens = StripLens(focus: 200, strength: 1, radius: 100, magnification: 1.4)
        XCTAssertEqual(lens.map(200), 200)
        XCTAssertEqual(lens.row(center: 200, size: 32).offset, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(lens.row(center: 200, size: 32).scale, 1.38)
        XCTAssertLessThan(lens.map(160), 160)
        XCTAssertGreaterThan(lens.map(240), 240)
        XCTAssertEqual(200 - lens.map(160), lens.map(240) - 200, accuracy: 0.0001)
    }

    func testRowsNeverOverlapOrShrinkAcrossContinuousSweep() {
        for focus in stride(from: CGFloat(-100), through: 500, by: 0.5) {
            let lens = StripLens(focus: focus, strength: 1, radius: 100, magnification: 3)
            for index in 0..<10 {
                let center = CGFloat(index) * 40 + 16
                let row = lens.row(center: center, size: 32)
                let next = lens.row(center: center + 40, size: 32)
                let gap = center + 40 + next.offset - next.scale * 16 - (center + row.offset + row.scale * 16)
                XCTAssertGreaterThanOrEqual(gap, 8 - 0.0001)
                XCTAssertGreaterThanOrEqual(row.scale, 1 - 0.0001)
                XCTAssertLessThanOrEqual(abs(row.offset), lens.reach + 0.0001)
            }
        }
    }

    func testMotionOffRestoresExactBaselineAndScrollCoordinatesTranslate() {
        let still = StripLens(focus: 115, strength: 0, radius: 100, magnification: 1.4)
        XCTAssertEqual(still.row(center: 80, size: 32).scale, 1)
        XCTAssertEqual(still.row(center: 80, size: 32).offset, 0)
        let lens = StripLens(focus: 115, strength: 1, radius: 100, magnification: 1.4)
        let scrolled = StripLens(focus: 65, strength: 1, radius: 100, magnification: 1.4)
        XCTAssertEqual(lens.row(center: 80, size: 32).scale,
                       scrolled.row(center: 30, size: 32).scale, accuracy: 0.0001)
        XCTAssertEqual(lens.row(center: 80, size: 32).offset,
                       scrolled.row(center: 30, size: 32).offset, accuracy: 0.0001)
    }

    func testFalloffHasNoVelocityKinksAtFocusOrRadius() {
        let lens = StripLens(focus: 0, strength: 1, radius: 100, magnification: 1.4)
        let step: CGFloat = 0.01
        for position: CGFloat in [-100, 0, 100] {
            let left = (lens.map(position) - lens.map(position - step)) / step
            let right = (lens.map(position + step) - lens.map(position)) / step
            XCTAssertEqual(left, right, accuracy: 0.0001)
        }
    }
}
