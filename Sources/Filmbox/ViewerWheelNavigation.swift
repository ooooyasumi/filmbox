import AppKit
import SwiftUI

/// A physical wheel notch advances once. A trackpad gesture advances at most
/// once, and its subsequent momentum never cascades through the catalogue.
struct ViewerWheelGate {
    private var accumulated: CGFloat = 0
    private var switched = false
    private var lastEvent: TimeInterval = -.infinity
    private var lastSwitch: TimeInterval = -.infinity

    mutating func consume(delta: CGFloat, precise: Bool, phase: NSEvent.Phase,
                          momentum: NSEvent.Phase, timestamp: TimeInterval) -> Int? {
        guard delta.isFinite, timestamp.isFinite else { return nil }
        guard momentum.isEmpty else { return nil }
        if phase.contains(.began) || (phase.isEmpty && timestamp - lastEvent > 0.35) {
            accumulated = 0; switched = false
        }
        lastEvent = timestamp
        if phase.contains(.ended) || phase.contains(.cancelled) { accumulated = 0; return nil }
        guard abs(delta) > 0.001 else { return nil }
        if precise {
            guard !switched else { return nil }
            if accumulated * delta < 0 { accumulated = 0 }
            accumulated += delta
            guard abs(accumulated) >= 36 else { return nil }
        }
        guard timestamp - lastSwitch >= 0.20 else { return nil }
        lastSwitch = timestamp
        switched = precise
        accumulated = 0
        return delta < 0 ? 1 : -1
    }
}

struct ViewerWheelNavigation: NSViewRepresentable {
    let onStep: (Int) -> Void
    func makeNSView(context: Context) -> ViewerWheelView { let view = ViewerWheelView(); view.onStep = onStep; return view }
    func updateNSView(_ view: ViewerWheelView, context: Context) { view.onStep = onStep }
    static func dismantleNSView(_ view: ViewerWheelView, coordinator: ()) { view.tearDown() }
}

@MainActor final class ViewerWheelView: NSView {
    var onStep: ((Int) -> Void)?
    private var monitor: Any?
    private var gate = ViewerWheelGate()
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tearDownMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) == true }
            return consumed ? nil : event
        }
    }
    @discardableResult func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.option),
              visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return false }
        // Leave sliders and other native player controls their ordinary events.
        var hit: NSView?
        if let content = window.contentView { hit = content.hitTest(content.convert(event.locationInWindow, from: nil)) }
        while let view = hit {
            if view is NSControl { return false }
            hit = view.superview
        }
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        if let direction = gate.consume(delta: delta, precise: event.hasPreciseScrollingDeltas,
                                        phase: event.phase, momentum: event.momentumPhase, timestamp: event.timestamp) {
            onStep?(direction)
        }
        return true
    }
    private func tearDownMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    func tearDown() { tearDownMonitor(); onStep = nil; gate = ViewerWheelGate() }
}
