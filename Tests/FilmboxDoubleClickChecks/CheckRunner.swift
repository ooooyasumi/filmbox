import AppKit
import FilmboxCore
import Foundation
@testable import Filmbox

/// Exercise the actual local-monitor gate against native hidden windows. No
/// event is posted to the system, and no window is ordered or activated.
@main
@MainActor
private struct DoubleClickChecks {
    private static var passed = 0

    static func main() {
        do { try run() }
        catch {
            print("FAIL \(error)")
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        _ = NSApplication.shared
        try firstClickOnlyInspects()
        try videoControlDoesNotOpenViewer()
        try inspectorReflowRetainsOriginalTarget(layout: .grid)
        try inspectorReflowRetainsOriginalTarget(layout: .browse)
        try releaseIsConsumedOnce(viewerWindow: false)
        try releaseIsConsumedOnce(viewerWindow: true)
        try unrelatedLateReleasePasses()
        try newSingleGestureAfterMissingReleasePasses()
        try reject("超出系统间隔的第二击不复活旧照片") { fixture in
            fixture.second(timestamp: fixture.firstTimestamp + NSEvent.doubleClickInterval + 0.01)
        }
        try reject("时间倒退的第二击不打开照片") { fixture in
            fixture.second(timestamp: fixture.firstTimestamp - 0.01)
        }
        try reject("超出位置容差的第二击不打开照片") { fixture in
            fixture.second(point: fixture.point.applyingOffset(x: 4.1, y: 0))
        }
        try reject("斜向位移超出容差时不误认同一双击") { fixture in
            fixture.second(point: fixture.point.applyingOffset(x: 3, y: 3))
        }
        try acceptsSmallPointerMotion()
        try rejectAfterMutation("可见数据改变后不打开过期首击目标") { fixture in
            fixture.store.visibleRevision += 1
        }
        try rejectAfterMutation("切换选择模式再返回后不复活旧双击") { fixture in
            fixture.store.setSelectionMode(true)
            fixture.store.setSelectionMode(false)
        }
        try rejectAfterMutation("原照片被移出可见集合后不打开") { fixture in
            fixture.store.visibleItems.removeAll { $0.id == fixture.first.id }
        }
        try wrongStoreCannotOpen()
        try differentWindowCannotOpen()
        try eventFromDifferentWindowPasses()
        try invalidRecordDoesNotArm()
        try explicitCancelInvalidatesClick()
        try cancellingOtherStoreDoesNotInvalidateClick()
        try cancelByInput(.keyDown, name: "键盘操作取消等待中的双击")
        try cancelByInput(.scrollWheel, name: "滚轮操作取消等待中的双击")
        try cancelByInput(.rightMouseDown, name: "右键操作取消等待中的双击")
        try newSingleDownInvalidatesPreviousClick()
        try existingViewerReopensOriginalTarget(layout: .grid, sameItem: true)
        try existingViewerReopensOriginalTarget(layout: .grid, sameItem: false)
        try existingViewerReopensOriginalTarget(layout: .browse, sameItem: true)
        try existingViewerReopensOriginalTarget(layout: .browse, sameItem: false)
        try tripleClickIsNotDoubleClick()
        print("\(passed)/\(passed) 双击事件门禁检查通过")
    }

    private static func videoControlDoesNotOpenViewer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        fixture.revealInspector()
        fixture.inspector.identifier = .init("grid-video-controls")
        let button = NSButton(frame: fixture.inspector.bounds)
        fixture.inspector.addSubview(button)
        let second = fixture.second()
        let request = fixture.store.viewerOpenRequestID
        try check(tracker.handle(second, store: fixture.store, window: fixture.window) === second
                  && fixture.store.viewerOpenRequestID == request && fixture.store.previewID == nil,
                  "单击后出现的视频控制区域保留自己的点击，不被旧首击误认为打开查看器")
    }

