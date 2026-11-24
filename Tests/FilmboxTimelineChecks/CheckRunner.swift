import AppKit
import Foundation
import FilmboxCore
@testable import Filmbox

/// Validate the real ruler and measured grid layout in a hidden native window.
/// Events call the view's handlers directly; nothing is posted to the system.
@main @MainActor
private struct TimelineChecks {
    static var passed = 0
    static func main() async {
        do {
            _ = NSApplication.shared
            try measuredGeometry()
            try compressedScaleBoundaries()
            try continuousProjection()
            try geometryBoundaries()
            try nativeViewInteraction()
            try nativeLabelHitTargets()
            try quietNativeTicks()
            try nativeYearBoundaries()
            try await nativeWheelInteraction()
            try nativeDrawingBounds()
            try largeAndEmptyLibraries()
            print("连续日期尺检查 \(passed) 项通过")
        } catch {
            print("FAIL \(error)"); exit(EXIT_FAILURE)
        }
    }

    static func measuredGeometry() throws {
        let sections = makeSections(counts: [1, 60, 3])
        let layout = JustifiedTimelineLayout.make(sections: sections, width: 900, targetHeight: 180)
        let spans = spans(for: layout)
        let geometry = LineDateRulerGeometry(spans: spans, position: 0, totalLength: layout.contentHeight, sections: sections)
        try check(geometry.spans.count == 3 && geometry.spans[1].length > geometry.spans[0].length * 6,
                  "真实网格几何保留 60 张照片的长日期区间，导航定位不受压缩影响")
        let firstLength = projectedLength(geometry, at: 0)
        let manyLength = projectedLength(geometry, at: 1)
        try check(manyLength > firstLength && manyLength / firstLength < 2.25,
                  "同月 60 张照片的日期只适度延长，不按照片或真实滚动长度膨胀")
        try check(geometry.spans.map(\.id) == sections.map(\.id),
                  "跨过没有照片的日期时不制造等长空日期")
        let narrower = JustifiedTimelineLayout.make(sections: sections, width: 460, targetHeight: 180)
        let narrow = LineDateRulerGeometry(spans: Self.spans(for: narrower), position: 0, totalLength: narrower.contentHeight, sections: sections)
        try check(narrow.spans[1].length > geometry.spans[1].length
                  && close(projectedLength(narrow, at: 1), manyLength),
                  "窗口变窄增加同日照片行数时，日期尺长度保持紧凑不变")
        let larger = JustifiedTimelineLayout.make(sections: sections, width: 900, targetHeight: 270)
        let zoomed = LineDateRulerGeometry(spans: Self.spans(for: larger), position: 0, totalLength: larger.contentHeight, sections: sections)
        try check(zoomed.spans[1].length > geometry.spans[1].length
                  && close(projectedLength(zoomed, at: 1), manyLength),
                  "缩略图放大只改变原始网格坐标，不拉长日期导航尺")
        let allItems = sections.flatMap(\.items)
        let grouped = TimelineGrouping.sections(for: allItems, scale: .month)
        let months = JustifiedTimelineLayout.make(sections: grouped, width: 900, targetHeight: 70)
        let monthGeometry = LineDateRulerGeometry(spans: Self.spans(for: months), position: 0, totalLength: months.contentHeight, sections: grouped)
        try check(monthGeometry.spans.count == grouped.count && grouped.count < sections.count,
                  "切换月聚合后仅保留新月份区间，不残留旧日刻度")
        let calendar = Calendar(identifier: .gregorian)
        let yearSections = (1...12).map { month in
            let date = calendar.date(from: DateComponents(year: 2025, month: month, day: 1))!
            return TemporalSection(id: "month:\(month)", startDate: date, endDate: date.addingTimeInterval(1),
                                   title: "\(month)月", items: sections[1].items)
        }
        let annualSpans = yearSections.enumerated().map {
            TimelineDateSpan(id: $0.element.id, start: Double($0.offset) * 100_000, length: 100_000)
        }
        let year = LineDateRulerGeometry(spans: annualSpans, position: 0, totalLength: 1_200_000, sections: yearSections)
        try check(year.dateScale.totalExtent <= 936 && year.dateScale.totalExtent >= 624,
                  "百万点照片网格的一整年被收拢在约一屏日期尺，可快速浏览去年")
        let previousYear = year.documentPosition(offsetByRulerPoints: 936)
        try check(close(previousYear, 1_200_000), "不到两屏的日期尺滚动即可跨过完整一年照片")
    }

