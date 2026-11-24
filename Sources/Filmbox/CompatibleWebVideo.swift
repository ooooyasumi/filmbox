import AppKit
import Observation
import SwiftUI
@preconcurrency import WebKit
import FilmboxCore

/// A local, read-only playback session for formats WebKit can decode directly.
/// The roll and viewer use the same controller, with separate presentation policy.
@MainActor @Observable
final class WebVideoPlayback {
    private(set) var webView: RestrictedVideoWebView?
    private(set) var currentID: String?
    private(set) var isPlaying = false
    private(set) var isMuted = true
    private(set) var isReady = false
    private(set) var isLoading = false
    private(set) var failed = false
    private(set) var needsOriginalDownload = false
    private(set) var isDownloadingOriginal = false
    private(set) var originalDownloadError: String?
    var originalFileSize: Int64 { media?.fileSize ?? 0 }
    private(set) var currentTime = 0.0
    private(set) var duration = 0.0

    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onEscape: (() -> Void)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var identity: String?
    @ObservationIgnored private var media: MediaItem?
    private(set) var wantsPlayback = false
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var showsControls = false
    @ObservationIgnored private var loops = false
    @ObservationIgnored private var bridgeToken = ""
    @ObservationIgnored private var commandRevision = 0
    @ObservationIgnored private var lease: LocalMediaLease?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var bridge: WebVideoBridge?
    @ObservationIgnored private var cacheLease: UUID?

    static func supports(_ url: URL) -> Bool { url.pathExtension.lowercased() == "webm" }
    var canTogglePlayback: Bool { currentID != nil && !failed && !needsOriginalDownload && !isDownloadingOriginal }

    func update(item: MediaItem?, muted: Bool, enabled: Bool, controls: Bool,
                loop: Bool, playOnOpen: Bool = true) {
        guard enabled, let item, item.kind == .video, Self.supports(item.url) else { stop(); return }
        let nextIdentity = "\(item.id)|\(item.url.absoluteString)|\(item.fileSize)|\(item.modifiedDate.timeIntervalSinceReferenceDate)|\(item.contentRevision ?? "")|\(controls)|\(loop)"
        if identity == nextIdentity, !failed, webView != nil || preparation != nil || needsOriginalDownload || isDownloadingOriginal {
            setMuted(muted)
            return
        }
        let suspended = isSuspended
        stop()
        isSuspended = suspended
        identity = nextIdentity
        media = item
        currentID = item.id
        isMuted = muted
        wantsPlayback = playOnOpen
        showsControls = controls
        loops = loop
        isLoading = true
        bridgeToken = UUID().uuidString
        commandRevision = 0
        let token = generation
        notify()
        preparation = Task { @MainActor [weak self] in
            do {
                if !item.isLocal {
                    let cacheLease = await MediaAssetResolver.shared.acquireViewingLease(for: item)
                    guard let self, self.generation == token, !Task.isCancelled else {
                        await MediaAssetResolver.shared.releaseViewingLease(cacheLease)
                        return
                    }
                    self.cacheLease = cacheLease
                }
                // WebKit receives a scoped local route, including for downloaded cloud originals.
                let localURL = try await MediaAssetResolver.shared.playbackURL(for: item)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                let opened = try await LocalMediaServer.shared.open(localURL)
                guard self.generation == token, !Task.isCancelled else { opened.release(); return }
                self.lease = opened
                let html = self.playerHTML(for: opened)
                await LocalMediaServer.shared.setPlayerHTML(html, for: opened)
                guard self.generation == token, !Task.isCancelled else { opened.release(); return }
                self.installWebView(lease: opened)
                self.preparation = nil
                self.startTimeout(token: token)
            } catch CloudConnectionError.originalDownloadRequired {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.preparation = nil
                self.needsOriginalDownload = true
                self.isLoading = false
                self.isPlaying = false
                self.notify()
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.preparation = nil
                self.markFailed()
            }
        }
    }