    private static func firstClickOnlyInspects() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        let down = fixture.mouse(.leftMouseDown, count: 1, timestamp: fixture.firstTimestamp - 0.01)
        let up = fixture.mouse(.leftMouseUp, count: 1, timestamp: fixture.firstTimestamp)
        let initialRevision = fixture.store.visibleRevision
        let initialOpenRequest = fixture.store.viewerOpenRequestID
        try require(tracker.handle(down, store: fixture.store, window: fixture.window) === down,
                    "监控不能拦截首击按下")
        fixture.store.activate(fixture.first)
        try require(tracker.handle(up, store: fixture.store, window: fixture.window) === up,
                    "监控不能拦截首击松开")
        tracker.record(item: fixture.first, store: fixture.store, event: up)
        try check(fixture.store.previewID == nil && fixture.store.showInspector
                  && fixture.store.selectedIDs == [fixture.first.id]
                  && fixture.store.focusedItem?.id == fixture.first.id
                  && fixture.store.visibleRevision == initialRevision
                  && fixture.store.viewerOpenRequestID == initialOpenRequest && !fixture.window.isVisible,
                  "普通首击完整传递，单选并显示信息，不打开查看器或显示测试窗口")
    }

    private static func inspectorReflowRetainsOriginalTarget(layout: AppStore.Layout) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.store.layout = layout
        let tracker = MediaDoubleClickTracker()
        let firstHit = fixture.root.hitTest(fixture.point)
        try require(firstHit === fixture.photo, "原点击点必须位于照片区域")
        fixture.completeFirstClick(tracker)
        fixture.revealInspector()
        try require(fixture.root.hitTest(fixture.point) === fixture.inspector,
                    "信息栏必须真实覆盖原点击点，不能仅修改尺寸数值")
        let second = fixture.second()
        if let forwarded = tracker.handle(second, store: fixture.store, window: fixture.window) {
            fixture.root.hitTest(forwarded.locationInWindow)?.mouseDown(with: forwarded)
        }
        try check(fixture.store.previewID == fixture.first.id
                  && fixture.store.selectedIDs == [fixture.first.id]
                  && fixture.inspector.downCount == 0 && !fixture.window.isVisible,
                  "\(layout.rawValue)首击打开信息栏并覆盖原位置后，第二击打开首击照片且不触发信息栏")
    }

    private static func releaseIsConsumedOnce(viewerWindow: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        let down = fixture.second()
        try require(tracker.handle(down, store: fixture.store, window: fixture.window) == nil,
                    "有效第二次按下必须先被消费")
        let target = viewerWindow ? fixture.otherWindow : fixture.window
        let up = fixture.mouse(.leftMouseUp, count: 2, timestamp: down.timestamp + 0.01, window: target)
        let handled = tracker.handle(up, store: fixture.store, window: fixture.window)
        let following = fixture.mouse(.leftMouseUp, count: 1, timestamp: up.timestamp + 0.01, window: target)
        try check(handled == nil
                  && tracker.handle(following, store: fixture.store, window: fixture.window) === following,
                  viewerWindow ? "第二击打开查看器后，发到查看器窗口的对应松开只消费一次"
                               : "第二击对应的主窗口松开只消费一次，后续事件继续传递")
    }

    private static func unrelatedLateReleasePasses() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        let down = fixture.second()
        _ = tracker.handle(down, store: fixture.store, window: fixture.window)
        let late = fixture.mouse(.leftMouseUp, count: 1, timestamp: down.timestamp + 3)
        try check(tracker.handle(late, store: fixture.store, window: fixture.window) === late,
                  "长时间之后的无关松开不会被旧双击吞掉")
    }

    private static func newSingleGestureAfterMissingReleasePasses() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        let second = fixture.second()
        try require(tracker.handle(second, store: fixture.store, window: fixture.window) == nil,
                    "合法双击按下必须先被消费")
        // The double-click release can be lost when the pointer leaves the app.
        // A later, independent control click still owns its complete gesture,
        // even when it occurs within the old release's suppression interval.
        let down = fixture.mouse(.leftMouseDown, count: 1, timestamp: second.timestamp + 0.10,
                                 point: NSPoint(x: 680, y: 80), window: fixture.otherWindow)
        let up = fixture.mouse(.leftMouseUp, count: 1, timestamp: down.timestamp + 0.01,
                               point: NSPoint(x: 680, y: 80), window: fixture.otherWindow)
        let forwardedDown = tracker.handle(down, store: fixture.store, window: fixture.window)
        let forwardedUp = tracker.handle(up, store: fixture.store, window: fixture.window)
        try check(forwardedDown === down && forwardedUp === up,
                  "双击松开在应用外丢失后，下一次独立点击的按下和松开均正常传递")
    }

    private static func reject(_ name: String, event: (Fixture) -> NSEvent) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        let second = event(fixture)
        let result = tracker.handle(second, store: fixture.store, window: fixture.window)
        try check(result === second && fixture.store.previewID == nil, name)
    }

    private static func rejectAfterMutation(_ name: String, mutation: (Fixture) -> Void) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        mutation(fixture)
        let second = fixture.second()
        let result = tracker.handle(second, store: fixture.store, window: fixture.window)
        try check(result === second && fixture.store.previewID == nil, name)
    }

    private static func acceptsSmallPointerMotion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        let second = fixture.second(point: fixture.point.applyingOffset(x: 2, y: 2))
        try check(tracker.handle(second, store: fixture.store, window: fixture.window) == nil
                  && fixture.store.previewID == fixture.first.id,
                  "轻微手部位移仍可正常双击打开原照片")
    }

    private static func wrongStoreCannotOpen() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let otherStore = AppStore(directory: fixture.catalogDirectory)
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        let second = fixture.second()
        try check(tracker.handle(second, store: otherStore, window: fixture.window) === second
                  && fixture.store.previewID == nil && otherStore.previewID == nil,
                  "同一窗口中的不同资料库实例不能接走旧双击")
    }

    private static func differentWindowCannotOpen() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        let second = fixture.mouse(.leftMouseDown, count: 2, timestamp: fixture.secondTimestamp, window: fixture.otherWindow)
        try check(tracker.handle(second, store: fixture.store, window: fixture.otherWindow) === second
                  && fixture.store.previewID == nil,
                  "不同窗口即使坐标和资料库一致，也不能打开原窗口的首击照片")
    }

    private static func eventFromDifferentWindowPasses() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        let second = fixture.mouse(.leftMouseDown, count: 2, timestamp: fixture.secondTimestamp, window: fixture.otherWindow)
        try check(tracker.handle(second, store: fixture.store, window: fixture.window) === second
                  && fixture.store.previewID == nil,
                  "主窗口监控原样放过其他窗口的第二击")
    }

    private static func invalidRecordDoesNotArm() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.store.visibleItems.removeAll { $0.id == fixture.first.id }
        tracker.record(item: fixture.first, store: fixture.store,
                       event: fixture.mouse(.leftMouseUp, count: 1, timestamp: fixture.firstTimestamp))
        fixture.store.visibleItems.insert(fixture.first, at: 0)
        let second = fixture.second()
        try check(tracker.handle(second, store: fixture.store, window: fixture.window) === second
                  && fixture.store.previewID == nil,
                  "不可见照片不能登记成首击，即使稍后重新出现也不能直接打开")
    }

    private static func explicitCancelInvalidatesClick() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        tracker.cancel(store: fixture.store)
        let second = fixture.second()
        try check(tracker.handle(second, store: fixture.store, window: fixture.window) === second
                  && fixture.store.previewID == nil,
                  "组件退出或拖动取消后，旧首击不再打开照片")
    }

    private static func cancellingOtherStoreDoesNotInvalidateClick() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        tracker.cancel(store: AppStore(directory: fixture.catalogDirectory))
        try check(tracker.handle(fixture.second(), store: fixture.store, window: fixture.window) == nil
                  && fixture.store.previewID == fixture.first.id,
                  "其他资料库的取消请求不会破坏当前窗口的合法双击")
    }

    private static func cancelByInput(_ type: NSEvent.EventType, name: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        let intervening: NSEvent
        switch type {
        case .keyDown:
            intervening = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: fixture.firstTimestamp + 0.01,
                                           windowNumber: fixture.window.windowNumber, context: nil,
                                           characters: " ", charactersIgnoringModifiers: " ",
                                           isARepeat: false, keyCode: 49)!
        case .rightMouseDown:
            intervening = fixture.mouse(.rightMouseDown, count: 1, timestamp: fixture.firstTimestamp + 0.01)
        default:
            // Standalone CG scroll events have no AppKit window. This native
            // NSEvent envelope supplies the window association a local monitor
            // receives, without dispatching anything to the OS.
            intervening = WindowBoundWheel(window: fixture.window, timestamp: fixture.firstTimestamp + 0.01)
        }
        try require(tracker.handle(intervening, store: fixture.store, window: fixture.window) === intervening,
                    "取消输入本身不能被监控吞掉")
        let second = fixture.second()
        try check(tracker.handle(second, store: fixture.store, window: fixture.window) === second
                  && fixture.store.previewID == nil, name)
    }

    private static func newSingleDownInvalidatesPreviousClick() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        let fresh = fixture.mouse(.leftMouseDown, count: 1, timestamp: fixture.firstTimestamp + 0.01)
        try require(tracker.handle(fresh, store: fixture.store, window: fixture.window) === fresh,
                    "新首击必须继续交给媒体或控件处理")
        let second = fixture.second()
        try check(tracker.handle(second, store: fixture.store, window: fixture.window) === second
                  && fixture.store.previewID == nil,
                  "另一轮单击尚未完成时不能复用旧照片身份")
    }

    private static func existingViewerReopensOriginalTarget(layout: AppStore.Layout, sameItem: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.store.layout = layout
        let originalPreview = sameItem ? fixture.first : fixture.secondItem
        fixture.store.open(originalPreview)
        let previousRequest = fixture.store.viewerOpenRequestID
        let tracker = MediaDoubleClickTracker()
        try require(fixture.root.hitTest(fixture.point) === fixture.photo,
                    "已有查看器时，原点击点仍必须位于主窗口照片区域")
        fixture.completeFirstClick(tracker)
        try require(fixture.store.previewID == originalPreview.id
                    && fixture.store.viewerOpenRequestID == previousRequest,
                    "已有查看器时，主窗口首击只能选中，不能更新内容或发出置前请求")
        fixture.revealInspector()
        try require(fixture.root.hitTest(fixture.point) === fixture.inspector,
                    "已有查看器时，也必须验证信息栏真实覆盖原点击位置")
        let second = fixture.second()
        let result = tracker.handle(second, store: fixture.store, window: fixture.window)
        if let result { fixture.root.hitTest(result.locationInWindow)?.mouseDown(with: result) }
        try check(result == nil && fixture.store.previewID == fixture.first.id
                  && fixture.store.viewerOpenRequestID == previousRequest + 1
                  && fixture.store.selectedIDs == [fixture.first.id]
                  && fixture.inspector.downCount == 0 && !fixture.window.isVisible,
                  "\(layout.rawValue)已有查看器时双击\(sameItem ? "同一" : "新")照片，保留原目标并重新发出打开请求，不误触覆盖的信息栏")
    }

    private static func tripleClickIsNotDoubleClick() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = MediaDoubleClickTracker()
        fixture.completeFirstClick(tracker)
        let third = fixture.mouse(.leftMouseDown, count: 3, timestamp: fixture.secondTimestamp)
        try check(tracker.handle(third, store: fixture.store, window: fixture.window) === third
                  && fixture.store.previewID == nil,
                  "第三击不会被当成双击反复打开查看器")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        try require(condition(), description)
        passed += 1
        print("PASS \(description)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        if !condition() { throw CheckFailure.failed(description) }
    }
}