    static func projectedLength(_ geometry: LineDateRulerGeometry, at index: Int) -> Double {
        geometry.y(forDocumentPosition: geometry.spans[index].end, height: 600)
            - geometry.y(forDocumentPosition: geometry.spans[index].start, height: 600)
    }
    static func compressedScaleBoundaries() throws {
        let calendar = Calendar.current
        let recentStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        var inputs: [CompressedDateScale.Input] = []
        for day in 0..<365 {
            inputs.append(.init(start: Double(inputs.count) * 2000, length: 2000,
                                date: calendar.date(byAdding: .day, value: day, to: recentStart)!, count: 2000))
        }
        let historicalStart = calendar.date(from: DateComponents(year: 2025, month: 12, day: 1, hour: 12))!
        for month in 0..<100 {
            inputs.append(.init(start: Double(inputs.count) * 2000, length: 2000,
                                date: calendar.date(byAdding: .month, value: -month, to: historicalStart)!, count: 1))
        }
        let scale = CompressedDateScale(inputs: inputs, totalLength: Double(inputs.count) * 2000, monthlyExtent: 52)
        try check(scale.segments.prefix(365).reduce(0) { $0 + $1.rulerLength } <= 936.000001,
                  "即使最近一年每天两千张、历史百月稀疏，最近一年也不侵占历史月份的紧凑预算")
        let reverse = CompressedDateScale(inputs: inputs.reversed().enumerated().map {
            .init(start: Double($0.offset) * 2000, length: 2000, date: $0.element.date, count: $0.element.count)
        }, totalLength: Double(inputs.count) * 2000, monthlyExtent: 52)
        try check(zip(scale.segments, reverse.segments.reversed()).allSatisfy { close($0.rulerLength, $1.rulerLength) },
                  "升降序切换仅反转日期方向，不改变各日期的紧凑长度")
        let gaps = CompressedDateScale(inputs: [
            .init(start: -0.5, length: 10, date: recentStart, count: 10),
            .init(start: 20, length: 5, date: recentStart, count: 5)
        ], totalLength: 40)
        try check([-0.5, 0, 4, 9.5, 10, 19.999, 20, 24.99, 40].allSatisfy {
            close(gaps.position(at: gaps.coordinate(for: $0)), $0)
        }, "横卷负半项起点、布局内部留白与末尾留白均保持连续精确往返")
        let tiny = CompressedDateScale(inputs: inputs, totalLength: 930_000,
                                       monthlyExtent: .leastNonzeroMagnitude, magnification: .leastNonzeroMagnitude)
        try check(tiny.totalExtent.isFinite && tiny.totalExtent > 0
                  && tiny.position(at: tiny.coordinate(for: 12345.625)).isFinite,
                  "极小尺度参数收敛为有效有限坐标，不产生零长度或无效反算")
    }
    static func continuousProjection() throws {
        let sections = makeSections(counts: [60, 1])
        let spans = [TimelineDateSpan(id: sections[0].id, start: 0, length: 10_000),
                     TimelineDateSpan(id: sections[1].id, start: 10_000, length: 200)]
        let a = LineDateRulerGeometry(spans: spans, position: 1000, totalLength: 10_200, sections: sections)
        let b = a.replacingPosition(1000.25)
        let c = a.replacingPosition(1023.5)
        let localScale = projectedLength(a, at: 0) / spans[0].length
        try check(close(a.y(forDocumentPosition: 1500, height: 600) - b.y(forDocumentPosition: 1500, height: 600), 0.25 * localScale),
                  "同一天内部四分之一文档点也连续映射到压缩刻度，不量化跳动")
        try check(a.index(atDocumentPosition: a.position) == b.index(atDocumentPosition: b.position)
                  && b.index(atDocumentPosition: b.position) == c.index(atDocumentPosition: c.position)
                  && a.y(forDocumentPosition: 0, height: 600) != c.y(forDocumentPosition: 0, height: 600),
                  "同一个日期保持唯一选中时，日期边界仍随浏览移动")
        for source in [0.0, 1512.75, 9999.999, 10_000, 10_175.25, 10_200] {
            let y = a.y(forDocumentPosition: source, height: 600)
            try check(close(a.documentPosition(atY: y, height: 600), source),
                      "压缩尺双向映射精确保留文档位置 \(source)")
        }
        try check(close(a.y(forDocumentPosition: a.position, height: 820), 410),
                  "改变视口高度后当前文档锚点保持在日期尺中心")
        try check(a.visibleIndices(height: 600).contains(0),
                  "真实文档跨度超出整个视口时仍包含当前压缩日期")
    }

