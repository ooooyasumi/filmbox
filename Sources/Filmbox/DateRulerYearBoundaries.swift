import Foundation

/// A year is repeated only at a real transition inside the viewport. The
/// caption names the year on the side away from the current date, in either
/// sort direction. Inspect visible neighbours rather than the whole library.
enum DateRulerYearBoundaries {
    struct Marker: Equatable {
        let index: Int
        let year: String
        let position: Double
    }
    static func layout(indices: Range<Int>, activeIndex: Int, lower: Double, upper: Double,
                       yearAt: (Int) -> String, positionAt: (Int) -> Double) -> [Marker] {
        indices.compactMap { index in
            guard index > 0, yearAt(index - 1) != yearAt(index) else { return nil }
            let position = positionAt(index)
            guard position.isFinite, position > lower, position < upper else { return nil }
            return Marker(index: index, year: yearAt(index <= activeIndex ? index - 1 : index), position: position)
        }
    }
}
