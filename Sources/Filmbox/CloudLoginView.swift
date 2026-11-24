import SwiftUI
import WebKit
import FilmboxCore

/// A private, ephemeral browser belongs only to this connection flow. It never
/// reads another browser's cookies or the default WebKit website data store.
@MainActor @Observable
final class CloudLoginSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let provider: CloudProvider
    let webView: WKWebView
    var loading = false
    var host = ""
    var error: String?
    var onCredential: ((String) -> Void)?
    private var deliveredCredential = false
    private var stopped = false

    init(provider: CloudProvider) {
        self.provider = provider
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Quark hides its login panel below a desktop-width breakpoint.
        // Keep that panel visible inside our 1000-point login window.
        if provider == .quark { webView.pageZoom = 0.60 }
        let url = provider == .quark ? URL(string: "https://pan.quark.cn/")! : CloudBaiduCallback.loginURL
        webView.load(URLRequest(url: url))
    }

    func collectQuarkCredential() async throws -> String {
        guard provider == .quark else { throw QuarkLoginCredential.CollectionError.incomplete }
        return try await QuarkLoginCredential.collect(
            readCookies: { await self.webView.configuration.websiteDataStore.httpCookieStore.allCookies() },
            isActive: { !self.stopped }
        )
    }

    func stop() {
        stopped = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        onCredential = nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        error = nil
        host = webView.url?.host ?? ""
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        host = webView.url?.host ?? ""
        if let url = webView.url { captureBaiduCredential(url) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        if (error as NSError).code != NSURLErrorCancelled { self.error = "暂时无法打开登录页面，请重试。" }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        if (error as NSError).code != NSURLErrorCancelled { self.error = "登录页面加载中断，请重试。" }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if captureBaiduCredential(url) { decisionHandler(.cancel); return }
        guard ["https", "about"].contains(url.scheme?.lowercased() ?? "") else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
    @discardableResult private func captureBaiduCredential(_ url: URL) -> Bool {
        guard provider == .baidu, let credential = CloudBaiduCallback.credential(from: url) else { return false }
        guard !deliveredCredential else { return true }
        deliveredCredential = true
        onCredential?(credential)
        return true
    }
}

private struct CloudWebSurface: NSViewRepresentable {
    let session: CloudLoginSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

struct CloudLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: CloudLoginSession
    @State private var collecting = false
    @State private var credentialError: String?
    @State private var credentialTask: Task<Void, Never>?
    let onCredential: (String) -> Void

    init(provider: CloudProvider, onCredential: @escaping (String) -> Void) {
        _session = State(initialValue: CloudLoginSession(provider: provider))
        self.onCredential = onCredential
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                Text(session.host.isEmpty ? session.provider.displayName : session.host).font(.callout)
                if session.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("重新加载") { session.webView.reload() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            CloudWebSurface(session: session)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                if let message = credentialError ?? session.error {
                    Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    if session.provider == .baidu {
                        Text("授权完成后会自动返回；也可复制刷新令牌后手动填写。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("返回") { dismiss() }.keyboardShortcut(.cancelAction)
                    if session.provider == .quark {
                        Button {
                            collecting = true
                            credentialError = nil
                            credentialTask?.cancel()
                            credentialTask = Task {
                                do {
                                    let credential = try await session.collectQuarkCredential()
                                    onCredential(credential)
                                    dismiss()
                                } catch is CancellationError {
                                } catch { credentialError = error.localizedDescription }
                                collecting = false
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if collecting { ProgressView().controlSize(.small) }
                                Text("已完成登录")
                            }
                        }.buttonStyle(.borderedProminent).disabled(collecting)
                    }
                }
            }.padding(16)
        }.frame(width: 1000, height: 700)
            .onAppear { session.onCredential = { value in onCredential(value); dismiss() } }
            .onDisappear { credentialTask?.cancel(); session.stop() }
    }
}

/// OpenList APIPages encodes its initial state and OAuth callback as UTF-8 JSON
/// in a Base64 fragment. Query-style callbacks are accepted for compatibility.
enum CloudBaiduCallback {
    static var loginURL: URL {
        let data = try! JSONSerialization.data(withJSONObject: ["driver_txt": "baiduyun_go", "server_use": "true"], options: [.sortedKeys])
        var components = URLComponents(string: "https://api.oplist.org/")!
        components.fragment = data.base64EncodedString()
        return components.url!
    }

    static func credential(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "api.oplist.org",
              url.user == nil, url.password == nil, url.absoluteString.count <= 131_072 else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var values: [String: String] = [:]
        for item in components?.queryItems ?? [] { if let value = item.value { values[item.name] = value } }
        if let fragment = components?.fragment, !fragment.isEmpty {
            var encoded = fragment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            if let data = Data(base64Encoded: encoded),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, value) in object { if let value = value as? String { values[key] = value } }
            } else {
                for item in URLComponents(string: "https://localhost/?\(fragment)")?.queryItems ?? [] {
                    if let value = item.value { values[item.name] = value }
                }
            }
        }
        guard values["driver_txt"] == "baiduyun_go", let token = values["refresh_token"] ?? values["refresh_ui"],
              !token.isEmpty, token != "undefined", token.count <= 32_768 else { return nil }
        var credential = ["refresh_token": token]
        if let access = values["access_token"], !access.isEmpty, access != "undefined", access.count <= 32_768 {
            credential["access_token"] = access
        }
        if let client = values["client_key"], !client.isEmpty,
           let secret = values["secret_key"], !secret.isEmpty {
            credential["client_id"] = client
            credential["client_secret"] = secret
        }
        guard let data = try? JSONSerialization.data(withJSONObject: credential, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
