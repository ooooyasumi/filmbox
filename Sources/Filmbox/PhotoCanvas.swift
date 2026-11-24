import AppKit
import Observation
import QuartzCore
import SwiftUI
import FilmboxCore

enum ViewerZoomCommand: String {
    case zoomIn = "in"
    case zoomOut = "out"
    case fit
    case actualSize
}

extension Notification.Name {
    static let filmboxViewerZoom = Notification.Name("FilmboxViewerZoom")
}

enum PhotoCanvasKeyAction { case previous, next, close, toggleSlideshow }

@MainActor @Observable
final class PhotoZoomState {
    static let maximumScale = 8.0
    var scale = 1.0
    var isFitted = true
    var hasImage = false
    var minimumScale = 0.01
    @ObservationIgnored private weak var canvas: PhotoScrollView?
    var canZoomIn: Bool { hasImage && scale < Self.maximumScale - 0.001 }
    var canZoomOut: Bool { hasImage && scale > minimumScale * 1.001 }
    var percentage: String { String(format: scale < 0.1 ? "%.1f%%" : "%.0f%%", scale * 100) }
    // A logarithmic track gives ordinary viewing sizes useful travel while
    // preserving the canvas's complete zoom range and its current fit value.
    var sliderValue: Double {
        get {
            let lower = max(0.0001, minimumScale)
            let current = min(Self.maximumScale, max(lower, scale))
            return log(current / lower) / log(Self.maximumScale / lower)
        }
        set {
            guard hasImage, newValue.isFinite else { return }
            let lower = max(0.0001, minimumScale)
            setScale(lower * pow(Self.maximumScale / lower, min(1, max(0, newValue))))
        }
    }
    func perform(_ command: ViewerZoomCommand) { canvas?.perform(command) }
    func setScale(_ value: Double) {
        guard value.isFinite, let canvas else { return }
        // Slider bindings must read their applied value back in this event,
        // rather than waiting for the layout-safe asynchronous canvas report.
        scale = canvas.setPhotoScale(value)
        isFitted = false
    }
    fileprivate func attach(_ view: PhotoScrollView) { canvas = view }
    fileprivate func detach(_ view: PhotoScrollView) { if canvas === view { canvas = nil } }
    fileprivate func update(scale: Double, isFitted: Bool, hasImage: Bool, minimumScale: Double) {
        self.scale = scale; self.isFitted = isFitted
        self.hasImage = hasImage; self.minimumScale = minimumScale
    }
}

struct NativePhotoCanvas: NSViewRepresentable {
    let item: MediaItem
    let image: NSImage?
    let zoomState: PhotoZoomState
    var isProvisional = false
    var onKeyAction: (PhotoCanvasKeyAction) -> Void
    var onContextMenu: (() -> NSMenu)? = nil
    func makeNSView(context: Context) -> PhotoScrollView {
        let view = PhotoScrollView()
        view.zoomState = zoomState
        zoomState.attach(view)
        view.onKeyAction = onKeyAction
        view.onContextMenu = onContextMenu
        view.configure(item: item, image: image, isProvisional: isProvisional)
        return view
    }
    func updateNSView(_ view: PhotoScrollView, context: Context) {
        view.onKeyAction = onKeyAction
        view.onContextMenu = onContextMenu
        view.configure(item: item, image: image, isProvisional: isProvisional)
    }
    static func dismantleNSView(_ view: PhotoScrollView, coordinator: ()) { view.tearDown() }
}