    /// A browse/hover never downloads a WebM original. This action represents
    /// the user's explicit request and shares the resolver's cancellable work.
    func downloadOriginalAndPlay() {
        guard let item = media, !item.isLocal, !isDownloadingOriginal else { return }
        preparation?.cancel()
        needsOriginalDownload = true
        isDownloadingOriginal = true
        originalDownloadError = nil
        failed = false
        isLoading = true
        let token = generation
        notify()
        preparation = Task { @MainActor [weak self] in
            do {
                _ = try await MediaAssetResolver.shared.originalFile(for: item)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.preparation = nil
                self.isDownloadingOriginal = false
                self.needsOriginalDownload = false
                self.identity = nil
                self.update(item: item, muted: self.isMuted, enabled: true, controls: self.showsControls, loop: self.loops)
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.preparation = nil
                self.isDownloadingOriginal = false
                self.isLoading = false
                self.originalDownloadError = MediaFailureText.transferError(error)
                self.notify()
            }
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        sendState()
        notify()
    }

    func togglePlayback() {
        guard canTogglePlayback else { return }
        wantsPlayback.toggle()
        if !wantsPlayback { isPlaying = false }
        sendState()
        notify()
    }

    /// Keep the viewer's position and manual pause while its window is hidden.
    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended { isPlaying = false }
        // WebKit's process-wide suspension can reset a WebM clock to zero.
        // Pause in place; the page's suspension gate retains the user's intent.
        if suspended { webView?.pauseAllMediaPlayback(completionHandler: nil) }
        sendState()
        if !suspended, isLoading { startTimeout(token: generation) }
        notify()
    }

    func retry() {
        guard let media, !isDownloadingOriginal else { return }
        identity = nil
        update(item: media, muted: isMuted, enabled: true, controls: showsControls, loop: loops)
    }

    func stop() {
        generation &+= 1
        preparation?.cancel(); preparation = nil
        timeout?.cancel(); timeout = nil
        tearDownPage()
        currentID = nil
        identity = nil
        media = nil
        wantsPlayback = false
        isPlaying = false
        isReady = false
        isLoading = false
        failed = false
        needsOriginalDownload = false
        isDownloadingOriginal = false
        originalDownloadError = nil
        currentTime = 0
        duration = 0
        notify()
    }

