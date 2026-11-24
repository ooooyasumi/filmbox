import Foundation

public enum TimelineScale: String, CaseIterable, Sendable {
    case day
    case week
    case month

    public init(targetRowHeight: Double) {
        if targetRowHeight < 104 { self = .month }
        else if targetRowHeight < 170 { self = .week }
        else { self = .day }
    }
}

public enum TimelineDateBasis: Sendable {
    case captured
    case created
    case modified
}

public struct TemporalSection: Identifiable, Sendable {
    public let id: String
    public let startDate: Date
    public let endDate: Date
    public let title: String
    public let items: [MediaItem]

    public init(id: String, startDate: Date, endDate: Date, title: String, items: [MediaItem]) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.title = title
        self.items = items
    }
}

public enum TimelineGrouping {
    public static func sections(
        for items: [MediaItem],
        scale: TimelineScale,
        dateBasis: TimelineDateBasis = .captured,
        descending: Bool = true,
        calendar: Calendar = .current
    ) -> [TemporalSection] {
        let component: Calendar.Component = switch scale {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        var grouped: [Date: [MediaItem]] = [:]
        var intervals: [Date: DateInterval] = [:]
        for item in items {
            let date: Date = switch dateBasis {
            case .captured: item.displayDate
            case .created: item.createdDate
            case .modified: item.modifiedDate
            }
            let interval = calendar.dateInterval(of: component, for: date)
                ?? fallbackInterval(for: date, calendar: calendar)
            grouped[interval.start, default: []].append(item)
            intervals[interval.start] = interval
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return grouped.keys.sorted { descending ? $0 > $1 : $0 < $1 }.map { start in
            let interval = intervals[start]!
            return TemporalSection(
                id: "\(scale.rawValue):\(start.timeIntervalSinceReferenceDate)",
                startDate: interval.start,
                endDate: interval.end,
                title: title(for: interval, scale: scale, calendar: calendar, formatter: formatter),
                items: grouped[start]!
            )
        }
    }

    private static func fallbackInterval(for date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    private static func title(for interval: DateInterval, scale: TimelineScale, calendar: Calendar, formatter: DateFormatter) -> String {
        switch scale {
        case .day:
            formatter.dateFormat = "yyyy年M月d日 EEE"
            return formatter.string(from: interval.start)
        case .month:
            formatter.dateFormat = "yyyy年M月"
            return formatter.string(from: interval.start)
        case .week:
            // Subtract a calendar day, never 86,400 seconds: DST weeks vary in length.
            let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
            if calendar.component(.year, from: interval.start) != calendar.component(.year, from: lastDay) {
                formatter.dateFormat = "yyyy年M月d日"
                return formatter.string(from: interval.start) + "—" + formatter.string(from: lastDay)
            }
            formatter.dateFormat = "M月d日"
            let start = formatter.string(from: interval.start)
            if calendar.component(.month, from: interval.start) == calendar.component(.month, from: lastDay) {
                formatter.dateFormat = "d日"
            }
            return start + "—" + formatter.string(from: lastDay)
        }
    }
}

public struct TimelineItemFrame: Identifiable, Sendable {
    public let id: String
    public let frame: CGRect

    public init(id: String, frame: CGRect) { self.id = id; self.frame = frame }
}

public struct TimelineSectionFrame: Identifiable, Sendable {
    public let id: String
    public let headerFrame: CGRect
    public let items: [TimelineItemFrame]

    public init(id: String, headerFrame: CGRect, items: [TimelineItemFrame]) {
        self.id = id
        self.headerFrame = headerFrame
        self.items = items
    }
}

public struct TimelineLayout: Sendable {
    public let sections: [TimelineSectionFrame]
    public let contentHeight: Double

    public init(sections: [TimelineSectionFrame], contentHeight: Double) {
        self.sections = sections
        self.contentHeight = contentHeight
    }
}

public enum JustifiedTimelineLayout {
    public static func make(
        sections: [TemporalSection],
        width: Double,
        targetHeight: Double,
        gap: Double = 6,
        padding: Double = 20,
        headerHeight: Double = 42,
        sectionSpacing: Double = 20
    ) -> TimelineLayout {
        guard width.isFinite, width > 0, !sections.isEmpty else {
            return TimelineLayout(sections: [], contentHeight: 0)
        }
        let padding = min(nonnegative(padding), width / 4)
        let available = width - padding * 2
        let gap = nonnegative(gap)
        let target = targetHeight.isFinite && targetHeight > 0 ? targetHeight : 170
        let headerHeight = nonnegative(headerHeight)
        let sectionSpacing = nonnegative(sectionSpacing)
        var y = padding
        var result: [TimelineSectionFrame] = []

        for (sectionIndex, section) in sections.enumerated() {
            let header = CGRect(x: padding, y: y, width: available, height: headerHeight)
            y += headerHeight
            var frames: [TimelineItemFrame] = []
            let entries = section.items.map { Entry(id: $0.id, ratio: $0.aspectRatio ?? ($0.isLocal ? 1.5 : 1)) }
            let rows = rows(for: entries, available: available, target: target, gap: gap)
            for (rowIndex, row) in rows.enumerated() {
                let ratioSum = row.entries.reduce(0) { $0 + $1.ratio }
                let availableForImages = max(0, available - gap * Double(row.entries.count - 1))
                let fittingHeight = availableForImages / ratioSum
                var height = row.justified ? fittingHeight : min(target, fittingHeight)
                // Keep every width proportional to the same height. Leave only a few
                // floating-point ulps at the right edge instead of cropping a final image.
                height *= max(0, 1 - Double.ulpOfOne * Double(row.entries.count + 2))
                var x = padding
                for entry in row.entries {
                    let imageWidth = entry.ratio * height
                    frames.append(TimelineItemFrame(id: entry.id, frame: CGRect(x: x, y: y, width: imageWidth, height: height)))
                    x += imageWidth + gap
                }
                y += height
                if rowIndex + 1 < rows.count { y += gap }
            }
            result.append(TimelineSectionFrame(id: section.id, headerFrame: header, items: frames))
            if sectionIndex + 1 < sections.count { y += sectionSpacing }
        }
        return TimelineLayout(sections: result, contentHeight: y + padding)
    }

    private static func nonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private struct Entry {
        let id: String
        let ratio: Double
    }

    private struct Row {
        let entries: [Entry]
        let justified: Bool
    }

    private static func rows(for entries: [Entry], available: Double, target: Double, gap: Double) -> [Row] {
        var rows: [Row] = []
        var pending: [Entry] = []
        var ratioSum = 0.0
        for entry in entries {
            if entry.ratio * target >= available {
                // A panorama gets its own fitting row rather than reducing its neighbours
                // to slivers. A preceding short row keeps its natural viewing height.
                if !pending.isEmpty { rows.append(Row(entries: pending, justified: false)) }
                rows.append(Row(entries: [entry], justified: true))
                pending = []; ratioSum = 0
                continue
            }
            if pending.isEmpty {
                pending = [entry]; ratioSum = entry.ratio
                continue
            }
            let gapsWithEntry = gap * Double(pending.count)
            if gapsWithEntry >= available {
                rows.append(Row(entries: pending, justified: false))
                pending = [entry]; ratioSum = entry.ratio
                continue
            }
            let projectedWidth = (ratioSum + entry.ratio) * target + gapsWithEntry
            if projectedWidth < available {
                pending.append(entry); ratioSum += entry.ratio
                continue
            }
            let heightWithEntry = (available - gapsWithEntry) / (ratioSum + entry.ratio)
            let heightWithoutEntry = (available - gap * Double(pending.count - 1)) / ratioSum
            if abs(heightWithoutEntry - target) < abs(heightWithEntry - target) {
                rows.append(Row(entries: pending, justified: true))
                pending = [entry]; ratioSum = entry.ratio
            } else {
                pending.append(entry)
                rows.append(Row(entries: pending, justified: true))
                pending = []; ratioSum = 0
            }
        }
        if !pending.isEmpty { rows.append(Row(entries: pending, justified: false)) }
        return rows
    }
}