private enum CheckFailure: Error { case failed(String) }

@MainActor
private final class Fixture {
    let rootDirectory: URL
    let catalogDirectory: URL
    let first: MediaItem
    let secondItem: MediaItem
    let store: AppStore
    let window: NSWindow
    let otherWindow: NSWindow
    let root: NSView
    let photo: NSView
    let inspector: InspectorProbe
    let point = NSPoint(x: 820, y: 250)
    let firstTimestamp: TimeInterval = 20
    var secondTimestamp: TimeInterval { firstTimestamp + min(0.05, NSEvent.doubleClickInterval / 2) }

    init() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Filmbox-DoubleClickChecks-\(UUID().uuidString)", isDirectory: true)
        catalogDirectory = rootDirectory.appendingPathComponent("Catalog", isDirectory: true)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        first = MediaItem(url: rootDirectory.appendingPathComponent("first.jpg"), kind: .image,
                          fileSize: 1, modifiedDate: date, createdDate: date, pixelWidth: 1600, pixelHeight: 1200)
        secondItem = MediaItem(url: rootDirectory.appendingPathComponent("second.jpg"), kind: .image,
                               fileSize: 1, modifiedDate: date, createdDate: date, pixelWidth: 1600, pixelHeight: 1200)
        try CatalogPersistence(directory: catalogDirectory).save(CatalogState(cachedItems: [first, secondItem]))
        store = AppStore(directory: catalogDirectory)
        window = Self.makeWindow()
        otherWindow = Self.makeWindow()
        root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        photo = NSView(frame: root.bounds)
        inspector = InspectorProbe(frame: NSRect(x: 620, y: 0, width: 280, height: 500))
        root.addSubview(photo)
        window.contentView = root
    }

    private static func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 500),
                 styleMask: [.borderless], backing: .buffered, defer: false)
    }

    func completeFirstClick(_ tracker: MediaDoubleClickTracker) {
        store.activate(first)
        tracker.record(item: first, store: store,
                       event: mouse(.leftMouseUp, count: 1, timestamp: firstTimestamp))
    }

    func revealInspector() {
        photo.frame.size.width = 620
        root.addSubview(inspector)
    }

    func second(point: NSPoint? = nil, timestamp: TimeInterval? = nil) -> NSEvent {
        mouse(.leftMouseDown, count: 2, timestamp: timestamp ?? secondTimestamp, point: point)
    }

    func mouse(_ type: NSEvent.EventType, count: Int, timestamp: TimeInterval,
               point: NSPoint? = nil, window: NSWindow? = nil) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point ?? self.point, modifierFlags: [], timestamp: timestamp,
                           windowNumber: (window ?? self.window).windowNumber, context: nil,
                           eventNumber: 0, clickCount: count, pressure: 1)!
    }

    func remove() {
        window.contentView = nil
        otherWindow.contentView = nil
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

@MainActor
private final class InspectorProbe: NSView {
    var downCount = 0
    override func mouseDown(with event: NSEvent) { downCount += 1 }
}

private final class WindowBoundWheel: NSEvent {
    private let owner: NSWindow
    private let clock: TimeInterval
    init(window: NSWindow, timestamp: TimeInterval) {
        owner = window; clock = timestamp
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Not used by this check") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { owner }
    override var timestamp: TimeInterval { clock }
}

private extension NSPoint {
    func applyingOffset(x: CGFloat, y: CGFloat) -> NSPoint { NSPoint(x: self.x + x, y: self.y + y) }
}
