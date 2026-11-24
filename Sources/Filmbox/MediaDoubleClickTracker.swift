import AppKit
import SwiftUI
import FilmboxCore

/// Opening the inspector can move a photo out from under the first click.
/// Keep the completed click's identity until the matching OS double-click,
/// even when the second event would otherwise hit the new inspector.
@MainActor final class MediaDoubleClickTracker {
    static let shared = MediaDoubleClickTracker()
    @MainActor private final class Click {
        weak var store: AppStore?
        weak var window: NSWindow?
        let id: String
        let point: NSPoint
        let timestamp: TimeInterval
        let visibleRevision: Int
        let modeRevision: Int
        init(item: MediaItem, store: AppStore, event: NSEvent, window: NSWindow) {
            self.store = store; self.window = window; id = item.id
            point = event.locationInWindow; timestamp = event.timestamp
            visibleRevision = store.visibleRevision; modeRevision = store.selectionModeRevision
        }
    }
    private var click: Click?
    private var consumedDownAt: TimeInterval?

    func record(item: MediaItem, store: AppStore, event: NSEvent) {
        guard event.clickCount == 1, let window = event.window,
              store.visibleItems.contains(where: { $0.id == item.id }) else { return }
        click = Click(item: item, store: store, event: event, window: window)
    }
    func cancel(store: AppStore) {
        if click?.store === store { click = nil }
    }
    func handle(_ event: NSEvent, store: AppStore, window: NSWindow) -> NSEvent? {
        // A release can be lost outside the app. A new press starts a new
        // gesture and must never consume that gesture's unrelated release.
        if event.type == .leftMouseDown { consumedDownAt = nil }
        if event.type == .leftMouseUp, let down = consumedDownAt {
            consumedDownAt = nil
            // Opening a viewer can change which window receives this release.
            if event.timestamp >= down, event.timestamp - down <= 2 { return nil }
        }
        guard event.window === window else { return event }
        if event.type == .leftMouseDown, let content = window.contentView {
            var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
            while let view = hit {
                if view.identifier?.rawValue == "grid-video-controls" {
                    cancel(store: store)
                    return event
                }
                hit = view.superview
            }
        }
        guard event.type == .leftMouseDown else {
            if [.rightMouseDown, .keyDown, .scrollWheel, .magnify].contains(event.type) { cancel(store: store) }
            return event
        }
        guard event.clickCount == 2, let first = click, first.store === store, first.window === window,
              first.visibleRevision == store.visibleRevision, first.modeRevision == store.selectionModeRevision,
              event.timestamp >= first.timestamp, event.timestamp - first.timestamp <= NSEvent.doubleClickInterval,
              hypot(event.locationInWindow.x - first.point.x, event.locationInWindow.y - first.point.y) <= 4,
              window.attachedSheet == nil,
              let item = store.visibleItems.first(where: { $0.id == first.id }) else {
            cancel(store: store)
            return event
        }
        click = nil
        consumedDownAt = event.timestamp
        store.open(item)
        return nil
    }
}

struct MediaDoubleClickMonitor: NSViewRepresentable {
    let store: AppStore
    func makeNSView(context: Context) -> MediaDoubleClickMonitorView { MediaDoubleClickMonitorView(store: store) }
    func updateNSView(_ view: MediaDoubleClickMonitorView, context: Context) { }
    static func dismantleNSView(_ view: MediaDoubleClickMonitorView, coordinator: ()) { view.detach() }
}

@MainActor final class MediaDoubleClickMonitorView: NSView {
    private let store: AppStore
    private var monitor: Any?
    init(store: AppStore) { self.store = store; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        detach()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .keyDown, .scrollWheel, .magnify]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let window = self.window else { return false }
                return MediaDoubleClickTracker.shared.handle(event, store: self.store, window: window) == nil
            }
            return consumed ? nil : event
        }
    }
    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        MediaDoubleClickTracker.shared.cancel(store: store)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    isolated deinit { detach() }
}
