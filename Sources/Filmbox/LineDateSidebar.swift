import AppKit
import SwiftUI
import FilmboxCore

/// Dates use a compact calendar scale while navigation retains the grid's
/// measured document coordinates, including progress within a single day.
struct LineDateSidebar: NSViewRepresentable {
    let store: AppStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LineDateRulerView {
        let view = LineDateRulerView()
        view.onSelectDate = { [weak store] in store?.scroll(toSection: $0) }
        view.onNavigate = { [weak store] in store?.navigateGridTimeline(to: $0) }
        view.onZoom = { [weak store] in store?.zoomTimeline(with: $0) }
        return view
    }

    func updateNSView(_ view: LineDateRulerView, context: Context) {
        view.configure(sections: store.timelineSections, spans: store.gridDateSpans,
                       position: store.gridTimelinePosition, totalLength: store.gridTimelineTotalLength,
                       activeID: store.visibleTimelineSectionID, dark: scheme == .dark,
                       reduceMotion: reduceMotion, revision: store.timelineRevision)
    }

    static func dismantleNSView(_ view: LineDateRulerView, coordinator: ()) {
        view.stop()
        view.onNavigate = nil; view.onSelectDate = nil; view.onZoom = nil
    }
}

/// Real document spans stay intact for navigation. A month has a bounded
/// visual budget, so media-rich dates grow gently without hiding other years.
struct LineDateRulerGeometry: Equatable {
    struct Span: Equatable {
        let id: String
        let start: Double
        let length: Double
        var end: Double { start + length }
    }
    let spans: [Span]
    let totalLength: Double
    let position: Double
    let dateScale: CompressedDateScale
    var rulerPosition: Double { dateScale.coordinate(for: position) }

    init(spans source: [TimelineDateSpan], position: Double, totalLength: Double,
         sections: [TemporalSection] = []) {
        var seen = Set<String>()
        spans = source.compactMap { span in
            guard span.start.isFinite, span.length.isFinite, span.start >= 0, span.length > 0,
                  (span.start + span.length).isFinite, seen.insert(span.id).inserted else { return nil }
            return Span(id: span.id, start: span.start, length: span.length)
        }.sorted { $0.start < $1.start }
        let lastEnd = spans.last?.end ?? 0
        self.totalLength = max(lastEnd, totalLength.isFinite ? max(0, totalLength) : 0)
        self.position = min(self.totalLength, max(0, position.isFinite ? position : 0))
        let sectionByID = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let fallbackDate = Date(timeIntervalSinceReferenceDate: 0)
        dateScale = CompressedDateScale(inputs: spans.map { span in
            let section = sectionByID[span.id]
            return .init(start: span.start, length: span.length, date: section?.startDate ?? fallbackDate,
                         count: section?.items.count ?? 1)
        }, totalLength: self.totalLength, monthlyExtent: 52)
    }

    func y(forDocumentPosition value: Double, height: Double) -> Double {
        height / 2 + dateScale.coordinate(for: value) - rulerPosition
    }
    func documentPosition(atY y: Double, height: Double) -> Double {
        documentPosition(atRulerPosition: rulerPosition + y - height / 2)
    }
    func documentPosition(atRulerPosition value: Double) -> Double {
        min(totalLength, max(0, dateScale.position(at: value)))
    }
    func documentPosition(offsetByRulerPoints delta: Double) -> Double {
        documentPosition(atRulerPosition: rulerPosition + delta)
    }
    func replacingPosition(_ position: Double, totalLength: Double? = nil) -> Self {
        let length = max(spans.last?.end ?? 0, totalLength.flatMap { $0.isFinite ? max(0, $0) : nil } ?? self.totalLength)
        return Self(spans: spans, totalLength: length,
                    position: min(length, max(0, position.isFinite ? position : 0)), dateScale: dateScale)
    }
    private init(spans: [Span], totalLength: Double, position: Double, dateScale: CompressedDateScale) {
        self.spans = spans; self.totalLength = totalLength; self.position = position; self.dateScale = dateScale
    }
    func index(atDocumentPosition value: Double) -> Int? {
        guard !spans.isEmpty else { return nil }
        var low = 0, high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].start <= value { low = mid + 1 } else { high = mid }
        }
        return min(spans.count - 1, max(0, low - 1))
    }
    func visibleIndices(height: Double, padding: Double = 40) -> Range<Int> {
        guard !spans.isEmpty, height.isFinite, height > 0 else { return 0..<0 }
        let firstPosition = documentPosition(offsetByRulerPoints: -(height / 2 + padding))
        let lastPosition = documentPosition(offsetByRulerPoints: height / 2 + padding)
        let first = index(atDocumentPosition: firstPosition) ?? 0
        var low = first, high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].start <= lastPosition { low = mid + 1 } else { high = mid }
        }
        return first..<max(first, low)
    }
}

