import AppKit
import SwiftUI
import FilmboxCore

/// A date ruler shares the continuous album's cursor, without changing explicit
/// multi-selection. Only a revision change rebuilds media-to-date membership.
struct BrowseTimeRuler: NSViewRepresentable {
    let store: AppStore
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> BrowseDateRulerView {
        let view = BrowseDateRulerView()
        view.onNavigate = { [weak coordinator = context.coordinator] in coordinator?.navigate(to: $0) }
        view.onNavigatePosition = { [weak coordinator = context.coordinator] in coordinator?.navigate(toPosition: $0) }
        view.onZoom = { [weak store] in store?.zoomTimeline(with: $0) }
        return view
    }
    func updateNSView(_ view: BrowseDateRulerView, context: Context) {
        context.coordinator.update(view, reduceMotion: reduceMotion, dark: scheme == .dark)
    }
    static func dismantleNSView(_ view: BrowseDateRulerView, coordinator: Coordinator) {
        view.stop(); view.onNavigate = nil; view.onNavigatePosition = nil; view.onZoom = nil
    }

    @MainActor final class Coordinator {
        let store: AppStore
        private var visibleRevision = -1
        private var scale: TimelineScale?
        private var dateSort: AppStore.SortOrder?
        private var descending = true
        private(set) var entries: [BrowseDateEntry] = []
        private(set) var sectionByItem: [Int] = []
        private(set) var rebuildCount = 0
        init(store: AppStore) { self.store = store }

        func update(_ view: BrowseDateRulerView, reduceMotion: Bool, dark: Bool) {
            let changed = visibleRevision != store.visibleRevision || scale != store.browseTimelineScale
                || dateSort != store.sort || descending != store.descending
            if changed {
                visibleRevision = store.visibleRevision; scale = store.browseTimelineScale
                dateSort = store.sort; descending = store.descending
                let visible = store.visibleItems
                entries = []
                sectionByItem = Array(repeating: -1, count: visible.count)
                let sections = TimelineGrouping.sections(for: visible, scale: store.browseTimelineScale,
                                                        dateBasis: store.timelineDateBasis, descending: store.descending)
                var sectionForItem: [String: TemporalSection] = [:]
                for section in sections { for item in section.items { sectionForItem[item.id] = section } }
                // Runs also keep the ruler faithful to media order when the
                // user chooses a non-date sort and a date appears twice.
                var runStart = 0
                var runSection: TemporalSection?
                func appendRun(endingAt end: Int) {
                    guard let section = runSection, end >= runStart else { return }
                    let entryIndex = entries.count
                    entries.append(BrowseDateEntry(section: section, firstItemIndex: runStart, lastItemIndex: end))
                    for index in runStart...end { sectionByItem[index] = entryIndex }
                }
                for (index, item) in visible.enumerated() {
                    let section = sectionForItem[item.id]
                    if section?.id != runSection?.id {
                        appendRun(endingAt: index - 1)
                        runStart = index; runSection = section
                    }
                }
                appendRun(endingAt: visible.count - 1)
                rebuildCount += 1
            }
            let active = sectionByItem.indices.contains(store.browseIndex) ? sectionByItem[store.browseIndex] : -1
            view.configure(entries: entries, activeIndex: active, position: resolvedPosition, mediaCount: store.visibleItems.count, dataChanged: changed,
                           reduceMotion: reduceMotion, dark: dark, zoom: store.browseTimelineSize)
        }
        private var resolvedPosition: Double {
            let position = store.browsePosition
            return position.isFinite && Int(position.rounded()) == store.browseIndex ? position : Double(store.browseIndex)
        }
        private var isCurrent: Bool {
            store.visibleRevision == visibleRevision && store.browseTimelineScale == scale
                && store.sort == dateSort && store.descending == descending
        }
        func navigate(to sectionIndex: Int) {
            guard entries.indices.contains(sectionIndex), isCurrent else { return }
            navigate(toPosition: Double(entries[sectionIndex].firstItemIndex))
        }
        func navigate(toPosition position: Double) {
            guard isCurrent, !store.visibleItems.isEmpty, position.isFinite else { return }
            store.navigateBrowse(to: position)
            let index = store.browseIndex
            let itemID = store.visibleItems[index].id
            // Grid and roll can use different date scales.
            store.setVisibleTimelineSection(store.timelineSections.first { section in
                section.items.contains { $0.id == itemID }
            }?.id)
        }
    }
}

