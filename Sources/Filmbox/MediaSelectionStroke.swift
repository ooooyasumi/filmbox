import Foundation

/// A pointer stroke selects only the media it crosses. Testing each segment
/// also catches photos skipped between two delivered mouse events.
struct MediaSelectionStroke {
    private(set) var lastPoint: CGPoint
    private(set) var visitedIDs: Set<String> = []

    init(at point: CGPoint) { lastPoint = point }

    func searchRect(to point: CGPoint) -> CGRect {
        CGRect(x: min(lastPoint.x, point.x) - 0.5,
               y: min(lastPoint.y, point.y) - 0.5,
               width: abs(point.x - lastPoint.x) + 1,
               height: abs(point.y - lastPoint.y) + 1)
    }

    mutating func advance(to point: CGPoint, candidates: [(id: String, frame: CGRect)]) -> Set<String> {
        guard point.x.isFinite, point.y.isFinite,
              lastPoint.x.isFinite, lastPoint.y.isFinite else { return [] }
        var added: Set<String> = []
        for candidate in candidates where !visitedIDs.contains(candidate.id) {
            if Self.intersects(from: lastPoint, to: point, rect: candidate.frame) {
                visitedIDs.insert(candidate.id)
                added.insert(candidate.id)
            }
        }
        lastPoint = point
        return added
    }

    private static func intersects(from start: CGPoint, to end: CGPoint, rect: CGRect) -> Bool {
        guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0 else { return false }
        let dx = end.x - start.x, dy = end.y - start.y
        var first: CGFloat = 0, last: CGFloat = 1
        // Clip the segment against all four sides of the photo rectangle.
        for (direction, distance) in [(-dx, start.x - rect.minX), (dx, rect.maxX - start.x),
                                      (-dy, start.y - rect.minY), (dy, rect.maxY - start.y)] {
            if direction == 0 {
                if distance < 0 { return false }
            } else {
                let fraction = distance / direction
                if direction < 0 { first = max(first, fraction) }
                else { last = min(last, fraction) }
                if first > last { return false }
            }
        }
        return true
    }
}
