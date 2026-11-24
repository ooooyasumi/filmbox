import Foundation

/// Visible labels own the main marks. Unlabelled dates may add a quiet short
/// mark only when there is room; no decorative ticks imply invented dates.
enum QuietDateRulerTicks {
    struct Anchor: Equatable {
        let index: Int
        let position: Double
    }
    struct Tick: Equatable {
        let index: Int
        let position: Double
        let isMajor: Bool
    }

    static func layout(dateAnchors: [Anchor], labelAnchors: [Anchor], lower: Double, upper: Double,
                       minimumSpacing: Double = 22) -> [Tick] {
        guard lower.isFinite, upper.isFinite, lower <= upper else { return [] }
        let spacing = minimumSpacing.isFinite && minimumSpacing > 0 ? max(1, minimumSpacing) : 22
        let labelledIndices = Set(labelAnchors.map(\.index))
        var seen = Set<Int>()
        var ticks = labelAnchors.filter {
            $0.position.isFinite && lower...upper ~= $0.position && seen.insert($0.index).inserted
        }.map { Tick(index: $0.index, position: $0.position, isMajor: true) }
        var occupied = ticks.map(\.position).sorted()
        let dates = dateAnchors.filter { $0.position.isFinite && lower...upper ~= $0.position }
        for date in dates.sorted(by: { $0.position < $1.position }) {
            guard !labelledIndices.contains(date.index), seen.insert(date.index).inserted else { continue }
            var low = 0, high = occupied.count
            while low < high {
                let middle = (low + high) / 2
                if occupied[middle] < date.position { low = middle + 1 } else { high = middle }
            }
            guard (low == 0 || date.position - occupied[low - 1] >= spacing),
                  (low == occupied.count || occupied[low] - date.position >= spacing) else { continue }
            ticks.append(Tick(index: date.index, position: date.position, isMajor: false))
            occupied.insert(date.position, at: low)
        }
        return ticks.sorted { $0.position < $1.position }
    }
}
