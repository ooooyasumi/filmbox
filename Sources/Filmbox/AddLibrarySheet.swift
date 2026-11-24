import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import FilmboxCore

struct AddLibrarySheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var step: Step = .choose
    @State private var isDropTarget = false
    private enum Step { case choose, local, cloud }
    private var palette: LightTablePalette { LightTablePalette(dark: scheme == .dark) }

    var body: some View {
        Group {
            if step == .cloud {
                CloudConnectionSheet(accounts: store.cloudAccounts, onBack: { step = .choose }) { account, reference, name in
                    store.addCloudLibrary(account: account, reference: reference, name: name)
                    dismiss()
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        if step == .local { ChromeIconButton(title: "返回", symbol: "chevron.left") { step = .choose } }
                        Text(step == .local ? "添加本地文件夹" : "添加资源库").font(.system(size: 21, weight: .semibold))
                        Spacer()
                        ChromeIconButton(title: "关闭", symbol: "xmark") { dismiss() }
                    }.padding(24)
                    if step == .choose {
                        VStack(spacing: 12) {
                            choice("本地文件夹", subtitle: "Mac、外置磁盘或已挂载的位置", symbol: "folder", action: { step = .local })
                            choice("云盘", subtitle: "百度网盘、夸克网盘或 WebDAV", symbol: "cloud", action: { step = .cloud })
                        }.padding(.horizontal, 24)
                    } else {
                        VStack(spacing: 18) {
                            Image(systemName: "folder.badge.plus").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.secondary)
                            Text("将文件夹拖到这里").font(.callout).foregroundStyle(.secondary)
                            Button("选择文件夹…", action: selectLocalFolder).buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity).frame(height: 210)
                            .background(isDropTarget ? palette.selectedFill : palette.raised, in: RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 24)
                    }
                    Spacer(minLength: 18)
                    HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(20)
                }.frame(width: 620, height: 380).background(palette.panel)
                    .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: receiveFolders)
            }
        }
    }

    private func choice(_ title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 27, weight: .light)).frame(width: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(palette.text)
                    Text(subtitle).font(.callout).foregroundStyle(palette.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(palette.secondary)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.raised, in: RoundedRectangle(cornerRadius: 15)).contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain)
    }

    private func selectLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加资源库"
        panel.begin { result in
            guard result == .OK else { return }
            store.addFolders(panel.urls)
            dismiss()
        }
    }

    private func receiveFolders(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matching.isEmpty else { return false }
        let collection = AddLibraryDropCollection(count: matching.count) { urls in
            guard !urls.isEmpty else { return }
            store.addFolders(urls)
            dismiss()
        }
        for provider in matching {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in Task { @MainActor in collection.receive(url) } }
        }
        return true
    }
}

@MainActor private final class AddLibraryDropCollection {
    private var remaining: Int
    private var urls: [URL] = []
    private let complete: ([URL]) -> Void
    init(count: Int, complete: @escaping ([URL]) -> Void) { remaining = count; self.complete = complete }
    func receive(_ url: URL?) {
        if let url, url.isFileURL {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue, !urls.contains(url) { urls.append(url) }
        }
        remaining -= 1
        if remaining == 0 { complete(urls) }
    }
}

private struct CloudLoginWebSurface: NSViewRepresentable {
    let session: CloudLoginSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// Login, folder selection and source selection share one presentation surface.
struct EmbeddedCloudLoginPanel: View {
    let session: CloudLoginSession
    let onBack: () -> Void
    let onCredential: (String) -> Void
    @State private var collecting = false
    @State private var error: String?
    @State private var credentialTask: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.caption)
                Text(session.host).font(.caption).lineLimit(1)
                if session.loading { ProgressView().controlSize(.mini) }
                Spacer()
                Button("重新加载") { session.webView.reload() }.buttonStyle(.plain).font(.caption)
            }.foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 12)
            Divider()
            CloudLoginWebSurface(session: session)
            Divider()
            HStack(spacing: 12) {
                if let error = error ?? session.error { Text(error).font(.callout).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("返回", action: onBack).keyboardShortcut(.cancelAction)
                if session.provider == .quark {
                    Button {
                        collecting = true
                        error = nil
                        credentialTask?.cancel()
                        credentialTask = Task {
                            do { onCredential(try await session.collectQuarkCredential()) }
                            catch is CancellationError { }
                            catch { self.error = error.localizedDescription }
                            collecting = false
                        }
                    } label: {
                        HStack { if collecting { ProgressView().controlSize(.small) }; Text("完成登录") }
                    }.buttonStyle(.borderedProminent).disabled(collecting)
                }
            }.padding(20)
        }.onAppear { session.onCredential = onCredential }
            .onDisappear { credentialTask?.cancel(); session.stop() }
    }
}