    private func installWebView(lease: LocalMediaLease) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        let bridge = WebVideoBridge(owner: self)
        configuration.userContentController.add(bridge, name: "filmboxVideo")
        let view = RestrictedVideoWebView(frame: .zero, configuration: configuration)
        view.focusRingType = .none
        view.interactive = showsControls
        view.underPageBackgroundColor = .black
        view.alphaValue = 0
        view.navigationDelegate = bridge
        view.uiDelegate = bridge
        self.bridge = bridge
        webView = view
        view.load(URLRequest(url: lease.playerURL, cachePolicy: .reloadIgnoringLocalCacheData))
        notify()
    }

    private func tearDownPage() {
        if let view = webView {
            // Stop the native media process before releasing the original file route.
            view.pauseAllMediaPlayback(completionHandler: nil)
            view.evaluateJavaScript("window.filmboxVideo?.shutdown()", completionHandler: nil)
            view.stopLoading()
            view.configuration.userContentController.removeScriptMessageHandler(forName: "filmboxVideo")
            view.navigationDelegate = nil
            view.uiDelegate = nil
            view.alphaValue = 0
            view.removeFromSuperview()
        }
        webView = nil
        bridge = nil
        lease?.release(); lease = nil
        if let cacheLease {
            self.cacheLease = nil
            Task { await MediaAssetResolver.shared.releaseViewingLease(cacheLease) }
        }
    }

    private func startTimeout(token: Int) {
        timeout?.cancel()
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.generation == token, self.isLoading, !self.isSuspended else { return }
            self.markFailed()
        }
    }

    private func markFailed() {
        timeout?.cancel(); timeout = nil
        failed = true
        isLoading = false
        isReady = false
        isPlaying = false
        wantsPlayback = false
        tearDownPage()
        notify()
    }

    private func notify() { onStateChange?() }

    private func sendState() {
        guard let view = webView, !failed else { return }
        commandRevision &+= 1
        let payload: [String: Any] = ["token": bridgeToken, "muted": isMuted,
                                      "playing": wantsPlayback, "suspended": isSuspended,
                                      "revision": commandRevision]
        view.evaluateJavaScript("window.filmboxVideo?.setState(\(Self.json(payload)))", completionHandler: nil)
    }

    fileprivate func allowsPage(_ url: URL?) -> Bool {
        guard let url, let lease else { return false }
        return url == lease.playerURL
    }

    fileprivate func didFinish(_ view: WKWebView) {
        guard view === webView, allowsPage(view.url), !failed else { return }
        sendState()
    }

    fileprivate func didFail(_ view: WKWebView, error: Error) {
        guard view === webView, (error as NSError).code != NSURLErrorCancelled else { return }
        markFailed()
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard !failed, message.name == "filmboxVideo", message.webView === webView,
              message.frameInfo.isMainFrame, allowsPage(message.frameInfo.request.url),
              let lease, let body = message.body as? [String: Any], body["token"] as? String == bridgeToken else { return }
        let origin = message.frameInfo.securityOrigin
        guard origin.protocol == lease.originURL.scheme, origin.host == "127.0.0.1",
              origin.port == lease.originURL.port else { return }
        guard let event = body["event"] as? String else { return }
        if event == "escape" { onEscape?(); return }
        if event == "error" { markFailed(); return }
        guard event == "state" || event == "ready" else { return }
        // A queued event from before a native pause/mute command must not undo it.
        if body["revision"] as? Int == commandRevision {
            if let muted = body["muted"] as? Bool { isMuted = muted }
            if let intent = body["intent"] as? Bool, !isSuspended { wantsPlayback = intent }
            isPlaying = (body["playing"] as? Bool ?? false) && !isSuspended
        }
        if let value = body["time"] as? Double, value.isFinite { currentTime = max(0, value) }
        if let value = body["duration"] as? Double, value.isFinite { duration = max(0, value) }
        if body["revision"] as? Int == commandRevision, isReady {
            isLoading = (body["buffering"] as? Bool ?? false) && wantsPlayback && !isSuspended
        }
        if event == "ready" {
            isReady = true
            isLoading = false
            timeout?.cancel(); timeout = nil
            webView?.alphaValue = 1
        }
        notify()
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]),
              let result = String(data: data, encoding: .utf8) else { return "null" }
        return result.replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private func playerHTML(for lease: LocalMediaLease) -> String {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let origin = "http://127.0.0.1:\(lease.originURL.port!)"
        let options: [String: Any] = ["token": bridgeToken, "source": lease.url.absoluteString,
                                      "muted": isMuted, "controls": showsControls, "loop": loops,
                                      "playing": wantsPlayback, "suspended": isSuspended]
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'nonce-\(nonce)'; media-src \(origin); connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style nonce="\(nonce)">html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000}video{display:block;width:100%;height:100%;object-fit:contain;background:#000;outline:none}video::-webkit-media-controls-fullscreen-button{display:none}</style></head>
        <body><video id="video" playsinline preload="metadata" controlslist="nofullscreen nodownload noremoteplayback" disablepictureinpicture aria-label="视频"></video>
        <script nonce="\(nonce)">
        (()=>{'use strict';const options=\(Self.json(options)),video=document.getElementById('video');
        let intent=options.playing,suspended=options.suspended,alive=true,lastState=0,ready=false,applying=false,revision=0;
        const post=event=>{if(!alive)return;window.webkit.messageHandlers.filmboxVideo.postMessage({token:options.token,event,revision,muted:video.muted,playing:!video.paused&&!video.ended,buffering:!video.paused&&!video.ended&&video.readyState<3,intent,time:video.currentTime||0,duration:Number.isFinite(video.duration)?video.duration:0});};
        const play=()=>{if(!alive||suspended||!intent)return;if(video.ended)video.currentTime=0;const result=video.play();if(result)result.catch(error=>{if(video.error)post('error');else{if(error.name==='NotAllowedError')intent=false;post('state');}});};
        const showFrame=()=>{if(!ready&&video.readyState>=2&&video.videoWidth>0){ready=true;post('ready');}};
        video.muted=options.muted;video.defaultMuted=options.muted;video.controls=options.controls;video.loop=options.loop;
        video.addEventListener('loadeddata',showFrame);video.addEventListener('canplay',showFrame);
        video.addEventListener('playing',()=>{showFrame();post('state');});
        for(const event of ['waiting','stalled','canplay'])video.addEventListener(event,()=>post('state'));
        video.addEventListener('play',()=>{if(suspended)video.pause();else if(!applying&&!video.paused)intent=true;post('state');});
        video.addEventListener('pause',()=>{if(!applying&&!suspended&&!video.ended&&video.paused)intent=false;post('state');});
        video.addEventListener('ended',()=>{if(!video.loop)intent=false;post('state');});
        video.addEventListener('volumechange',()=>post('state'));
        video.addEventListener('durationchange',()=>post('state'));
        video.addEventListener('error',()=>{if(alive)post('error');});
        video.addEventListener('timeupdate',()=>{const now=performance.now();if(now-lastState>200){lastState=now;post('state');}});
        document.addEventListener('keydown',event=>{if(event.key==='Escape'){event.preventDefault();event.stopPropagation();post('escape');}},true);
        window.filmboxVideo={setState:state=>{if(!alive||state.token!==options.token||state.revision<revision)return;revision=state.revision;applying=true;video.muted=state.muted;intent=state.playing;suspended=state.suspended;if(suspended||!intent)video.pause();else play();applying=false;post('state');},shutdown:()=>{alive=false;intent=false;suspended=true;video.pause();video.removeAttribute('src');video.load();}};
        video.src=options.source;video.load();
        })();
        </script></body></html>
        """
    }

    isolated deinit { stop() }
}

@MainActor final class RestrictedVideoWebView: WKWebView {
    var interactive = false
    override var acceptsFirstResponder: Bool { interactive }
    override func hitTest(_ point: NSPoint) -> NSView? { interactive ? super.hitTest(point) : nil }
}

@MainActor private final class WebVideoBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var owner: WebVideoPlayback?
    init(owner: WebVideoPlayback) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.targetFrame?.isMainFrame == true && owner?.allowsPage(navigationAction.request.url) == true
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.isForMainFrame && owner?.allowsPage(navigationResponse.response.url) == true ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { owner?.didFinish(webView) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { owner?.didFail(webView, error: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { owner?.didFail(webView, error: error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner?.didFail(webView, error: NSError(domain: "FilmboxVideo", code: 1))
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}

struct WebVideoSurface: NSViewRepresentable {
    let webView: RestrictedVideoWebView?
    func makeNSView(context: Context) -> WebVideoHostView {
        let view = WebVideoHostView(); view.configure(webView); return view
    }
    func updateNSView(_ view: WebVideoHostView, context: Context) { view.configure(webView) }
    static func dismantleNSView(_ view: WebVideoHostView, coordinator: ()) { view.configure(nil) }
}

@MainActor final class WebVideoHostView: NSView {
    private weak var hosted: RestrictedVideoWebView?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ view: RestrictedVideoWebView?) {
        guard hosted !== view || view?.superview !== self else { return }
        if hosted?.superview === self { hosted?.removeFromSuperview() }
        hosted = view
        guard let view else { return }
        view.removeFromSuperview(); view.frame = bounds; view.autoresizingMask = [.width, .height]; addSubview(view)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hosted?.interactive == true else { return nil }
        return super.hitTest(point)
    }
}

