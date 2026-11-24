import FilmboxCore
import Foundation

func temporalZoomBandsAggregateStably() throws {
    let calendar = timelineCalendar()
    let items = [
        timelineItem(0, date: timelineDate("2024-06-18T10:00:00+08:00")),
        timelineItem(1, date: timelineDate("2024-06-19T10:00:00+08:00")),
        timelineItem(2, date: timelineDate("2024-06-24T10:00:00+08:00")),
        timelineItem(3, date: timelineDate("2024-07-01T10:00:00+08:00"))
    ]
    for height in 64...280 {
        let expected: TimelineScale = height < 104 ? .month : (height < 170 ? .week : .day)
        try expect(TimelineScale(targetRowHeight: Double(height)) == expected)
        let actual = TimelineGrouping.sections(for: items, scale: TimelineScale(targetRowHeight: Double(height)), calendar: calendar)
        let baseline = TimelineGrouping.sections(for: items, scale: expected, calendar: calendar)
        try expect(actual.map(\.id) == baseline.map(\.id))
        try expect(actual.flatMap(\.items).map(\.id) == baseline.flatMap(\.items).map(\.id))
    }
    try expect(TimelineScale(targetRowHeight: 103.999) == .month)
    try expect(TimelineScale(targetRowHeight: 104) == .week)
    try expect(TimelineScale(targetRowHeight: 169.999) == .week)
    try expect(TimelineScale(targetRowHeight: 170) == .day)
    let day = TimelineGrouping.sections(for: items, scale: .day, calendar: calendar)
    let week = TimelineGrouping.sections(for: items, scale: .week, calendar: calendar)
    let month = TimelineGrouping.sections(for: items, scale: .month, calendar: calendar)
    try expect(day.count == 4 && week.count == 3 && month.count == 2)
    try expect(Set(day.flatMap(\.items).map(\.id)) == Set(month.flatMap(\.items).map(\.id)))
}

func temporalDayGroupingPreservesInputOrderAndUsesExclusiveEnds() throws {
    let calendar = timelineCalendar()
    let items = [
        timelineItem(0, date: timelineDate("2024-06-18T20:00:00+08:00")),
        timelineItem(1, date: timelineDate("2024-06-17T20:00:00+08:00")),
        timelineItem(2, date: timelineDate("2024-06-18T08:00:00+08:00")),
        timelineItem(3, date: timelineDate("2024-06-19T00:00:00+08:00"))
    ]
    let descending = TimelineGrouping.sections(for: items, scale: .day, calendar: calendar)
    try expect(descending.map { $0.items.map(\.id) } == [[items[3].id], [items[0].id, items[2].id], [items[1].id]])
    try expect(descending[1].title == "2024年6月18日 周二")
    try expect(descending[1].startDate == timelineDate("2024-06-18T00:00:00+08:00"))
    try expect(descending[1].endDate == timelineDate("2024-06-19T00:00:00+08:00"))
    let ascending = TimelineGrouping.sections(for: items, scale: .day, descending: false, calendar: calendar)
    try expect(ascending.map(\.id) == descending.reversed().map(\.id))
    try expect(ascending[1].items.map(\.id) == [items[0].id, items[2].id])
    for section in descending {
        try expect(section.items.allSatisfy { $0.displayDate >= section.startDate && $0.displayDate < section.endDate })
    }
}

func temporalWeeksAndMonthsHandleYearBoundaries() throws {
    let calendar = timelineCalendar()
    let items = [
        timelineItem(0, date: timelineDate("2024-12-30T12:00:00+08:00")),
        timelineItem(1, date: timelineDate("2025-01-01T12:00:00+08:00")),
        timelineItem(2, date: timelineDate("2025-01-05T23:59:59+08:00")),
        timelineItem(3, date: timelineDate("2025-01-06T00:00:00+08:00"))
    ]
    let weeks = TimelineGrouping.sections(for: items, scale: .week, descending: false, calendar: calendar)
    try expect(weeks.count == 2)
    try expect(weeks[0].items.map(\.id) == Array(items[0...2]).map(\.id))
    try expect(weeks[0].startDate == timelineDate("2024-12-30T00:00:00+08:00"))
    try expect(weeks[0].endDate == timelineDate("2025-01-06T00:00:00+08:00"))
    try expect(weeks[0].title == "2024年12月30日—2025年1月5日")
    let months = TimelineGrouping.sections(for: items, scale: .month, descending: false, calendar: calendar)
    try expect(months.map(\.title) == ["2024年12月", "2025年1月"])
    try expect(months[1].items.map(\.id) == Array(items[1...3]).map(\.id))
    let ordinary = TimelineGrouping.sections(
        for: [timelineItem(4, date: timelineDate("2024-06-18T12:00:00+08:00"))],
        scale: .week, calendar: calendar
    )
    try expect(ordinary.first?.title == "6月17日—23日")
}