struct LineDateRulerEntry: Equatable {
    let id: String
    let title: String
    let label: String
    let year: String
    let count: Int
    init(section: TemporalSection) {
        id = section.id; title = section.title; count = section.items.count
        let date = Calendar.current.dateComponents([.year, .month, .day], from: section.startDate)
        year = String(date.year ?? 0)
        let month = date.month ?? 1, day = date.day ?? 1
        if section.id.hasPrefix("month:") { label = "\(month)月" }
        else if section.id.hasPrefix("week:") { label = "\(month).\(day) 周" }
        else { label = "\(month)月\(day)日" }
    }
}

/// Native calendar navigation draws only visible dates. Hover highlights the
/// hit-tested date using the same bounds as clicks and accessibility.
@MainActor final class LineDateRulerView: NSView {
    private(set) var geometry = LineDateRulerGeometry(spans: [], position: 0, totalLength: 0)
    private(set) var entries: [LineDateRulerEntry] = []
    private(set) var activeIndex = -1
    private var dark = false
    private var reduceMotion = false
    private var hoveredIndex: Int?
    private var tracking: NSTrackingArea?
    private var dragStart: CGPoint?
    private var dragPosition = 0.0
    private var didDrag = false
    private let wheelMotion = DateRulerWheelMotion()
    private var sourceSpans: [TimelineDateSpan] = []
    private var sectionRevision = -1
    private var indexByID: [String: Int] = [:]
    private var dateElements: [LineDateAccessibleDate] = []
    private(set) var rebuildCount = 0
    var onSelectDate: ((String) -> Void)?
    var onNavigate: ((Double) -> Void)?
    var onZoom: ((NSEvent) -> Void)?
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { true }
    override var acceptsFirstResponder: Bool { !entries.isEmpty }
    var visibleDateIndices: Range<Int> { geometry.visibleIndices(height: bounds.height) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = .init("filmbox.grid.date-ruler")
        focusRingType = .none
        clipsToBounds = true
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("日期导航")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(sections: [TemporalSection], spans: [TimelineDateSpan], position: Double,
                   totalLength: Double, activeID: String?, dark: Bool, reduceMotion: Bool, revision: Int = 0) {
        let changed = sectionRevision != revision || sourceSpans != spans
            || (totalLength.isFinite && max(geometry.spans.last?.end ?? 0, max(0, totalLength)) != geometry.totalLength)
        if changed {
            if sectionRevision != revision { wheelMotion.stop(); dragStart = nil; didDrag = false }
            let ids = Set(sections.map(\.id))
            let next = LineDateRulerGeometry(spans: spans.filter { ids.contains($0.id) },
                                            position: position, totalLength: totalLength, sections: sections)
            let sectionByID = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if sectionRevision != revision || entries.map(\.id) != next.spans.map(\.id) {
                entries = next.spans.compactMap { sectionByID[$0.id].map(LineDateRulerEntry.init) }
                indexByID = Dictionary(entries.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
                dateElements = entries.indices.map { LineDateAccessibleDate(owner: self, index: $0) }
                setAccessibilityChildren(dateElements)
                rebuildCount += 1
            }
            hoveredIndex = nil
            geometry = next
            sourceSpans = spans; sectionRevision = revision
        } else {
            geometry = geometry.replacingPosition(position, totalLength: totalLength)
        }
        self.dark = dark; self.reduceMotion = reduceMotion
        activeIndex = activeID.flatMap { indexByID[$0] }
            ?? geometry.index(atDocumentPosition: geometry.position) ?? -1
        if reduceMotion { wheelMotion.stop() }
        wheelMotion.reconcile(position: geometry.rulerPosition)
        setAccessibilityEnabled(!entries.isEmpty)
        setAccessibilityMinValue(0); setAccessibilityMaxValue(max(0, entries.count - 1))
        updateAccessibilityValue()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func stop() {
        wheelMotion.stop(); dragStart = nil; didDrag = false; hoveredIndex = nil
    }
    override func resetCursorRects() {
        if !entries.isEmpty { addCursorRect(bounds, cursor: .openHand) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { wheelMotion.stop(); needsDisplay = true; return true }
    override func mouseMoved(with event: NSEvent) {
        hoveredIndex = visibleLabels.first { $0.frame.contains(convert(event.locationInWindow, from: nil)) }?.index
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hoveredIndex = nil; needsDisplay = true }

    private var blue: NSColor {
        dark ? NSColor(srgbRed: 143 / 255, green: 167 / 255, blue: 1, alpha: 1)
             : NSColor(srgbRed: 49 / 255, green: 91 / 255, blue: 1, alpha: 1)
    }
    private var secondary: NSColor {
        dark ? NSColor(srgbRed: 169 / 255, green: 175 / 255, blue: 186 / 255, alpha: 1)
             : NSColor(srgbRed: 97 / 255, green: 105 / 255, blue: 116 / 255, alpha: 1)
    }
    private var marker: NSColor { (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.28 : 0.25) }

    private struct LabelLayout {
        let index: Int
        let y: Double
        let frame: CGRect
    }
    private func labelLayout(at index: Int) -> LabelLayout {
        let naturalY = geometry.y(forDocumentPosition: geometry.spans[index].start, height: bounds.height)
        var y = index == activeIndex ? max(16, min(bounds.height - 28, naturalY)) : naturalY
        if entries.indices.contains(activeIndex), abs(index - activeIndex) == 1 {
            let activeNatural = geometry.y(forDocumentPosition: geometry.spans[activeIndex].start, height: bounds.height)
            let center = max(16, min(bounds.height - 28, activeNatural))
            y = index < activeIndex ? min(y, center - 30) : max(y, center + 40)
        }
        return LabelLayout(index: index, y: y,
                           frame: CGRect(x: 6, y: y - 8, width: max(0, bounds.width - 12), height: index == activeIndex ? 28 : 15))
    }
    struct YearBoundaryLabel {
        let marker: DateRulerYearBoundaries.Marker
        let frame: CGRect
    }
    var visibleYearBoundaries: [YearBoundaryLabel] {
        guard entries.indices.contains(activeIndex) else { return [] }
        let active = labelLayout(at: activeIndex).frame.insetBy(dx: 0, dy: -4)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        var occupied = [active]
        return DateRulerYearBoundaries.layout(indices: visibleDateIndices, activeIndex: activeIndex,
            lower: 0, upper: bounds.height, yearAt: { entries[$0].year },
            positionAt: { geometry.y(forDocumentPosition: geometry.spans[$0].start, height: bounds.height) })
            .compactMap { marker in
                let size = (marker.year as NSString).size(withAttributes: [.font: font])
                // Normally a caption sits just above the divider. At the
                // current date, choose its other side to keep both readable.
                var candidates = [marker.position - 22, marker.position + 8]
                if abs(marker.position - active.midY) < 60 {
                    candidates += [active.minY - size.height - 4, active.maxY + 4]
                }
                guard let frame = candidates.map({ CGRect(x: 36, y: $0, width: size.width, height: size.height) })
                    .first(where: { frame in bounds.contains(frame) && occupied.allSatisfy { !$0.intersects(frame) } }) else { return nil }
                occupied.append(frame.insetBy(dx: 0, dy: -4))
                return YearBoundaryLabel(marker: marker, frame: frame)
            }
    }
    private var visibleLabels: [LabelLayout] {
        let active = entries.indices.contains(activeIndex) ? labelLayout(at: activeIndex) : nil
        var result: [LabelLayout] = []
        let yearBoundaries = visibleYearBoundaries
        var indices = Set(visibleDateIndices)
        if active != nil { indices.insert(activeIndex) }
        for index in indices.sorted(by: { abs($0 - activeIndex) == abs($1 - activeIndex) ? $0 < $1 : abs($0 - activeIndex) < abs($1 - activeIndex) }) where entries.indices.contains(index) {
            let label = labelLayout(at: index)
            guard label.frame.intersects(bounds) else { continue }
            if index != activeIndex {
                if yearBoundaries.contains(where: { $0.frame.insetBy(dx: -4, dy: -4).intersects(label.frame) }) { continue }
                if let active, label.frame.intersects(active.frame.insetBy(dx: 0, dy: -4)) { continue }
                if result.contains(where: { $0.frame.insetBy(dx: 0, dy: -4).intersects(label.frame) }) { continue }
            }
            result.append(label)
        }
        return result.sorted { $0.y < $1.y }
    }
    /// Drawing, physical clicks and accessibility share the same label frame,
    /// including an active date pinned within a very long interval.
    func labelFrame(atIndex index: Int) -> CGRect? {
        visibleLabels.first { $0.index == index }?.frame
    }

    /// Only real dates contribute ticks. Labeled dates own the prominent
    /// marks, including the current label when it is pinned into the viewport.
    var visibleRulerTicks: [QuietDateRulerTicks.Tick] {
        QuietDateRulerTicks.layout(
            dateAnchors: visibleDateIndices.compactMap { index in
                guard entries.indices.contains(index) else { return nil }
                return .init(index: index, position: geometry.y(
                    forDocumentPosition: geometry.spans[index].start, height: bounds.height))
            },
            labelAnchors: visibleLabels.map { .init(index: $0.index, position: $0.y) },
            lower: 0, upper: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        (dark ? NSColor(srgbRed: 23 / 255, green: 25 / 255, blue: 29 / 255, alpha: 1)
              : NSColor(srgbRed: 245 / 255, green: 246 / 255, blue: 247 / 255, alpha: 1)).setFill()
        bounds.intersection(dirtyRect).fill()
        guard !entries.isEmpty else { return }
        for tick in visibleRulerTicks {
            let active = tick.isMajor && tick.index == activeIndex
            let depth = wheelDepth(at: tick.position)
            let base = tick.isMajor ? marker : marker.withAlphaComponent(dark ? 0.10 : 0.09)
            let hovered = tick.isMajor && tick.index == hoveredIndex
            let color = active ? blue : base.withAlphaComponent((hovered ? 0.5 : base.alphaComponent) * depth.opacity)
            drawLine(at: tick.position, length: tick.isMajor ? 18 : 5,
                     color: color, width: active ? 1.5 : 1)
        }
        // Keep the current date readable while its long interval passes
        // through the viewport. Other labels remain on their actual tick.
        for label in visibleLabels {
            let index = label.index, active = index == activeIndex
            let depth = wheelDepth(at: label.y)
            let base = index == hoveredIndex ? (dark ? NSColor.white : NSColor.black) : secondary
            let color = active ? blue : base.withAlphaComponent(depth.opacity)
            draw(entries[index].label, at: CGPoint(x: 36 + (1 - depth.scale) * 10, y: label.y - 8),
                 font: .monospacedDigitSystemFont(ofSize: active ? 12 : 11 * depth.scale,
                                                 weight: active ? .semibold : .regular), color: color)
            if active {
                draw(entries[index].year, at: CGPoint(x: 36, y: label.y + 7),
                     font: .monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                     color: secondary.withAlphaComponent(0.7))
            }
        }
        for boundary in visibleYearBoundaries {
            if abs(boundary.marker.position - labelLayout(at: activeIndex).y) > 2 {
                drawLine(at: boundary.marker.position, length: 18, color: marker, width: 1)
            }
            draw(boundary.marker.year, at: boundary.frame.origin,
                 font: .monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                 color: secondary.withAlphaComponent(0.7 * wheelDepth(at: boundary.marker.position).opacity))
        }
        if window?.firstResponder === self, activeIndex >= 0 {
            let dot = NSBezierPath(ovalIn: CGRect(x: bounds.width - 9, y: bounds.midY - 2, width: 4, height: 4))
            secondary.setFill(); dot.fill()
        }
    }

    private func wheelDepth(at y: CGFloat) -> DateRulerWheelStyle.Depth {
        DateRulerWheelStyle.depth(at: y, centre: bounds.midY, extent: bounds.height, reduceMotion: reduceMotion)
    }
    private func drawLine(at y: Double, length: Double, color: NSColor, width: Double) {
        guard y >= -1, y <= bounds.height + 1 else { return }
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 8, y: y)); path.line(to: CGPoint(x: 8 + length, y: y))
        path.lineWidth = width; color.setStroke(); path.stroke()
    }
    private func draw(_ text: String, at point: CGPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
    func index(at point: CGPoint) -> Int? {
        if let label = visibleLabels.first(where: { $0.frame.contains(point) }) { return label.index }
        return geometry.index(atDocumentPosition: geometry.documentPosition(atY: point.y, height: bounds.height))
    }
    func selectDate(at point: CGPoint) {
        wheelMotion.stop()
        guard let index = index(at: point) else { return }
        navigate(toDate: index)
    }
    private func updateAccessibilityValue() {
        setAccessibilityValue(max(0, activeIndex))
        setAccessibilityValueDescription(entries.indices.contains(activeIndex)
            ? "\(entries[activeIndex].title)，\(entries[activeIndex].count) 项" : "无日期")
    }
    private func navigate(toDate index: Int) {
        wheelMotion.stop()
        guard entries.indices.contains(index) else { return }
        wheelMotion.noteDetent(from: activeIndex, to: index, enabled: window?.isKeyWindow == true && !reduceMotion)
        onSelectDate?(entries[index].id)
    }
    @discardableResult func selectDate(atIndex index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        navigate(toDate: index); return true
    }
    private func navigate(toPosition position: Double) {
        let next = geometry.replacingPosition(position)
        geometry = next
        let nextIndex = next.index(atDocumentPosition: next.position) ?? -1
        wheelMotion.noteDetent(from: activeIndex, to: nextIndex, enabled: window?.isKeyWindow == true && !reduceMotion)
        activeIndex = nextIndex
        updateAccessibilityValue(); needsDisplay = true
        onNavigate?(next.position)
    }
    override func scrollWheel(with event: NSEvent) {
        guard !entries.isEmpty else { return }
        wheelMotion.stop()
        if event.modifierFlags.contains(.command) { onZoom?(event); return }
        let axis = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        let delta = event.hasPreciseScrollingDeltas ? axis : axis * 24
        navigate(toPosition: geometry.documentPosition(offsetByRulerPoints: -delta))
    }
    func beginScrubbing(at point: CGPoint, time: Double = ProcessInfo.processInfo.systemUptime) {
        wheelMotion.begin(at: geometry.rulerPosition, time: time)
        dragStart = point; dragPosition = geometry.rulerPosition; didDrag = false
    }
    func scrub(to point: CGPoint, time: Double = ProcessInfo.processInfo.systemUptime) {
        guard let start = dragStart else { return }
        if abs(point.y - start.y) >= 3 { didDrag = true }
        guard didDrag else { return }
        navigate(toPosition: geometry.documentPosition(atRulerPosition: dragPosition - (point.y - start.y)))
        wheelMotion.sample(at: geometry.rulerPosition, time: time)
    }
    func endScrubbing(at point: CGPoint, time: Double = ProcessInfo.processInfo.systemUptime) {
        guard dragStart != nil else { return }
        if didDrag {
            scrub(to: point, time: time)
            wheelMotion.finish(time: time, reduceMotion: reduceMotion, maximumTravel: min(220, bounds.height * 0.4)) { [weak self] delta in
                guard let self, self.window != nil else { return nil }
                self.navigate(toPosition: self.geometry.documentPosition(offsetByRulerPoints: delta))
                return self.geometry.rulerPosition
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
        switch event.keyCode {
        case 123, 126: navigate(toDate: max(0, activeIndex - 1))
        case 124, 125: navigate(toDate: min(entries.count - 1, max(0, activeIndex) + 1))
        case 115: navigate(toDate: 0)
        case 119: navigate(toDate: entries.count - 1)
        case 116: navigate(toPosition: geometry.documentPosition(offsetByRulerPoints: -bounds.height * 0.75))
        case 121: navigate(toPosition: geometry.documentPosition(offsetByRulerPoints: bounds.height * 0.75))
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard activeIndex >= 0, activeIndex + 1 < entries.count else { return false }
        navigate(toDate: activeIndex + 1); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard activeIndex > 0 else { return false }
        navigate(toDate: activeIndex - 1); return true
    }
}

/// Retain every date as an accessible button, including dates outside the
/// painted viewport. VoiceOver can navigate or activate any date directly.
@MainActor private final class LineDateAccessibleDate: NSAccessibilityElement {
    private nonisolated let state: LineDateAccessibleState
    init(owner: LineDateRulerView, index: Int) {
        state = LineDateAccessibleState(owner: owner, index: index)
        super.init()
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityEnabled(true)
        setAccessibilityParent(owner)
        setAccessibilityLabel(owner.entries[index].title)
        setAccessibilityValue("\(owner.entries[index].count) 项")
    }
    override func accessibilityPerformPress() -> Bool {
        let state = state
        return MainActor.assumeIsolated { state.owner?.selectDate(atIndex: state.index) ?? false }
    }
    override func isAccessibilitySelected() -> Bool {
        let state = state
        return MainActor.assumeIsolated { state.owner?.activeIndex == state.index }
    }
    override func accessibilityFrame() -> NSRect {
        let state = state
        return MainActor.assumeIsolated {
            let index = state.index
            guard let owner = state.owner, let labelFrame = owner.labelFrame(atIndex: index),
                  let window = owner.window else { return .zero }
            let frame = owner.convert(labelFrame, to: nil)
            return window.convertToScreen(frame)
        }
    }
}

@MainActor private final class LineDateAccessibleState {
    weak var owner: LineDateRulerView?
    let index: Int
    init(owner: LineDateRulerView, index: Int) { self.owner = owner; self.index = index }
}
