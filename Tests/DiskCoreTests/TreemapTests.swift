import XCTest
@testable import DiskCore

final class TreemapTests: XCTestCase {
    func testAreasProportionalToValues() {
        let values: [Double] = [6, 3, 1]
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rects = Treemap.layout(values: values, in: bounds)

        XCTAssertEqual(rects.count, 3)
        let expected: [Double] = [6000, 3000, 1000]
        for (rect, area) in zip(rects, expected) {
            XCTAssertEqual(Double(rect.width * rect.height), area, accuracy: 1.0)
        }
    }

    func testRectsStayWithinBounds() {
        let values: [Double] = [50, 30, 10, 5, 3, 1, 0.5]
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 180)
        let rects = Treemap.layout(values: values, in: bounds)
        for rect in rects {
            XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX - 0.001)
            XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY - 0.001)
            XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + 0.001)
            XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + 0.001)
        }
    }

    func testRectsDoNotOverlap() {
        let values: [Double] = [40, 25, 15, 10, 5, 3, 2]
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 120)
        let rects = Treemap.layout(values: values, in: bounds)
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                let overlap = rects[i].intersection(rects[j])
                let area = overlap.isNull ? 0 : Double(overlap.width * overlap.height)
                XCTAssertLessThan(area, 0.01, "rects \(i) and \(j) overlap by \(area)")
            }
        }
    }

    func testTotalAreaCoversBounds() {
        let values: [Double] = [7, 5, 3, 2, 1]
        let bounds = CGRect(x: 0, y: 0, width: 90, height: 60)
        let rects = Treemap.layout(values: values, in: bounds)
        let total = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        XCTAssertEqual(total, 5400, accuracy: 1.0)
    }

    func testZeroAndEmptyInputs() {
        XCTAssertEqual(Treemap.layout(values: [], in: CGRect(x: 0, y: 0, width: 10, height: 10)), [])
        let zeros = Treemap.layout(values: [0, 0], in: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(zeros, [.zero, .zero])
        let degenerate = Treemap.layout(values: [1, 2], in: .zero)
        XCTAssertEqual(degenerate, [.zero, .zero])
    }
}
