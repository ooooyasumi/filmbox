import Foundation

/// A compact date overview, independent of the size of the media canvas.
/// Counts affect relative emphasis, while occupied months bound its length.
struct CompressedDateScale: Equatable {
    struct Input: Equatable {
        let start: Double
        let length: Double
        let date: Date
        let count: Int
        var end: Double { start + length }
    }

    struct Segment: Equatable {
        let start: Double
        let length: Double
        let rulerStart: Double
        let rulerLength: Double
        var end: Double { start + length }
        var rulerEnd: Double { rulerStart + rulerLength }
    }

    let segments: [Segment]
    let totalExtent: Double
    private let pieces: [Segment]

    init(inputs: [Input], totalLength: Double, monthlyExtent: Double = 84, magnification: Double = 1) {
        let extent = monthlyExtent.isFinite && monthlyExtent > 0 ? min(2048, max(1, monthlyExtent)) : 84
        let zoom = magnification.isFinite && magnification > 0 ? min(16, max(0.01, magnification)) : 1
        let sorted = inputs.filter {
            $0.start.isFinite && $0.length.isFinite && $0.length > 0 && $0.end.isFinite
        }.sorted { $0.start < $1.start }
        var valid: [Input] = []
        for input in sorted where valid.last.map({ input.start >= $0.end }) ?? true {
            valid.append(input)
        }
        guard let first = valid.first, let last = valid.last else {
            segments = []; pieces = []; totalExtent = 0
            return
        }

        let calendar = Calendar.current
        var monthKeys: [String] = []
        var countsByMonth: [String: Double] = [:]
        var weightsByMonth: [String: Double] = [:]
        var weights: [Double] = []
        for input in valid {
            let date = input.date.timeIntervalSinceReferenceDate.isFinite
                ? input.date : Date(timeIntervalSinceReferenceDate: 0)
            let components = calendar.dateComponents([.era, .year, .month], from: date)
            let key = "\(components.era ?? 1):\(components.year ?? 2001):\(components.month ?? 1)"
            monthKeys.append(key)
            let count = Double(max(1, input.count))
            let weight = 1 + min(1.25, 0.16 * log2(count))
            countsByMonth[key, default: 0] += count
            weightsByMonth[key, default: 0] += weight
            // Within a month, a 2,000-photo day is at most 2.25 times
            // a one-photo day. Busy recent years cannot consume past years.
            weights.append(weight)
        }
        var mapped: [Segment] = []
        var all: [Segment] = []
        var sourceCursor = min(0, first.start)
        var rulerCursor = 0.0
        // Layout gutters retain an invertible mapping without stretching the
        // overview. Their length is capped independently of document pixels.
        let gapExtent = min(4, extent * zoom * 0.04)
        func appendGap(to end: Double) {
            guard end > sourceCursor else { return }
            let gap = Segment(start: sourceCursor, length: end - sourceCursor,
                              rulerStart: rulerCursor, rulerLength: gapExtent)
            all.append(gap); rulerCursor = gap.rulerEnd; sourceCursor = end
        }
        for (index, input) in valid.enumerated() {
            appendGap(to: input.start)
            let key = monthKeys[index]
            let density = 1 + min(0.5, 0.08 * log2(max(1, countsByMonth[key, default: 1])))
            let budget = extent * zoom * density
            let segment = Segment(start: input.start, length: input.length,
                                  rulerStart: rulerCursor,
                                  rulerLength: budget * weights[index] / weightsByMonth[key, default: 1])
            mapped.append(segment); all.append(segment)
            sourceCursor = input.end; rulerCursor = segment.rulerEnd
        }
        appendGap(to: max(last.end, totalLength.isFinite ? totalLength : last.end))
        segments = mapped; pieces = all; totalExtent = rulerCursor
    }

    func coordinate(for position: Double) -> Double {
        guard let first = pieces.first, let last = pieces.last else { return 0 }
        let value = position.isFinite ? min(last.end, max(first.start, position)) : first.start
        let segment = pieces[index(at: value, ruler: false)]
        return segment.rulerStart + (value - segment.start) / segment.length * segment.rulerLength
    }

    func position(at coordinate: Double) -> Double {
        guard let first = pieces.first, let last = pieces.last else { return 0 }
        let value = coordinate.isFinite ? min(totalExtent, max(0, coordinate)) : 0
        if value >= totalExtent { return last.end }
        if value <= 0 { return first.start }
        let segment = pieces[index(at: value, ruler: true)]
        return segment.start + (value - segment.rulerStart) / segment.rulerLength * segment.length
    }

    private func index(at value: Double, ruler: Bool) -> Int {
        var low = 0, high = pieces.count
        while low < high {
            let middle = (low + high) / 2
            let start = ruler ? pieces[middle].rulerStart : pieces[middle].start
            if start <= value { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }
}