struct BrowseDateEntry {
    let id: String
    let title: String
    let label: String
    let year: String
    let startDate: Date
    let firstItemIndex: Int
    let lastItemIndex: Int
    var itemCount: Int { lastItemIndex - firstItemIndex + 1 }
    init(section: TemporalSection, firstItemIndex: Int, lastItemIndex: Int? = nil) {
        id = section.id; title = section.title; startDate = section.startDate
        self.firstItemIndex = firstItemIndex
        self.lastItemIndex = lastItemIndex ?? firstItemIndex
        let components = Calendar.current.dateComponents([.year, .month, .day], from: section.startDate)
        year = String(components.year ?? 0)
        let month = components.month ?? 1, day = components.day ?? 1
        if section.id.hasPrefix("month:") { label = "\(month)月" }
        else if section.id.hasPrefix("week:") { label = "\(month).\(day) 周" }
        else { label = "\(month)月\(day)日" }
    }
}

/// Each populated month receives a compact budget of space. Busier dates
/// receive a little more of that budget, while fractional media positions map
/// continuously in both directions without making a large shoot fill the ruler.
@MainActor final class BrowseDateRulerView: NSView {
    static let spacing: CGFloat = 84
    private(set) var tickSpacing: CGFloat = 84
    private(set) var entries: [BrowseDateEntry] = []
    private(set) var activeIndex = -1
    private(set) var position: Double = 0
    private(set) var mediaCount = 0
    private(set) var scrollOffset: CGFloat = 0
    private var dateScale = CompressedDateScale(inputs: [], totalLength: 0)
    private var coordinateOrigin: Double = 0
    private var dark = false
    private var reduceMotion = false
    private let wheelMotion = DateRulerWheelMotion()
    private var dragStart: CGPoint?
    private var dragOffset: CGFloat = 0
    private var didDrag = false
    var onNavigate: ((Int) -> Void)?
    var onNavigatePosition: ((Double) -> Void)?
    var onZoom: ((NSEvent) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !entries.isEmpty }
    private var blue: NSColor {
        dark ? NSColor(srgbRed: 143 / 255, green: 167 / 255, blue: 1, alpha: 1)
             : NSColor(srgbRed: 49 / 255, green: 91 / 255, blue: 1, alpha: 1)
    }
    private var maximumOffset: CGFloat { rulerCoordinate(for: Double(max(0, mediaCount - 1))) }
    private func rulerCoordinate(for mediaPosition: Double) -> CGFloat {
        CGFloat(dateScale.coordinate(for: mediaPosition) - coordinateOrigin)
    }
    private func mediaPosition(at offset: CGFloat) -> Double {
        dateScale.position(at: Double(min(maximumOffset, max(0, offset))) + coordinateOrigin)
    }
    var visibleDateIndices: Range<Int> {
        guard !entries.isEmpty else { return 0..<0 }
        let lower = Double(scrollOffset - bounds.width / 2 - 70) + coordinateOrigin
        let upper = Double(scrollOffset + bounds.width / 2 + 70) + coordinateOrigin
        // Date segments remain sorted after compression. Search in ruler
        // coordinates so visible work depends on the viewport, not file count.
        var low = 0, high = dateScale.segments.count
        while low < high {
            let middle = (low + high) / 2
            if dateScale.segments[middle].rulerEnd < lower { low = middle + 1 } else { high = middle }
        }
        let first = low
        while low < dateScale.segments.count, dateScale.segments[low].rulerStart <= upper { low += 1 }
        return first..<low
    }
    /// The current date and its year remain centred even in a long group.
    /// Other dates share this row, but do not repeat the year beneath them.
    var visibleDateLabels: [(index: Int, x: CGFloat, yearX: CGFloat)] {
        guard entries.indices.contains(activeIndex) else { return [] }
        var labels = [(index: activeIndex, x: bounds.midX, yearX: bounds.midX)]
        for index in visibleDateIndices.sorted(by: { abs($0 - activeIndex) == abs($1 - activeIndex) ? $0 < $1 : abs($0 - activeIndex) < abs($1 - activeIndex) }) where index != activeIndex {
            var x = x(at: Double(entries[index].firstItemIndex))
            if index == activeIndex - 1 { x = min(x, bounds.midX - 84) }
            if index == activeIndex + 1 { x = max(x, bounds.midX + 84) }
            guard x >= bounds.minX + 35, x <= bounds.maxX - 35,
                  labels.allSatisfy({ abs($0.x - x) >= 84 }) else { continue }
            labels.append((index: index, x: x, yearX: x))
        }
        return labels.sorted { $0.x < $1.x }
    }
    struct YearBoundaryLabel {
        let marker: DateRulerYearBoundaries.Marker
        let frame: NSRect
    }
    var visibleYearBoundaries: [YearBoundaryLabel] {
        guard entries.indices.contains(activeIndex) else { return [] }
        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        let activeRect = labelGeometry(for: (activeIndex, bounds.midX, bounds.midX)).yearRect.insetBy(dx: -7, dy: -2)
        var occupied = [activeRect]
        return DateRulerYearBoundaries.layout(indices: visibleDateIndices, activeIndex: activeIndex,
            lower: Double(bounds.minX), upper: Double(bounds.maxX), yearAt: { entries[$0].year },
            positionAt: { x(at: Double(entries[$0].firstItemIndex) - 0.5) }).compactMap { marker in
                let size = (marker.year as NSString).size(withAttributes: [.font: font])
                let x = CGFloat(marker.position)
                var candidates = [x + 7, x - size.width - 7]
                if abs(x - bounds.midX) < 60 { candidates += [activeRect.maxX + 4, activeRect.minX - size.width - 4] }
                guard let frame = candidates.map({ NSRect(x: $0, y: 36, width: size.width, height: size.height) })
                    .first(where: { frame in bounds.contains(frame) && occupied.allSatisfy { !$0.intersects(frame) } }) else { return nil }
                occupied.append(frame.insetBy(dx: -5, dy: 0))
                return YearBoundaryLabel(marker: marker, frame: frame)
            }
    }
    /// Every line represents a real date. Labelled dates own a major tick at
    /// the exact label coordinate; unlabelled dates add only sparse minor ticks.
    var visibleTicks: [QuietDateRulerTicks.Tick] {
        QuietDateRulerTicks.layout(
            dateAnchors: visibleDateIndices.map {
                .init(index: $0, position: Double(x(at: Double(entries[$0].firstItemIndex))))
            },
            labelAnchors: visibleDateLabels.map { .init(index: $0.index, position: Double($0.x)) },
            lower: Double(bounds.minX), upper: Double(bounds.maxX))
    }
    func x(at mediaPosition: Double) -> CGFloat { bounds.midX + rulerCoordinate(for: mediaPosition) - scrollOffset }
    func span(for index: Int) -> CGFloat {
        dateScale.segments.indices.contains(index) ? CGFloat(dateScale.segments[index].rulerLength) : 0
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = .init("filmbox.browse.date-ruler")
        focusRingType = .none
        setAccessibilityElement(true); setAccessibilityRole(.slider)
        setAccessibilityLabel("照片卷日期导航")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(entries: [BrowseDateEntry], activeIndex: Int, position: Double? = nil, mediaCount: Int? = nil,
                   dataChanged: Bool, reduceMotion: Bool, dark: Bool, zoom: Double = 180) {
        self.dark = dark; self.reduceMotion = reduceMotion
        if reduceMotion { wheelMotion.stop() }
        if dataChanged { stop(); self.entries = entries }
        let nextSpacing = Self.spacing(for: zoom)
        let nextCount = mediaCount ?? ((entries.map(\.lastItemIndex).max() ?? -1) + 1)
        if dataChanged || nextSpacing != tickSpacing || nextCount != self.mediaCount {
            tickSpacing = nextSpacing
            dateScale = CompressedDateScale(inputs: self.entries.map {
                .init(start: Double($0.firstItemIndex) - 0.5, length: Double($0.itemCount),
                      date: $0.startDate, count: $0.itemCount)
            }, totalLength: Double(nextCount) - 0.5, monthlyExtent: Double(Self.spacing),
               magnification: Double(tickSpacing / Self.spacing))
            coordinateOrigin = dateScale.coordinate(for: 0)
        }
        self.mediaCount = nextCount
        self.activeIndex = entries.indices.contains(activeIndex) ? activeIndex : -1
        let nextPosition = position ?? (self.activeIndex >= 0 ? Double(entries[self.activeIndex].firstItemIndex) : 0)
        self.position = nextPosition.isFinite ? min(Double(max(0, self.mediaCount - 1)), max(0, nextPosition)) : 0
        // Follow the exact scroll position, including fractions within a date;
        // an easing task here would lag behind a live wheel gesture.
        scrollOffset = rulerCoordinate(for: self.position)
        wheelMotion.reconcile(position: Double(scrollOffset))
        setAccessibilityEnabled(!entries.isEmpty)
        setAccessibilityMinValue(0); setAccessibilityMaxValue(max(0, self.mediaCount - 1))
        updateAccessibilityValue(); needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    private static func spacing(for zoom: Double) -> CGFloat {
        let value = zoom.isFinite ? min(280, max(64, zoom)) : 180
        let magnification = value <= 180
            ? 0.72 + (value - 64) / 116 * 0.28
            : 1 + (value - 180) / 100 * 0.6
        return Self.spacing * CGFloat(magnification)
    }
    func stop() { wheelMotion.stop(); dragStart = nil; didDrag = false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stop() } }
    override func resetCursorRects() { if !entries.isEmpty { addCursorRect(bounds, cursor: .openHand) } }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { wheelMotion.stop(); needsDisplay = true; return true }

    override func draw(_ dirtyRect: NSRect) {
        guard !entries.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        let secondary = dark
            ? NSColor(srgbRed: 169 / 255, green: 175 / 255, blue: 186 / 255, alpha: 1)
            : NSColor(srgbRed: 97 / 255, green: 105 / 255, blue: 116 / 255, alpha: 1)
        let marker = (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.24 : 0.19)
        for tick in visibleTicks {
            let depth = wheelDepth(at: CGFloat(tick.position))
            if tick.index == activeIndex {
                stroke(at: CGFloat(tick.position), from: 4, to: 15, color: blue, width: 1.5)
            } else {
                let base = tick.isMajor ? marker : marker.withAlphaComponent(dark ? 0.12 : 0.10)
                stroke(at: CGFloat(tick.position), from: 4, to: tick.isMajor ? 14 : 8,
                       color: base.withAlphaComponent(base.alphaComponent * depth.opacity))
            }
        }
        for label in visibleDateLabels {
            let geometry = labelGeometry(for: label)
            draw(entries[label.index].label, in: geometry.dateRect,
                 font: geometry.dateFont, color: label.index == activeIndex ? blue : secondary.withAlphaComponent(wheelDepth(at: label.x).opacity))
            if label.index == activeIndex {
                draw(entries[label.index].year, in: geometry.yearRect,
                     font: geometry.yearFont, color: secondary.withAlphaComponent(0.72))
            }
        }
        for boundary in visibleYearBoundaries {
            let x = CGFloat(boundary.marker.position)
            let current = labelGeometry(for: (activeIndex, bounds.midX, bounds.midX)).yearRect.insetBy(dx: -3, dy: 0)
            let nearCurrentYear = current.minX...current.maxX ~= x
            stroke(at: x, from: nearCurrentYear ? 4 : 35, to: nearCurrentYear ? 15 : 47, color: marker)
            draw(boundary.marker.year, in: boundary.frame,
                 font: .systemFont(ofSize: 9, weight: .medium), color: secondary.withAlphaComponent(0.72 * wheelDepth(at: x).opacity))
        }
    }
    private func wheelDepth(at x: CGFloat) -> DateRulerWheelStyle.Depth {
        DateRulerWheelStyle.depth(at: x, centre: bounds.midX, extent: bounds.width, reduceMotion: reduceMotion)
    }
    private func stroke(at x: CGFloat, from: CGFloat, to: CGFloat, color: NSColor, width: CGFloat = 1) {
        let path = NSBezierPath(); path.move(to: CGPoint(x: x, y: from)); path.line(to: CGPoint(x: x, y: to))
        path.lineWidth = width; color.setStroke(); path.stroke()
    }
    private struct LabelGeometry {
        let dateRect: NSRect
        let yearRect: NSRect
        let dateFont: NSFont
        let yearFont: NSFont
        var hitRect: NSRect { (yearRect.isEmpty ? dateRect : dateRect.union(yearRect)).insetBy(dx: -5, dy: -3) }
    }
    private func labelGeometry(for label: (index: Int, x: CGFloat, yearX: CGFloat)) -> LabelGeometry {
        let active = label.index == activeIndex
        let depth = wheelDepth(at: label.x)
        let dateFont = NSFont.monospacedDigitSystemFont(ofSize: active ? 12 : 10 * depth.scale, weight: active ? .semibold : .regular)
        let yearFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        func rect(_ text: String, x: CGFloat, y: CGFloat, font: NSFont) -> NSRect {
            let size = (text as NSString).size(withAttributes: [.font: font])
            return NSRect(x: x - size.width / 2, y: y, width: size.width, height: size.height)
        }
        return LabelGeometry(dateRect: rect(entries[label.index].label, x: label.x, y: active ? 19 : 21 + (1 - depth.scale) * 3, font: dateFont),
                             yearRect: label.index == activeIndex ? rect(entries[label.index].year, x: label.yearX, y: 36, font: yearFont) : .zero,
                             dateFont: dateFont, yearFont: yearFont)
    }
    func labelHitRect(for index: Int) -> NSRect? {
        visibleDateLabels.first { $0.index == index }.map { labelGeometry(for: $0).hitRect }
    }
    private func draw(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: rect.origin, withAttributes: [.font: font, .foregroundColor: color])
    }
    func position(at point: CGPoint) -> Double? {
        guard mediaCount > 0 else { return nil }
        return min(Double(mediaCount - 1), max(0, mediaPosition(at: scrollOffset + point.x - bounds.midX)))
    }
    func index(at point: CGPoint) -> Int? {
        guard let position = position(at: point), !entries.isEmpty else { return nil }
        // Membership uses the nearest photograph, matching the roll's cursor.
        let item = Int(position.rounded())
        var low = 0, high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].lastItemIndex < item { low = middle + 1 } else { high = middle }
        }
        return entries.indices.contains(low) ? low : nil
    }
    func selectDate(at point: CGPoint) {
        wheelMotion.stop()
        // A compact segment can be narrower than its label. The words own
        // their visible hit region; blank space and minor ticks remain a
        // continuous scrubber rather than unexpectedly choosing a nearby day.
        if let label = visibleDateLabels.first(where: { labelGeometry(for: $0).hitRect.contains(point) }) {
            navigate(to: label.index, center: true)
            return
        }
        guard let position = position(at: point) else { return }
        navigate(toPosition: position)
    }
    private func updateAccessibilityValue() {
        setAccessibilityValue(position)
        setAccessibilityValueDescription(activeIndex >= 0 ? entries[activeIndex].title : "无日期")
    }
    private func navigate(to index: Int, center: Bool) {
        guard entries.indices.contains(index) else { return }
        wheelMotion.noteDetent(from: activeIndex, to: index, enabled: window?.isKeyWindow == true && !reduceMotion)
        activeIndex = index; position = Double(entries[index].firstItemIndex)
        scrollOffset = rulerCoordinate(for: position)
        updateAccessibilityValue(); needsDisplay = true
        if let onNavigate { onNavigate(index) } else { onNavigatePosition?(position) }
    }
    private func navigate(toPosition position: Double) {
        guard mediaCount > 0 else { return }
        self.position = min(Double(mediaCount - 1), max(0, position))
        scrollOffset = rulerCoordinate(for: self.position)
        let nextIndex = index(at: CGPoint(x: bounds.midX, y: 0)) ?? -1
        wheelMotion.noteDetent(from: activeIndex, to: nextIndex, enabled: window?.isKeyWindow == true && !reduceMotion)
        activeIndex = nextIndex
        updateAccessibilityValue(); needsDisplay = true
        if let onNavigatePosition { onNavigatePosition(self.position) }
        else if activeIndex >= 0 { onNavigate?(activeIndex) }
    }
    override func scrollWheel(with event: NSEvent) {
        guard !entries.isEmpty else { return }
        wheelMotion.stop()
        if event.modifierFlags.contains(.command) { onZoom?(event); return }
        let axis = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let delta = event.hasPreciseScrollingDeltas ? axis : axis * 28
        navigate(toPosition: mediaPosition(at: scrollOffset - delta))
    }
    func beginScrubbing(at point: CGPoint, time: Double = ProcessInfo.processInfo.systemUptime) {
        wheelMotion.begin(at: Double(scrollOffset), time: time)
        dragStart = point; dragOffset = scrollOffset; didDrag = false
    }
    func scrub(to point: CGPoint, time: Double = ProcessInfo.processInfo.systemUptime) {
        guard let start = dragStart else { return }
        if abs(point.x - start.x) >= 3 { didDrag = true }
        guard didDrag else { return }
        navigate(toPosition: mediaPosition(at: dragOffset - (point.x - start.x)))
        wheelMotion.sample(at: Double(scrollOffset), time: time)
    }
    func endScrubbing(at point: CGPoint, time: Double = ProcessInfo.processInfo.systemUptime) {
        guard dragStart != nil else { return }
        if didDrag {
            scrub(to: point, time: time)
            wheelMotion.finish(time: time, reduceMotion: reduceMotion, maximumTravel: min(260, bounds.width * 0.4)) { [weak self] delta in
                guard let self, self.window != nil else { return nil }
                self.navigate(toPosition: self.mediaPosition(at: self.scrollOffset + delta))
                return Double(self.scrollOffset)
            }
        } else { selectDate(at: point) }
        dragStart = nil; didDrag = false
    }
    override func mouseDown(with event: NSEvent) {
        guard !entries.isEmpty, let window else { return }
        window.makeFirstResponder(self); NSCursor.closedHand.set()
        beginScrubbing(at: convert(event.locationInWindow, from: nil), time: event.timestamp)
    }
    override func mouseDragged(with event: NSEvent) { scrub(to: convert(event.locationInWindow, from: nil), time: event.timestamp) }
    override func mouseUp(with event: NSEvent) {
        endScrubbing(at: convert(event.locationInWindow, from: nil), time: event.timestamp); NSCursor.openHand.set()
    }
    override func keyDown(with event: NSEvent) {
        wheelMotion.stop()
        guard !entries.isEmpty else { super.keyDown(with: event); return }
        let index: Int
        switch event.keyCode {
        case 123, 126: index = max(0, activeIndex - 1)
        case 124, 125: index = min(entries.count - 1, max(0, activeIndex) + 1)
        case 115: index = 0
        case 119: index = entries.count - 1
        case 116: navigate(toPosition: mediaPosition(at: scrollOffset - bounds.width * 0.85)); return
        case 121: navigate(toPosition: mediaPosition(at: scrollOffset + bounds.width * 0.85)); return
        default: super.keyDown(with: event); return
        }
        navigate(to: index, center: true)
    }
    override func accessibilityPerformIncrement() -> Bool {
        wheelMotion.stop()
        guard activeIndex >= 0, activeIndex + 1 < entries.count else { return false }
        navigate(to: activeIndex + 1, center: true); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        wheelMotion.stop()
        guard activeIndex > 0 else { return false }
        navigate(to: activeIndex - 1, center: true); return true
    }
}