@MainActor final class PhotoScrollView: NSScrollView {
    fileprivate weak var zoomState: PhotoZoomState?
    var onKeyAction: ((PhotoCanvasKeyAction) -> Void)?
    var onContextMenu: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?() }
    private let photoView = PhotoDocumentView()
    private var identity: String?
    private var originalPixels = CGSize(width: 1, height: 1)
    private var hasOriginalDimensions = false
    private var provisional = false
    // Keep the document's unscaled backing no larger than the 4096px preview.
    // 100% still uses original pixel proportions, without decoding the whole RAW.
    private var referenceRatio: CGFloat = 1
    private var fitted = true
    private var fitScale: CGFloat = 1
    private var lastViewport = CGSize.zero
    private var lastBackingScale: CGFloat = 0
    private var pendingResizeCenter: CGPoint?
    private var publishing = false
    private var tornDown = false
    override var acceptsFirstResponder: Bool { true }
    private var photoScale: CGFloat { magnification / referenceRatio }
    private var viewportCenter: CGPoint { CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY) }
    private var backingScale: CGFloat { max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true; hasHorizontalScroller = true
        autohidesScrollers = true; scrollerStyle = .overlay
        horizontalScrollElasticity = .none; verticalScrollElasticity = .none
        usesPredominantAxisScrolling = false
        allowsMagnification = true
        minMagnification = 0.001; maxMagnification = 64
        let clip = CenteredPhotoClipView()
        clip.drawsBackground = false
        contentView = clip
        documentView = photoView
        photoView.owner = self
        photoView.wantsLayer = true
        setAccessibilityLabel("照片查看器")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: MediaItem, image: NSImage?, isProvisional: Bool = false) {
        let nextIdentity = item.id + "|" + String(item.modifiedDate.timeIntervalSince1970.bitPattern)
            + "|" + String(item.fileSize) + "|" + (item.isLocal ? item.localFileStamp ?? "" : item.contentRevision ?? "")
        let changed = identity != nextIdentity
        if changed { identity = nextIdentity; fitted = true }
        let previousPixelsWereEstimated = !hasOriginalDimensions
        let pixels: CGSize
        let nextHasOriginalDimensions: Bool
        if let width = item.pixelWidth, let height = item.pixelHeight, width > 0, height > 0 {
            pixels = CGSize(width: width, height: height)
            nextHasOriginalDimensions = true
        } else if let representation = image?.representations.first, representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            pixels = CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
            nextHasOriginalDimensions = false
        } else {
            pixels = image?.size ?? CGSize(width: 1, height: 1)
            nextHasOriginalDimensions = false
        }
        let geometryChanged = changed || pixels != originalPixels || lastBackingScale != backingScale
            || provisional != isProvisional || hasOriginalDimensions != nextHasOriginalDimensions
        originalPixels = pixels
        hasOriginalDimensions = nextHasOriginalDimensions
        provisional = isProvisional
        if photoView.image !== image {
            // Keep the same canvas, zoom and pan while a provisional preview
            // becomes sharp. Never carry an old photo across a source change.
            if !changed, photoView.image != nil, image != nil,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let transition = CATransition()
                transition.type = .fade
                transition.duration = 0.18
                transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
                photoView.layer?.add(transition, forKey: "transition")
            } else { photoView.layer?.removeAnimation(forKey: "transition") }
            photoView.image = image
            photoView.needsDisplay = true
        }
        photoView.setAccessibilityLabel(item.name)
        if geometryChanged { updateGeometry(reset: changed, preserveRelativeFit: !changed && previousPixelsWereEstimated) }
        publishState()
    }

    override func layout() {
        super.layout()
        guard !tornDown else { return }
        let viewport = contentSize
        if abs(viewport.width - lastViewport.width) > 0.5 || abs(viewport.height - lastViewport.height) > 0.5 || lastBackingScale != backingScale {
            updateGeometry(reset: false)
        }
    }
    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size, identity != nil, pendingResizeCenter == nil {
            let size = photoView.bounds.size
            let center = viewportCenter
            pendingResizeCenter = CGPoint(x: size.width > 0 ? center.x / size.width : 0.5,
                                          y: size.height > 0 ? center.y / size.height : 0.5)
        }
        super.setFrameSize(newSize)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry(reset: false)
    }

    private func updateGeometry(reset: Bool, preserveRelativeFit: Bool = false) {
        guard !tornDown else { return }
        let previousScale = photoScale
        let previousFit = fitScale
        let previousSize = photoView.bounds.size
        let center = viewportCenter
        let fraction = pendingResizeCenter ?? CGPoint(x: previousSize.width > 0 ? center.x / previousSize.width : 0.5,
                                                     y: previousSize.height > 0 ? center.y / previousSize.height : 0.5)
        pendingResizeCenter = nil
        let longest = max(originalPixels.width, originalPixels.height, 1)
        referenceRatio = max(1, longest / 4096)
        let natural = CGSize(width: originalPixels.width / referenceRatio / backingScale,
                             height: originalPixels.height / referenceRatio / backingScale)
        lastViewport = contentSize
        lastBackingScale = backingScale
        if photoView.frame.size != natural { photoView.setFrameSize(natural) }
        let available = CGSize(width: max(1, lastViewport.width - 32), height: max(1, lastViewport.height - 24))
        // A temporary cover can be smaller than the viewport. Fit it to the
        // same viewing area as the coming original without inventing metadata.
        let fitLimit: CGFloat = provisional && !hasOriginalDimensions ? 8 : 1
        fitScale = min(fitLimit, min(available.width / max(1, natural.width), available.height / max(1, natural.height)) / referenceRatio)
        let minimum = max(0.0001, min(0.01, fitScale * 0.25))
        minMagnification = minimum * referenceRatio
        maxMagnification = max(8, referenceRatio * 8)
        let preservedScale = preserveRelativeFit && previousFit > 0
            ? fitScale * (previousScale / previousFit) : previousScale
        let target = reset || fitted ? fitScale : max(minimum, min(8, preservedScale))
        let anchor = reset || fitted
            ? CGPoint(x: natural.width / 2, y: natural.height / 2)
            : CGPoint(x: natural.width * fraction.x, y: natural.height * fraction.y)
        setMagnification(target * referenceRatio, centeredAt: anchor)
        if fitted || reset { centerPhoto() } else { centerPhoto(at: anchor) }
        window?.invalidateCursorRects(for: photoView)
        publishState()
    }

    func perform(_ command: ViewerZoomCommand) {
        switch command {
        case .zoomIn: setPhotoScale(Double(photoScale) * 1.25)
        case .zoomOut: setPhotoScale(Double(photoScale) / 1.25)
        case .fit:
            fitted = true
            setMagnification(fitScale * referenceRatio, centeredAt: viewportCenter)
            centerPhoto()
            window?.invalidateCursorRects(for: photoView)
            publishState()
        case .actualSize: setPhotoScale(1)
        }
    }
    @discardableResult
    func setPhotoScale(_ value: Double, centeredAt point: CGPoint? = nil) -> Double {
        guard value.isFinite else { return Double(photoScale) }
        fitted = false
        let native = max(minMagnification, min(maxMagnification, CGFloat(value) * referenceRatio))
        setMagnification(native, centeredAt: point ?? viewportCenter)
        constrainPosition()
        window?.invalidateCursorRects(for: photoView)
        publishState()
        return Double(photoScale)
    }
    fileprivate func doubleClick(at point: CGPoint) {
        if fitted || abs(photoScale - fitScale) <= max(0.001, fitScale * 0.02) {
            setPhotoScale(Double(max(1, fitScale * 2)), centeredAt: point)
        } else { perform(.fit) }
    }
    override func magnify(with event: NSEvent) {
        let anchor = contentView.convert(event.locationInWindow, from: nil)
        setPhotoScale(Double(photoScale) * exp(Double(event.magnification)), centeredAt: anchor)
    }
    override func smartMagnify(with event: NSEvent) {
        doubleClick(at: contentView.convert(event.locationInWindow, from: nil))
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let delta = min(40, max(-40, event.scrollingDeltaY))
            let sensitivity = event.hasPreciseScrollingDeltas ? 0.012 : 0.08
            setPhotoScale(Double(photoScale) * exp(Double(delta) * sensitivity), centeredAt: contentView.convert(event.locationInWindow, from: nil))
        } else { super.scrollWheel(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch event.keyCode {
            case 123: onKeyAction?(.previous); return
            case 124: onKeyAction?(.next); return
            case 53: onKeyAction?(.close); return
            case 49: onKeyAction?(.toggleSlideshow); return
            default: break
            }
        }
        super.keyDown(with: event)
    }
    fileprivate var canPan: Bool {
        photoView.bounds.width * magnification > contentSize.width + 1 || photoView.bounds.height * magnification > contentSize.height + 1
    }
    fileprivate func pan(windowDelta: CGSize) {
        guard canPan else { return }
        let factor = max(0.0001, magnification)
        let origin = contentView.bounds.origin
        let point = CGPoint(x: origin.x - windowDelta.width / factor,
                            y: origin.y + windowDelta.height / factor * (contentView.isFlipped ? 1 : -1))
        contentView.scroll(to: contentView.constrainBoundsRect(CGRect(origin: point, size: contentView.bounds.size)).origin)
        reflectScrolledClipView(contentView)
    }
    private func centerPhoto(at target: CGPoint? = nil) {
        let bounds = contentView.bounds
        let center = target ?? CGPoint(x: photoView.bounds.width / 2, y: photoView.bounds.height / 2)
        let point = CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2)
        contentView.scroll(to: contentView.constrainBoundsRect(CGRect(origin: point, size: bounds.size)).origin)
        reflectScrolledClipView(contentView)
    }
    private func constrainPosition() {
        contentView.scroll(to: contentView.constrainBoundsRect(contentView.bounds).origin)
        reflectScrolledClipView(contentView)
    }
    private func publishState() {
        guard !publishing, !tornDown else { return }
        publishing = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.tornDown else { return }
            self.publishing = false
            self.zoomState?.update(scale: Double(self.photoScale), isFitted: self.fitted,
                                   hasImage: self.photoView.image != nil,
                                   minimumScale: Double(self.minMagnification / self.referenceRatio))
            self.setAccessibilityValue(self.zoomState?.percentage)
        }
    }
    func tearDown() {
        tornDown = true
        zoomState?.detach(self)
        onKeyAction = nil
        onContextMenu = nil
        photoView.layer?.removeAnimation(forKey: "transition")
        photoView.image = nil
    }
}