func temporalGroupingUsesCalendarAcrossDaylightSavingChanges() throws {
    let calendar = timelineCalendar(timeZone: "America/Los_Angeles")
    let spring = [
        timelineItem(0, date: timelineDate("2024-03-10T01:30:00-08:00")),
        timelineItem(1, date: timelineDate("2024-03-10T03:30:00-07:00"))
    ]
    let day = try require(TimelineGrouping.sections(for: spring, scale: .day, calendar: calendar).first)
    try expect(day.items.count == 2 && day.endDate.timeIntervalSince(day.startDate) == 23 * 3_600)
    try expect(day.startDate == timelineDate("2024-03-10T00:00:00-08:00"))
    try expect(day.endDate == timelineDate("2024-03-11T00:00:00-07:00"))
    let week = try require(TimelineGrouping.sections(for: spring, scale: .week, calendar: calendar).first)
    try expect(week.endDate.timeIntervalSince(week.startDate) == 167 * 3_600)
    let month = try require(TimelineGrouping.sections(for: spring, scale: .month, calendar: calendar).first)
    try expect(month.endDate.timeIntervalSince(month.startDate) == 743 * 3_600)
    let autumn = [
        timelineItem(2, date: timelineDate("2024-11-03T01:30:00-07:00")),
        timelineItem(3, date: timelineDate("2024-11-03T01:30:00-08:00"))
    ]
    let longDay = try require(TimelineGrouping.sections(for: autumn, scale: .day, calendar: calendar).first)
    try expect(longDay.items.count == 2 && longDay.endDate.timeIntervalSince(longDay.startDate) == 25 * 3_600)
}

func temporalDateBasisSelectsRequestedMetadataAndCaptureFallback() throws {
    let calendar = timelineCalendar()
    let captured = timelineDate("2024-06-18T12:00:00+08:00")
    let created = timelineDate("2024-07-02T12:00:00+08:00")
    let modified = timelineDate("2024-08-03T12:00:00+08:00")
    let item = MediaItem(url: URL(fileURLWithPath: "/Fixtures/date.jpg"), kind: .image, fileSize: 1,
                         modifiedDate: modified, createdDate: created, capturedDate: captured)
    try expect(TimelineGrouping.sections(for: [item], scale: .month, dateBasis: .captured, calendar: calendar).first?.title == "2024年6月")
    try expect(TimelineGrouping.sections(for: [item], scale: .month, dateBasis: .created, calendar: calendar).first?.title == "2024年7月")
    try expect(TimelineGrouping.sections(for: [item], scale: .month, dateBasis: .modified, calendar: calendar).first?.title == "2024年8月")
    let noExif = MediaItem(url: URL(fileURLWithPath: "/Fixtures/no-exif.jpg"), kind: .image, fileSize: 1,
                           modifiedDate: modified, createdDate: created)
    try expect(TimelineGrouping.sections(for: [noExif], scale: .month, calendar: calendar).first?.title == "2024年7月")
}

func temporalLayoutPreservesRatiosBoundsAndOrderAtFourWindowWidths() throws {
    let calendar = timelineCalendar()
    let dimensions: [(Int?, Int?)] = [(6000, 4000), (4000, 6000), (12000, 2000), (1000, 1500), (1, 100_000), (100_000, 1), (nil, nil), (0, 500)]
    let items = (0..<120).map { index in
        let dimensions = dimensions[index % dimensions.count]
        return timelineItem(index, date: Date(timeIntervalSince1970: 1_718_000_000 + Double(index / 12) * 86_400), width: dimensions.0, height: dimensions.1)
    }
    for width in [320.0, 768, 1280, 1920] {
        for target in [64.0, 104, 169, 170, 280] {
            let sections = TimelineGrouping.sections(for: items, scale: TimelineScale(targetRowHeight: target), calendar: calendar)
            let layout = JustifiedTimelineLayout.make(sections: sections, width: width, targetHeight: target)
            try validateTimelineLayout(layout, source: sections, width: width)
        }
    }
}

