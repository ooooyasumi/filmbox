import AppKit
import FilmboxCore
import Observation

/// The entire grid shares one decoder. Reused and offscreen cells only retain
/// posters; selection owns the request, while viewport visibility permits it.
@MainActor final class GridVideoPreviewSession {
    let playback = BrowseVideoPlayback()
    private struct Request: Equatable {
        let id: String
        let url: URL
        let size: Int64
        let modified: Date
        let revision: String?
        let muted: Bool
    }
    private var request: Request?

    func update(item: MediaItem?, store: AppStore, presented: Bool) {
        let enabled = presented && store.layout == .grid && !store.isSelectionMode
            && item?.id == store.gridPreviewID
        guard enabled, let item, item.kind == .video else { stop(); return }
        let next = Request(id: item.id, url: item.url, size: item.fileSize,
                           modified: item.modifiedDate, revision: item.contentRevision, muted: store.browseVideoMuted)
        // Representable updates observe playback while configuring reused
        // cells. Rewriting its observable state for the same request would
        // schedule another update, including while the grid is entirely idle.
        guard request != next else { return }
        request = next
        playback.update(item: item, muted: next.muted, enabled: true)
    }

    func stop() {
        request = nil
        guard playback.currentID != nil || playback.player != nil || playback.webPlayback != nil
                || playback.isPlaying || playback.isReady || playback.isLoading || playback.failed else { return }
        playback.stop()
    }
}

/// Native controls form a separate hit target from the photo. In particular,
/// pressing sound or pause must never become a collection selection gesture.
@MainActor final class GridVideoPreviewControls: NSView {
    private let playButton = NSButton()
    private let soundButton = NSButton()
    private weak var session: GridVideoPreviewSession?
    private weak var store: AppStore?
    private var observationGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("grid-video-controls")
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.48).cgColor
        for button in [playButton, soundButton] {
            button.identifier = identifier
            button.isBordered = false
            button.bezelStyle = .inline
            button.focusRingType = .none
            button.imagePosition = .imageOnly
            button.contentTintColor = .white
            button.target = self
            addSubview(button)
        }
        playButton.action = #selector(togglePlayback)
        soundButton.action = #selector(toggleSound)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let compact = bounds.width < 52
        playButton.isHidden = compact
        if compact {
            soundButton.frame = bounds.insetBy(dx: 2, dy: 2)
        } else {
            playButton.frame = NSRect(x: 4, y: 2, width: 26, height: max(0, bounds.height - 4))
            soundButton.frame = NSRect(x: bounds.width - 30, y: 2, width: 26, height: max(0, bounds.height - 4))
        }
    }

    func configure(session: GridVideoPreviewSession?, store: AppStore?) {
        guard self.session !== session || self.store !== store else { return }
        observationGeneration += 1
        self.session = session; self.store = store
        refresh()
    }

    private func refresh() {
        guard let session, let store else { return }
        let generation = observationGeneration
        withObservationTracking {
            let playback = session.playback
            let playTitle = playback.failed ? "重试播放" : playback.playbackRequested ? "暂停视频预览" : "播放视频预览"
            let symbol = playback.failed ? "arrow.clockwise" : playback.playbackRequested ? "pause.fill" : "play.fill"
            playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: playTitle)
            playButton.toolTip = playTitle
            playButton.setAccessibilityLabel(playTitle)
            playButton.isEnabled = playback.failed || playback.canTogglePlayback
            let soundTitle = store.browseVideoMuted ? "打开声音" : "静音"
            soundButton.image = NSImage(systemSymbolName: store.browseVideoMuted ? "speaker.slash" : "speaker.wave.2",
                                       accessibilityDescription: soundTitle)
            soundButton.toolTip = soundTitle
            soundButton.setAccessibilityLabel(soundTitle)
            soundButton.setAccessibilityValue(store.browseVideoMuted ? "已静音" : "声音已打开")
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.refresh()
            }
        }
    }

    @objc private func togglePlayback() {
        guard let playback = session?.playback else { return }
        if playback.failed { playback.retry() } else { playback.togglePlayback() }
    }

    @objc private func toggleSound() {
        guard let store, let session, let id = store.gridPreviewID,
              session.playback.currentID == id,
              let item = store.visibleItems.first(where: { $0.id == id }) else { return }
        store.browseVideoMuted.toggle()
        session.update(item: item, store: store, presented: true)
    }

    override func mouseDown(with event: NSEvent) { }
    override func mouseDragged(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) { }
}