@MainActor private final class CenteredPhotoClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        if documentView.frame.width < result.width { result.origin.x = (documentView.frame.width - result.width) / 2 }
        if documentView.frame.height < result.height { result.origin.y = (documentView.frame.height - result.height) / 2 }
        return result
    }
}

@MainActor private final class PhotoDocumentView: NSView {
    weak var owner: PhotoScrollView?
    var image: NSImage?
    private var lastDragPoint: CGPoint?
    override func menu(for event: NSEvent) -> NSMenu? { owner?.onContextMenu?() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "放大", target: self, selector: #selector(zoomIn)),
            NSAccessibilityCustomAction(name: "缩小", target: self, selector: #selector(zoomOut)),
            NSAccessibilityCustomAction(name: "适应窗口", target: self, selector: #selector(fitPhoto)),
            NSAccessibilityCustomAction(name: "实际大小（100%）", target: self, selector: #selector(actualSize))
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: owner?.canPan == true ? .openHand : .arrow) }
    override func mouseDown(with event: NSEvent) {
        guard let owner else { return }
        window?.makeFirstResponder(owner)
        if event.clickCount == 2 {
            lastDragPoint = nil
            owner.doubleClick(at: owner.contentView.convert(event.locationInWindow, from: nil))
        } else {
            lastDragPoint = event.locationInWindow
            if owner.canPan { NSCursor.closedHand.set() }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let previous = lastDragPoint else { return }
        let point = event.locationInWindow
        owner?.pan(windowDelta: CGSize(width: point.x - previous.x, height: point.y - previous.y))
        lastDragPoint = point
    }
    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        (owner?.canPan == true ? NSCursor.openHand : NSCursor.arrow).set()
    }
    @objc private func zoomIn() -> Bool { owner?.perform(.zoomIn); return owner != nil }
    @objc private func zoomOut() -> Bool { owner?.perform(.zoomOut); return owner != nil }
    @objc private func fitPhoto() -> Bool { owner?.perform(.fit); return owner != nil }
    @objc private func actualSize() -> Bool { owner?.perform(.actualSize); return owner != nil }
}