    static func geometryBoundaries() throws {
        let spans = [TimelineDateSpan(id: "second", start: 300, length: 200),
                     TimelineDateSpan(id: "first", start: 20, length: 280),
                     TimelineDateSpan(id: "second", start: 600, length: 100),
                     TimelineDateSpan(id: "nan", start: .nan, length: 40),
                     TimelineDateSpan(id: "negative", start: -1, length: 20),
                     TimelineDateSpan(id: "zero", start: 500, length: 0)]
        let g = LineDateRulerGeometry(spans: spans, position: .infinity, totalLength: .nan)
        try check(g.spans.map(\.id) == ["first", "second"] && g.totalLength == 500 && g.position == 0,
                  "无效及重复日期几何被过滤，有效日期按实际位置排列")
        try check(g.index(atDocumentPosition: -30) == 0 && g.index(atDocumentPosition: 300) == 1
                  && g.index(atDocumentPosition: 900) == 1,
                  "日期边界、首尾越界和精确下一段起点正确归属")
        try check(g.replacingPosition(-100).position == 0 && g.replacingPosition(900).position == 500,
                  "连续定位在文档有效范围内收敛")
        try check(g.visibleIndices(height: 0).isEmpty && g.visibleIndices(height: .nan).isEmpty,
                  "零尺寸或无效视口不绘制任何日期")
        let empty = LineDateRulerGeometry(spans: [], position: 20, totalLength: 0)
        try check(empty.index(atDocumentPosition: 0) == nil && empty.visibleIndices(height: 600).isEmpty,
                  "空资料库没有虚构刻度或可选日期")
    }