func temporalLayoutHandlesNarrowWindowsExtremeRatiosAndDensePortraits() throws {
    let date = timelineDate("2024-06-18T12:00:00+08:00")
    let extremes = [
        timelineItem(0, date: date, width: Int.max, height: 1),
        timelineItem(1, date: date, width: 1, height: Int.max),
        timelineItem(2, date: date, width: 1, height: 1),
        timelineItem(3, date: date, width: nil, height: 1)
    ]
    let sections = TimelineGrouping.sections(for: extremes, scale: .day)
    for width in [1.0, 20, 39, 64, 1280] {
        let layout = JustifiedTimelineLayout.make(sections: sections, width: width, targetHeight: 180)
        try validateTimelineLayout(layout, source: sections, width: width)
    }
    let portraits = (0..<300).map { timelineItem($0, date: date, width: 1, height: 1_000_000) }
    let portraitSections = TimelineGrouping.sections(for: portraits, scale: .day)
    let portraitLayout = JustifiedTimelineLayout.make(sections: portraitSections, width: 300, targetHeight: 180)
    try validateTimelineLayout(portraitLayout, source: portraitSections, width: 300)
    try expect(portraitLayout.sections[0].items.last!.frame.minY > portraitLayout.sections[0].items.first!.frame.minY)
    for width in [0.0, -1, Double.nan, .infinity] {
        let layout = JustifiedTimelineLayout.make(sections: sections, width: width, targetHeight: 180)
        try expect(layout.sections.isEmpty && layout.contentHeight == 0)
    }
}

func temporalLayoutKeepsShortRowsNaturalAndPanoramasIndependent() throws {
    let date = timelineDate("2024-06-18T12:00:00+08:00")
    let items = [timelineItem(0, date: date, width: 1, height: 1), timelineItem(1, date: date, width: 2, height: 3)]
    let sections = TimelineGrouping.sections(for: items, scale: .day)
    let layout = JustifiedTimelineLayout.make(sections: sections, width: 1200, targetHeight: 170)
    try validateTimelineLayout(layout, source: sections, width: 1200)
    try expect(layout.sections[0].items.allSatisfy { abs($0.frame.height - 170) < 0.000_001 })
    try expect(layout.sections[0].items.last!.frame.maxX < 400)
    let withPanorama = [items[0], timelineItem(2, date: date, width: 100_000, height: 1), items[1]]
    let panoramaSections = TimelineGrouping.sections(for: withPanorama, scale: .day)
    let panoramaLayout = JustifiedTimelineLayout.make(sections: panoramaSections, width: 1200, targetHeight: 170)
    try validateTimelineLayout(panoramaLayout, source: panoramaSections, width: 1200)
    let frames = panoramaLayout.sections[0].items
    try expect(abs(frames[0].frame.height - 170) < 0.000_001)
    try expect(abs(frames[2].frame.height - 170) < 0.000_001)
    try expect(frames[0].frame.maxY <= frames[1].frame.minY && frames[1].frame.maxY <= frames[2].frame.minY)
}

private func validateTimelineLayout(_ layout: TimelineLayout, source: [TemporalSection], width: Double) throws {
    let epsilon = 0.000_001
    try expect(layout.contentHeight.isFinite && layout.contentHeight >= 0)
    try expect(layout.sections.map(\.id) == source.map(\.id))
    let expectedItems = source.flatMap(\.items)
    let actualFrames = layout.sections.flatMap(\.items)
    try expect(actualFrames.map(\.id) == expectedItems.map(\.id))
    for (item, itemFrame) in zip(expectedItems, actualFrames) {
        let frame = itemFrame.frame
        let ratio = item.aspectRatio ?? 1.5
        try expect(frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0)
        try expect(abs(frame.width / frame.height - ratio) <= max(0.000_000_000_001, ratio * 0.000_000_000_001))
        try expect(frame.minX >= 0 && frame.maxX <= width + epsilon)
        try expect(frame.minY >= 0 && frame.maxY <= layout.contentHeight + epsilon)
    }
    var previousBottom = 0.0
    for section in layout.sections {
        try expect(section.headerFrame.minX >= 0 && section.headerFrame.maxX <= width + epsilon)
        try expect(section.headerFrame.minY + epsilon >= previousBottom)
        for item in section.items { try expect(item.frame.minY + epsilon >= section.headerFrame.maxY) }
        previousBottom = max(section.headerFrame.maxY, section.items.map(\.frame.maxY).max() ?? 0)
        for first in section.items.indices {
            for second in section.items.indices where second > first {
                let a = section.items[first].frame
                let b = section.items[second].frame
                let overlapsX = min(a.maxX, b.maxX) - max(a.minX, b.minX) > epsilon
                let overlapsY = min(a.maxY, b.maxY) - max(a.minY, b.minY) > epsilon
                try expect(!(overlapsX && overlapsY))
            }
        }
    }
}

private func timelineCalendar(timeZone: String = "Asia/Shanghai") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "zh_CN")
    calendar.timeZone = TimeZone(identifier: timeZone)!
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
}

private func timelineDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private func timelineItem(_ index: Int, date: Date, width: Int? = 6000, height: Int? = 4000) -> MediaItem {
    MediaItem(
        url: URL(fileURLWithPath: "/Fixtures/timeline/\(index).jpg"), kind: .image, fileSize: 1,
        modifiedDate: date, createdDate: date, capturedDate: date, pixelWidth: width, pixelHeight: height
    )
}
