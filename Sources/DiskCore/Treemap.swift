import Foundation
import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing, van Wijk).
///
/// Given weights (expected sorted descending for best aspect ratios) and a
/// bounding rect, returns one rect per weight, in the same order. Areas are
/// proportional to weights; rects tile the bounds without overlap.
public enum Treemap {
    public static func layout(values: [Double], in bounds: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, bounds.width > 0, bounds.height > 0 else {
            return values.map { _ in .zero }
        }
        let scale = Double(bounds.width * bounds.height) / total
        let areas = values.map { max(0, $0) * scale }

        var result = [CGRect](repeating: .zero, count: values.count)
        var remaining = bounds
        var start = 0

        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else { break }

            // Grow the row while doing so improves the worst aspect ratio.
            var end = start
            var rowSum = areas[start]
            var rowMin = areas[start]
            var rowMax = areas[start]
            var worst = worstAspect(sum: rowSum, minA: rowMin, maxA: rowMax, side: side)
            while end + 1 < areas.count {
                let a = areas[end + 1]
                let newWorst = worstAspect(
                    sum: rowSum + a, minA: min(rowMin, a), maxA: max(rowMax, a), side: side)
                if newWorst > worst { break }
                end += 1
                rowSum += a
                rowMin = min(rowMin, a)
                rowMax = max(rowMax, a)
                worst = newWorst
            }

            // Lay the row along the shorter side of the remaining area.
            if remaining.width >= remaining.height {
                let stripWidth = remaining.height > 0 ? CGFloat(rowSum) / remaining.height : 0
                var y = remaining.minY
                for i in start...end {
                    let h = stripWidth > 0 ? CGFloat(areas[i]) / stripWidth : 0
                    result[i] = CGRect(x: remaining.minX, y: y, width: stripWidth, height: h)
                    y += h
                }
                remaining.origin.x += stripWidth
                remaining.size.width -= stripWidth
            } else {
                let stripHeight = remaining.width > 0 ? CGFloat(rowSum) / remaining.width : 0
                var x = remaining.minX
                for i in start...end {
                    let w = stripHeight > 0 ? CGFloat(areas[i]) / stripHeight : 0
                    result[i] = CGRect(x: x, y: remaining.minY, width: w, height: stripHeight)
                    x += w
                }
                remaining.origin.y += stripHeight
                remaining.size.height -= stripHeight
            }
            start = end + 1
        }
        return result
    }

    private static func worstAspect(sum: Double, minA: Double, maxA: Double, side: Double) -> Double {
        guard sum > 0, minA > 0 else { return .infinity }
        let s2 = sum * sum
        let w2 = side * side
        return max(w2 * maxA / s2, s2 / (w2 * minA))
    }
}