    static func nativeViewInteraction() throws {
        let f = Fixture(sections: makeSections(counts: [1, 60, 3]))
        defer { f.close() }
        let position = f.spans[1].start + 1700
        f.configure(position: position, active: f.sections[1].id)
        try check(!f.window.isVisible && f.view.entries.count == 3 && f.view.activeIndex == 1,
                  "真实隐藏原生日期尺读取三组几何，并保留单一活动日期")
        let firstBitmap = f.snapshot()
        let firstTickPositions = Dictionary(uniqueKeysWithValues: f.view.visibleRulerTicks.map { ($0.index, $0.position) })
        let before = f.view.geometry.y(forDocumentPosition: f.spans[1].start, height: f.view.bounds.height)
        f.configure(position: position + 13.25, active: f.sections[1].id)
        let after = f.view.geometry.y(forDocumentPosition: f.spans[1].start, height: f.view.bounds.height)
        let compactDelta = f.view.geometry.dateScale.coordinate(for: position + 13.25)
            - f.view.geometry.dateScale.coordinate(for: position)
        try check(close(before - after, compactDelta) && before != after && f.view.rebuildCount == 1,
                  "同组内视口回报连续驱动真实日期尺且不重建日期标签")
        try check(firstBitmap != nil && f.snapshot() != nil && f.view.visibleRulerTicks.contains { tick in
            firstTickPositions[tick.index].map { !close($0, tick.position) } ?? false
        }, "同日浏览时实际日期刻度持续移动，无需添加内部装饰线")
        let children = f.view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement } ?? []
        try check(children.count == 3 && children.filter { $0.isAccessibilitySelected() }.count == 1,
                  "所有日期均有独立辅助功能按钮，只有当前日期被选中")
        try check(children.allSatisfy { $0.isAccessibilityEnabled() },
                  "每个日期辅助功能按钮显式启用，可经系统标准按下动作选择")
        try check(children.first?.accessibilityPerformPress() == true && f.selectedDates.last == f.sections[0].id,
                  "视口外日期也能通过辅助功能直接跳转")
        f.configure(position: position, active: f.sections[1].id)
        f.view.keyDown(with: f.key(125))
        try check(f.selectedDates.last == f.sections[2].id, "方向键可跳到下一个有照片的日期")
        f.view.keyDown(with: f.key(115))
        try check(f.selectedDates.last == f.sections[0].id, "Home 键直接选择首个日期")
        f.view.keyDown(with: f.key(119))
        try check(f.selectedDates.last == f.sections[2].id, "End 键直接选择最后日期")
        let navigations = f.positions.count
        f.view.keyDown(with: f.key(121))
        try check(f.positions.count == navigations + 1 && (f.positions.last ?? 0) > position,
                  "Page Down 连续移动日期尺，不按日期数量跳固定步长")
        f.configure(position: position, active: f.sections[1].id)
        f.view.beginScrubbing(at: CGPoint(x: 60, y: 300))
        f.view.scrub(to: CGPoint(x: 60, y: 282))
        f.view.endScrubbing(at: CGPoint(x: 60, y: 282))
        try check(close(f.positions.last ?? -1, f.view.geometry.documentPosition(atRulerPosition:
            f.view.geometry.dateScale.coordinate(for: position) + 18)),
                  "按住拖动 18 点沿压缩尺导航，跨日期后仍正确反算真实文档位置")
        f.configure(position: position, active: f.sections[1].id)
        f.view.scrollWheel(with: Wheel(delta: -1.8, precise: true))
        try check(close(f.positions.last ?? -1, f.view.geometry.documentPosition(atRulerPosition:
            f.view.geometry.dateScale.coordinate(for: position) + 1.8)),
                  "触控板精细滚动沿压缩尺连续导航，避免困在长照片日期")
        let priorCount = f.positions.count
        f.view.scrollWheel(with: Wheel(delta: -1.8, precise: true, command: true))
        try check(f.positions.count == priorCount && f.zoomEvents == 1,
                  "Command 滚轮交还原有缩放动作，不误导航日期")
        f.configure(position: 0, active: f.sections[0].id)
        f.view.selectDate(at: CGPoint(x: 60, y: 300))
        try check(f.selectedDates.last == f.sections[0].id, "点击日期所在区间跳转其照片首项")
        f.view.beginScrubbing(at: CGPoint(x: 60, y: 300))
        f.view.endScrubbing(at: CGPoint(x: 60, y: 301))
        try check(f.selectedDates.last == f.sections[0].id, "轻微手部移动仍作为日期单击")
        f.view.setFrameSize(CGSize(width: 140, height: 810))
        try check(close(f.view.geometry.y(forDocumentPosition: 0, height: f.view.bounds.height), 405),
                  "原生视口改变高度后日期锚点投影同步更新")
        let image = f.view.bitmapImageRepForCachingDisplay(in: f.view.bounds)
        if let image { f.view.cacheDisplay(in: f.view.bounds, to: image) }
        let backing = f.view.convertToBacking(f.view.bounds)
        try check(image?.pixelsWide == Int(backing.width) && image?.pixelsHigh == Int(backing.height) && !f.window.isVisible,
                  "原生日期绘制可在隐藏窗口完成，不显示测试界面")
    }

    static func largeAndEmptyLibraries() throws {
        let sections = makeSections(counts: Array(repeating: 1, count: 10_000))
        let f = Fixture(sections: sections, syntheticSpans: true)
        defer { f.close() }
        f.configure(position: 1_500_010, active: sections[5000].id)
        try check(f.view.visibleDateIndices.count < 30 && f.view.entries.count == 10_000,
                  "一万个日期只绘制视口附近刻度，完整保留日期导航数据")
        let children = f.view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement } ?? []
        try check(children.count == 10_000 && children.last?.accessibilityPerformPress() == true
                  && f.selectedDates.last == sections.last?.id,
                  "极大资料库仍可通过辅助功能直接找到并打开最末日期")
        f.view.configure(sections: [], spans: [], position: 0, totalLength: 0, activeID: nil,
                         dark: true, reduceMotion: true, revision: 2)
        try check(f.view.entries.isEmpty && f.view.activeIndex == -1
                  && (f.view.accessibilityChildren()?.isEmpty ?? true)
                  && !f.view.accessibilityPerformIncrement() && !f.view.accessibilityPerformDecrement(),
                  "过滤到空结果时清除所有刻度、高亮和辅助日期")
    }

    static func nativeLabelHitTargets() throws {
        let f = Fixture(sections: makeSections(counts: [1, 60, 3]))
        defer { f.close() }
        // The grid's document probe is 44 pt below its origin, so the next
        // date can already be active shortly before that header reaches it.
        f.configure(position: f.spans[1].start - 20, active: f.sections[1].id)
        guard let label = f.view.labelFrame(atIndex: 1) else { throw Failure.failed("当前日期标签必须真实可见") }
        let point = CGPoint(x: 48, y: label.minY + 2)
        let rawIndex = f.view.geometry.index(atDocumentPosition:
            f.view.geometry.documentPosition(atY: point.y, height: f.view.bounds.height))
        try check(rawIndex == 0 && f.view.index(at: point) == 1,
                  "日期文字标线上半部优先命中实际标签，不误选上一日期")
        f.view.mouseDown(with: f.mouse(.leftMouseDown, point: point))
        f.view.mouseUp(with: f.mouse(.leftMouseUp, point: point))
        try check(f.selectedDates.last == f.sections[1].id && !f.window.isVisible,
                  "真实原生鼠标按下与松开点击日期文字上半部，跳转文字对应日期")
        let children = f.view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement } ?? []
        let expected = f.window.convertToScreen(f.view.convert(label, to: nil))
        try check(children[1].accessibilityFrame() == expected,
                  "可见日期辅助功能框与真实绘制及鼠标命中框完全一致")
        f.view.setFrameSize(CGSize(width: 140, height: 36))
        f.configure(position: f.spans[1].start + f.spans[1].length - 1, active: f.sections[1].id)
        guard let pinned = f.view.labelFrame(atIndex: 1) else { throw Failure.failed("紧凑视口当前日期标签必须持续可见") }
        let activeTicks = f.view.visibleRulerTicks.filter { $0.index == f.view.activeIndex }
        try check(activeTicks.count == 1 && activeTicks[0].isMajor
                  && close(activeTicks[0].position, pinned.minY + 8),
                  "钉顶日期只有一根主刻度且与文字共用位置，不残留原位置的蓝线")
        f.view.selectDate(at: CGPoint(x: 48, y: pinned.minY + 2))
        try check(pinned.minY == 8 && f.selectedDates.last == f.sections[1].id,
                  "紧凑视口钉顶日期沿用同一实际命中框，不丢失触点归属")
        f.view.setFrameSize(CGSize(width: 140, height: 600))
        let compact = f.sections.enumerated().map {
            TimelineDateSpan(id: $0.element.id, start: Double($0.offset) * 100, length: 100)
        }
        let compactSections = f.sections.enumerated().map { index, section in
            let date = f.sections[0].startDate.addingTimeInterval(Double(index) * 86400)
            return TemporalSection(id: section.id, startDate: date, endDate: date.addingTimeInterval(86400),
                                   title: section.title, items: section.items)
        }
        f.view.configure(sections: compactSections, spans: compact, position: 100, totalLength: 300,
                         activeID: f.sections[1].id, dark: false, reduceMotion: true, revision: 1)
        let hiddenIndices = f.sections.indices.filter { f.view.labelFrame(atIndex: $0) == nil }
        try check(f.view.labelFrame(atIndex: 0) != nil && f.view.labelFrame(atIndex: 2) != nil && hiddenIndices.allSatisfy { children[$0].accessibilityFrame() == .zero }
                  && hiddenIndices.allSatisfy { children[$0].accessibilityPerformPress() },
                  "密集的三个相邻日期均保留标签；被避让日期不产生重叠AX触点")
    }

    static func quietNativeTicks() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!
        let seed = makeSections(counts: [1])[0].items
        let sections = (0..<120).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            return TemporalSection(id: "day:\(offset)", startDate: date, endDate: date.addingTimeInterval(86_400),
                                   title: "\(offset) 日期", items: seed)
        }
        let f = Fixture(sections: sections, syntheticSpans: true)
        defer { f.close() }
        f.configure(position: f.spans[60].start + 120, active: sections[60].id)
        let ticks = f.view.visibleRulerTicks
        let majors = ticks.filter(\.isMajor)
        let minors = ticks.filter { !$0.isMajor }
        let labeledIndices = sections.indices.filter { f.view.labelFrame(atIndex: $0) != nil }
        try check(Set(majors.map(\.index)) == Set(labeledIndices) && majors.allSatisfy { tick in
            f.view.labelFrame(atIndex: tick.index).map { close(tick.position, $0.minY + 8) } ?? false
        }, "密集日期只给可见文字绘制主刻度，主线与日期行精确对齐")
        try check(ticks.count < f.view.visibleDateIndices.count / 2
                  && minors.allSatisfy { minor in
                      ticks.allSatisfy { other in
                          minor.index == other.index || abs(minor.position - other.position) >= 22 - 0.000001
                      }
                  }, "一百二十个连续日期合并疏密显示，短刻度距任意相邻刻度至少22点")
        try check(Set(ticks.map(\.index)).count == ticks.count && minors.allSatisfy { tick in
            close(tick.position, f.view.geometry.y(forDocumentPosition: f.spans[tick.index].start,
                                                   height: f.view.bounds.height))
        }, "辅助短刻度仅来自真实日期边界，没有均匀填充的虚构日期线")
        if let major = majors.first(where: { $0.index != f.view.activeIndex }) {
            f.view.selectDate(at: CGPoint(x: 16, y: major.position))
            try check(f.selectedDates.last == sections[major.index].id,
                      "稀疏主刻度的实际鼠标点击仍跳转其显示日期")
        } else { throw Failure.failed("密集日期中必须保留可跳转的其它可见日期") }
    }

    static func nativeYearBoundaries() throws {
        let calendar = Calendar.current, seed = makeSections(counts: [1])[0].items
        let dates = [(2025, 2, 1), (2025, 1, 15), (2024, 12, 20), (2024, 11, 1), (2023, 12, 20)]
        let sections = dates.enumerated().map { index, d in
            let date = calendar.date(from: DateComponents(year: d.0, month: d.1, day: d.2))!
            return TemporalSection(id: "day:year-\(index)", startDate: date, endDate: date.addingTimeInterval(86400),
                                   title: "year \(index)", items: seed)
        }
        let f = Fixture(sections: sections, syntheticSpans: true)
        defer { f.close() }
        f.configure(position: f.spans[2].start, active: sections[2].id)
        try check(f.view.visibleYearBoundaries.map(\.marker.year) == ["2025", "2023"],
                  "右侧2024当前日期仅在两侧真实分界标记2025和2023")
        try check(f.view.visibleYearBoundaries.allSatisfy { b in
            close(b.marker.position, f.view.geometry.y(forDocumentPosition: f.spans[b.marker.index].start, height: 600))
                && f.view.bounds.contains(b.frame)
                && !(f.view.labelFrame(atIndex: 2)?.intersects(b.frame) ?? true)
        }, "右侧分界线绑定真实坐标且年份避让当前日期与年份")
        let frames = sections.indices.compactMap { index in f.view.labelFrame(atIndex: index).map { (index, $0) } }
        try check(frames.contains(where: { $0.0 != 2 }) && frames.allSatisfy { $0.1.height == ($0.0 == 2 ? 28 : 15) },
                  "右侧仅当前日期占用两行，其余日期无重复年份触点")
        let previous = f.view.visibleYearBoundaries.map(\.marker.position)
        f.configure(position: f.spans[2].start + 100, active: sections[2].id)
        try check(zip(previous, f.view.visibleYearBoundaries.map(\.marker.position)).allSatisfy { abs($0 - $1) > 1 },
                  "浏览同日照片时右侧跨年分界连续移动")
        let reverse = Fixture(sections: sections.reversed(), syntheticSpans: true)
        defer { reverse.close() }
        reverse.configure(position: reverse.spans[2].start, active: reverse.sections[2].id)
        try check(reverse.view.visibleYearBoundaries.map(\.marker.year) == ["2023", "2025"],
                  "右侧升序日期同样识别前后相邻年份")
        f.view.setFrameSize(CGSize(width: 140, height: 70))
        f.configure(position: 0, active: sections[0].id)
        try check(f.view.visibleYearBoundaries.isEmpty && f.view.labelFrame(atIndex: 0)?.height == 28,
                  "右侧邻年移出视口后不残留年份，当前年份保留")
    }

    static func nativeWheelInteraction() async throws {
        let centre = DateRulerWheelStyle.depth(at: 300, centre: 300, extent: 600, reduceMotion: false)
        let edge = DateRulerWheelStyle.depth(at: 0, centre: 300, extent: 600, reduceMotion: false)
        let opposite = DateRulerWheelStyle.depth(at: 600, centre: 300, extent: 600, reduceMotion: false)
        try check(centre.scale == 1 && centre.opacity == 1 && edge.scale < centre.scale
                  && edge.opacity < centre.opacity && edge.opacity == opposite.opacity,
                  "滚轮中央清晰完整，两端对称缩小与退隐且不改变日期坐标")
        try check(DateRulerWheelStyle.depth(at: 0, centre: 300, extent: 600, reduceMotion: true).scale == 1,
                  "减少动态效果时关闭滚轮深度缩放")
        var slow = DateRulerWheelMotion.Coast(velocity: 1000, maximumTravel: 220)
        var fast = slow, a = 0.0, b = 0.0
        for _ in 0..<15 { a += slow.advance(by: 1 / 30.0) }
        for _ in 0..<60 { b += fast.advance(by: 1 / 120.0) }
        try check(abs(a - b) < 0.00001 && a > 150 && a < 220,
                  "30与120帧惯性距离一致，衰减有界且不会无限漂移")
        let first = slow.advance(by: 0.016), second = slow.advance(by: 0.016)
        try check(first > second && second > 0, "松手后位移自然逐帧减速")
        let calendar = Calendar.current, seed = makeSections(counts: [1])[0].items
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let sections = (0..<60).map { index in
            let date = calendar.date(byAdding: .month, value: -index, to: start)!
            return TemporalSection(id: "month:wheel-\(index)", startDate: date, endDate: date.addingTimeInterval(86400),
                                   title: "wheel \(index)", items: seed)
        }
        let horizontal = BrowseDateRulerView(frame: CGRect(x: 0, y: 0, width: 800, height: 52))
        let entries = sections.enumerated().map { BrowseDateEntry(section: $0.element, firstItemIndex: $0.offset) }
        let window = NSWindow(contentRect: horizontal.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(CGPoint(x: -10000, y: -10000)); window.contentView = horizontal
        defer { horizontal.stop(); window.contentView = nil }
        horizontal.configure(entries: entries, activeIndex: 20, dataChanged: true, reduceMotion: false, dark: true)
        var time = ProcessInfo.processInfo.systemUptime
        horizontal.beginScrubbing(at: CGPoint(x: 400, y: 20), time: time)
        horizontal.scrub(to: CGPoint(x: 380, y: 20), time: time + 0.02)
        horizontal.scrub(to: CGPoint(x: 360, y: 20), time: time + 0.04)
        horizontal.endScrubbing(at: CGPoint(x: 360, y: 20), time: time + 0.05)
        let released = horizontal.scrollOffset
        try await Task.sleep(for: .milliseconds(100))
        try check(horizontal.scrollOffset > released + 15 && horizontal.scrollOffset < released + 261,
                  "真实横向日期尺拖动松手后继续平滑滚动，行程受控")
        horizontal.configure(entries: entries, activeIndex: 0, dataChanged: false, reduceMotion: false, dark: true)
        try await Task.sleep(for: .milliseconds(60))
        try check(horizontal.scrollOffset == 0, "外部跳转立即打断横向惯性，不被旧滚动拉回")
        let f = Fixture(sections: sections, syntheticSpans: true)
        defer { f.close() }
        f.view.configure(sections: sections, spans: f.spans, position: f.spans[20].start, totalLength: f.length,
                         activeID: sections[20].id, dark: false, reduceMotion: false, revision: 1)
        time = ProcessInfo.processInfo.systemUptime
        f.view.beginScrubbing(at: CGPoint(x: 60, y: 300), time: time)
        f.view.scrub(to: CGPoint(x: 60, y: 280), time: time + 0.02)
        f.view.scrub(to: CGPoint(x: 60, y: 260), time: time + 0.04)
        f.view.endScrubbing(at: CGPoint(x: 60, y: 260), time: time + 0.05)
        let verticalReleased = f.view.geometry.rulerPosition
        try await Task.sleep(for: .milliseconds(100))
        try check(f.view.geometry.rulerPosition > verticalReleased + 15
                  && f.view.geometry.rulerPosition < verticalReleased + 221,
                  "真实竖向日期尺同样具有受控惯性，不止于指针松开的位置")
        f.view.stop(); let stopped = f.view.geometry.rulerPosition
        try await Task.sleep(for: .milliseconds(60))
        try check(f.view.geometry.rulerPosition == stopped, "卸载或新操作停止竖向惯性，无后台残留推进")
        horizontal.configure(entries: entries, activeIndex: 20, dataChanged: false, reduceMotion: true, dark: true)
        time = ProcessInfo.processInfo.systemUptime
        horizontal.beginScrubbing(at: CGPoint(x: 400, y: 20), time: time)
        horizontal.scrub(to: CGPoint(x: 380, y: 20), time: time + 0.02)
        horizontal.scrub(to: CGPoint(x: 360, y: 20), time: time + 0.04)
        horizontal.endScrubbing(at: CGPoint(x: 360, y: 20), time: time + 0.05)
        let reduced = horizontal.scrollOffset
        try await Task.sleep(for: .milliseconds(60))
        try check(horizontal.scrollOffset == reduced && !window.isVisible && !f.window.isVisible,
                  "减少动态效果禁用松手惯性，原生窗口检查不打扰正式应用")
    }

    static func nativeDrawingBounds() throws {
        let f = Fixture(sections: makeSections(counts: [1, 60, 3]))
        defer { f.close() }
        let host = ColorSurface(frame: CGRect(x: 0, y: 0, width: 640, height: 400), color: .systemPink)
        let header = ColorSurface(frame: CGRect(x: 0, y: 330, width: 640, height: 70), color: .systemGreen)
        let left = ColorSurface(frame: CGRect(x: 0, y: 0, width: 500, height: 330), color: .systemPurple)
        let right = ColorSurface(frame: CGRect(x: 620, y: 0, width: 20, height: 330), color: .systemOrange)
        f.window.contentView = host
        f.window.setContentSize(CGSize(width: 640, height: 400))
        host.addSubview(left); host.addSubview(header); host.addSubview(right)
        f.view.frame = CGRect(x: 500, y: 0, width: 120, height: 330)
        host.addSubview(f.view)
        f.configure(position: f.spans[1].start + 1500, active: f.sections[1].id)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure.failed("宿主原生快照必须可用") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var samplePoints = [(50, 200), (630, 200), (50, 10), (50, 390)]
        // Locate a header row in bitmap coordinates so the check also samples
        // the sibling directly above the ruler, independent of bitmap Y flip.
        if let headerRow = (0..<bitmap.pixelsHigh).first(where: {
            bitmap.colorAt(x: 550, y: $0) == bitmap.colorAt(x: 50, y: $0)
        }) { samplePoints.append((550, headerRow)) }
        let original = samplePoints.map { bitmap.colorAt(x: $0.0, y: $0.1) }
        try check(f.view.wantsDefaultClipping && f.view.clipsToBounds,
                  "日期尺显式启用原生默认裁剪及bounds裁剪")
        // macOS may hand a view a dirty region larger than its own bounds.
        // Render that exact case into the host snapshot, under its real frame
        // transform, without relying on implicit AppKit clipping.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: f.view.frame.minX, y: f.view.frame.minY)
        f.view.draw(CGRect(x: -1000, y: -1000, width: 3000, height: 3000))
        NSGraphicsContext.restoreGraphicsState()
        let after = samplePoints.map { bitmap.colorAt(x: $0.0, y: $0.1) }
        try check(samplePoints.count == 5 && original.allSatisfy { $0 != nil } && zip(original, after).allSatisfy { $0 == $1 }
                  && !f.window.isVisible,
                  "父宿主快照中超大dirtyRect重绘日期尺后，左右与上方兄弟像素均保持原色")
    }

    static func makeSections(counts: [Int]) -> [TemporalSection] {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        return counts.enumerated().map { offset, count in
            let date = calendar.date(byAdding: .day, value: offset == 1 ? 1 : offset * 40, to: start)!
            let items = (0..<count).map { index in
                MediaItem(url: URL(fileURLWithPath: "/TimelineChecks/\(offset)-\(index).jpg"), kind: .image,
                          fileSize: 1, modifiedDate: date, createdDate: date, pixelWidth: 1600, pixelHeight: 1200)
            }
            return TemporalSection(id: "day:\(date.timeIntervalSinceReferenceDate)", startDate: date,
                                   endDate: date.addingTimeInterval(86_400), title: "\(offset) 日期", items: items)
        }
    }
    static func spans(for layout: TimelineLayout) -> [TimelineDateSpan] {
        layout.sections.enumerated().map { index, section in
            let next = index + 1 < layout.sections.count ? layout.sections[index + 1].headerFrame.minY : layout.contentHeight
            return TimelineDateSpan(id: section.id, start: section.headerFrame.minY, length: next - section.headerFrame.minY)
        }
    }
    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
    static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw Failure.failed(description) }
        passed += 1; print("PASS \(description)")
    }
}

@MainActor private final class Fixture {
    let sections: [TemporalSection]
    let spans: [TimelineDateSpan]
    let length: Double
    let window: NSWindow
    let view: LineDateRulerView
    var selectedDates: [String] = []
    var positions: [Double] = []
    var zoomEvents = 0
    init(sections: [TemporalSection], syntheticSpans: Bool = false) {
        self.sections = sections
        let layout = JustifiedTimelineLayout.make(sections: sections, width: 900, targetHeight: 180)
        spans = syntheticSpans ? sections.enumerated().map { TimelineDateSpan(id: $0.element.id, start: Double($0.offset) * 300, length: 300) }
            : TimelineChecks.spans(for: layout)
        length = syntheticSpans ? Double(sections.count) * 300 : layout.contentHeight
        window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 140, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        view = LineDateRulerView(frame: CGRect(x: 0, y: 0, width: 140, height: 600))
        window.contentView = view
        view.onSelectDate = { [weak self] in self?.selectedDates.append($0) }
        view.onNavigate = { [weak self] in self?.positions.append($0) }
        view.onZoom = { [weak self] _ in self?.zoomEvents += 1 }
    }
    func configure(position: Double, active: String?) {
        view.configure(sections: sections, spans: spans, position: position, totalLength: length,
                       activeID: active, dark: false, reduceMotion: true, revision: 1)
    }
    func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                         windowNumber: window.windowNumber, context: nil, characters: "",
                         charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    func mouse(_ type: NSEvent.EventType, point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 2,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }
    func snapshot() -> Data? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.bitmapData else { return nil }
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
    func close() { view.stop(); window.contentView = nil }
}

private final class Wheel: NSEvent {
    let delta: CGFloat
    let precise: Bool
    let command: Bool
    init(delta: CGFloat, precise: Bool, command: Bool = false) {
        self.delta = delta; self.precise = precise; self.command = command; super.init()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var scrollingDeltaY: CGFloat { delta }
    override var scrollingDeltaX: CGFloat { 0 }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var modifierFlags: NSEvent.ModifierFlags { command ? [.command] : [] }
}
@MainActor private final class ColorSurface: NSView {
    let color: NSColor
    init(frame: CGRect, color: NSColor) { self.color = color; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}
private enum Failure: Error { case failed(String) }
