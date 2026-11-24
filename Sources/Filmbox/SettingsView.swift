import AppKit
import SwiftUI
import FilmboxCore

struct SettingsView: View {
    @Bindable var store: AppStore
    @AppStorage("settingsSelectedTab") private var selectedTab = "general"
    @AppStorage("ignoreDotFiles") private var ignoreDotFiles = true
    @AppStorage("showFileNames") private var showFileNames = false
    @AppStorage("physicalEffects") private var physicalEffects = true
    @AppStorage("refreshOnActivation") private var refreshOnActivation = true
    @AppStorage("slideshowInterval") private var slideshowInterval = 4.0
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("thumbnailCacheLimitGB") private var cacheLimitGB = 2.0
    @State private var cacheBytes: Int64?
    @State private var showCacheManagement = false
    @State private var showRebuildIndexes = false
    @AppStorage("cloudThumbnailMode") private var cloudThumbnailMode = "nearby"
    @AppStorage("cloudCacheLimitGB") private var cloudCacheLimitGB = 8.0
    @State private var cloudCacheBytes: Int64?
    @State private var cloudConnectionRequest: CloudConnectionRequest?
    @State private var pendingDisconnect: CloudAccount?
    @State private var cloudTransfers = CloudTransferCenter.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Section {
                    Picker("外观", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    Toggle("返回应用时刷新资源库", isOn: $refreshOnActivation)
                    Toggle("忽略以点开头的文件和文件夹", isOn: $ignoreDotFiles)
                        .onChange(of: ignoreDotFiles) { _, _ in store.dotFilePreferenceChanged() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("常规", systemImage: "gearshape") }.tag("general")

            Form {
                Section {
                    Toggle("显示文件名", isOn: $showFileNames)
                    LabeledContent("缩略图大小") {
                        Slider(value: Binding(get: { store.thumbnailSize }, set: { store.setThumbnailSize($0) }), in: 64...280)
                            .frame(width: 200)
                            .accessibilityLabel("缩略图大小")
                    }
                }
                Section {
                    Toggle("翻阅时启用立体与反光效果", isOn: $physicalEffects)
                    Stepper(value: $slideshowInterval, in: 2...30, step: 1) {
                        LabeledContent("幻灯片间隔", value: "\(Int(slideshowInterval)) 秒")
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("浏览", systemImage: "photo.on.rectangle") }.tag("browse")

            Form {
                Section {
                    LabeledContent("缩略图缓存") {
                        if let cacheBytes {
                            Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                                .monospacedDigit()
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Picker("磁盘缓存上限", selection: $cacheLimitGB) {
                        Text("512 MB").tag(0.5)
                        Text("2 GB").tag(2.0)
                        Text("8 GB").tag(8.0)
                    }.onChange(of: cacheLimitGB) { _, _ in Task { await ThumbnailService.shared.trimCache() } }
                }
                Section("云端文件缓存") {
                    LabeledContent("已缓存", value: cloudCacheBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "正在计算…")
                    Picker("缓存上限", selection: $cloudCacheLimitGB) {
                        Text("2 GB").tag(2.0)
                        Text("8 GB").tag(8.0)
                        Text("32 GB").tag(32.0)
                    }.onChange(of: cloudCacheLimitGB) { _, _ in Task { await MediaAssetResolver.shared.trimCache(); cloudCacheBytes = await MediaAssetResolver.shared.cacheSize() } }
                }
                Section {
                    Button("清理缓存…") { showCacheManagement = true }
                }
                Section("资源库索引") {
                    Button("重新建立索引…") { showRebuildIndexes = true }
                        .disabled(store.libraries.isEmpty)
                }
            }
            .formStyle(.grouped)
            .task {
                cacheBytes = await ThumbnailService.shared.cacheSize()
                cloudCacheBytes = await MediaAssetResolver.shared.cacheSize()
            }
            .tabItem { Label("缓存", systemImage: "internaldrive") }.tag("cache")

            Form {
                Section("缩略图") {
                    Picker("加载方式", selection: $cloudThumbnailMode) {
                        Text("仅浏览附近").tag("nearby")
                        Text("后台加载全部").tag("all")
                    }.onChange(of: cloudThumbnailMode) { _, _ in
                        NotificationCenter.default.post(name: Notification.Name("FilmboxCloudThumbnailModeChanged"), object: nil)
                    }
                    if cloudThumbnailMode == "all" {
                        Text("后台加载会使用网络流量，可在云盘任务中暂停。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(store.cloudAccounts) { account in
                        HStack(spacing: 12) {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.name)
                                    HStack(spacing: 8) {
                                        Text(account.provider.displayName).foregroundStyle(.secondary)
                                        if needsLogin(account) {
                                            Text("需要重新登录").foregroundStyle(.secondary)
                                                .help(cloudTransfers.issue(for: account.id)?.message ?? "需要重新登录")
                                        } else if let problem = cloudTransfers.connectionProblems[account.id] {
                                            Text(problem.title).foregroundStyle(.secondary).help(problem.detail)
                                        }
                                    }.font(.caption)
                                }
                            } icon: { Image(systemName: account.provider.systemImage) }
                                .accessibilityElement(children: .combine)
                            Spacer(minLength: 12)
                            HStack(spacing: 12) {
                                if needsLogin(account) {
                                    Button("重新登录") { cloudConnectionRequest = CloudConnectionRequest(mode: .reconnect(account)) }
                                        .buttonStyle(.borderless).controlSize(.small)
                                        .accessibilityLabel("重新登录\(account.name)")
                                }
                                if let problem = cloudTransfers.connectionProblems[account.id], let library = store.libraries.first(where: { $0.cloud?.accountID == account.id }) {
                                    Button(problem.action) { store.recover(.init(problem: problem, libraryID: library.id)) }.buttonStyle(.borderless).controlSize(.small)
                                }
                                Menu {
                                    Button("添加文件夹…") { cloudConnectionRequest = CloudConnectionRequest(mode: .browse(account)) }
                                        .disabled(needsLogin(account))
                                    Button("重新登录…") { cloudConnectionRequest = CloudConnectionRequest(mode: .reconnect(account)) }
                                    Divider()
                                    Button("断开连接…", role: .destructive) { pendingDisconnect = account }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("管理\(account.name)")
                            }
                        }.accessibilityElement(children: .contain)
                    }
                    Button("添加云盘…", systemImage: "plus") { cloudConnectionRequest = CloudConnectionRequest(mode: .add) }
                }
            }.formStyle(.grouped)
                .tabItem { Label("云盘", systemImage: "cloud") }.tag("cloud")

            ScrollView {
                ShortcutReferenceView().padding(22)
            }
            .tabItem { Label("快捷键", systemImage: "keyboard") }.tag("shortcuts")
        }
        .frame(width: 560, height: 420)
        .sheet(isPresented: $showCacheManagement) {
            CacheManagementSheet().onDisappear { Task { await reloadCacheSizes() } }
        }
        .confirmationDialog("重新建立索引？", isPresented: $showRebuildIndexes, titleVisibility: .visible) {
            Button("重新建立索引") { store.rebuildIndexes() }
        } message: { Text("会重新核对资源库文件夹。现有收藏、隐藏和影集会保留。") }
        .sheet(item: $cloudConnectionRequest) { request in
            CloudConnectionSheet(accounts: store.cloudAccounts, reconnectAccount: request.reconnectAccount, initialAccount: request.initialAccount) { account, reference, name in
                if request.reconnectAccount != nil { store.updateCloudAccount(account) }
                else { store.addCloudLibrary(account: account, reference: reference, name: name) }
                cloudConnectionRequest = nil
            }
        }
        .confirmationDialog("断开此云盘？", isPresented: Binding(get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } }), titleVisibility: .visible) {
            Button("断开连接", role: .destructive) { if let account = pendingDisconnect { store.disconnectAccount(account) }; pendingDisconnect = nil }
        } message: { Text("会移除该账户的资源库和本机登录信息，云端原文件保留。") }
        .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
    }

    private func reloadCacheSizes() async {
        cacheBytes = await ThumbnailService.shared.cacheSize()
        cloudCacheBytes = await MediaAssetResolver.shared.cacheSize()
    }

    private func needsLogin(_ account: CloudAccount) -> Bool {
        cloudTransfers.issue(for: account.id)?.kind == .authenticationRequired
    }

}

struct CloudConnectionRequest: Identifiable {
    enum Mode {
        case add
        case browse(CloudAccount)
        case reconnect(CloudAccount)
    }

    let id = UUID()
    let mode: Mode

    var reconnectAccount: CloudAccount? {
        if case let .reconnect(account) = mode { return account }
        return nil
    }

    var initialAccount: CloudAccount? {
        if case let .browse(account) = mode { return account }
        return nil
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingLicense = false
    @State private var showingPrivacy = false

    private var version: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return "版本 \(value)"
        }
        return "开发版本"
    }

    private var icon: NSImage? {
        guard let url = Bundle.main.url(forResource: "Filmbox", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    private var license: String? {
        var sections: [String] = []
        if let resources = Bundle.main.resourceURL {
            for name in ["LICENSE", "THIRD_PARTY_NOTICES.md", "source-build.json"] {
                let url = resources.appendingPathComponent("Licenses/Filmbox/\(name)")
                if let text = try? String(contentsOf: url, encoding: .utf8) { sections.append(text) }
            }
            for name in ["FFmpeg-LICENSE.md", "COPYING.LGPLv2.1.txt", "SOURCE_INFO.txt"] {
                let url = resources.appendingPathComponent("Licenses/Codecs/\(name)")
                if let text = try? String(contentsOf: url, encoding: .utf8) { sections.append(text) }
            }
            for name in ["UPSTREAM.md", "LICENSE", "Go-LICENSE"] {
                let url = resources.appendingPathComponent("Licenses/CloudEngine/\(name)")
                if let text = try? String(contentsOf: url, encoding: .utf8) { sections.append(text) }
            }
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n────────────────────\n\n")
    }

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo.stack").resizable().scaledToFit().padding(14).foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text("菲林盒").font(.title2.weight(.semibold))
                Text("Filmbox").font(.title3).foregroundStyle(.secondary)
                Text(version).font(.callout).foregroundStyle(.secondary).padding(.top, 3)
            }
            Text("macOS 15 或更新版本 · Apple 芯片").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            HStack {
                if license != nil {
                    Button("开源许可") { showingLicense = true }
                }
                Button("隐私") { showingPrivacy = true }
                if let resources = Bundle.main.resourceURL {
                    let source = resources.appendingPathComponent("Licenses/Filmbox/filmbox-source.tar.gz")
                    if FileManager.default.fileExists(atPath: source.path) {
                        Button("源代码") { NSWorkspace.shared.activateFileViewerSelecting([source]) }
                    }
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.top, 14)
        }
        .padding(28)
        .frame(width: 360)
        .sheet(isPresented: $showingLicense) {
            LicenseView(text: license ?? "")
        }
        .sheet(isPresented: $showingPrivacy) {
            LicenseView(text: Bundle.main.resourceURL.flatMap {
                try? String(contentsOf: $0.appendingPathComponent("Licenses/Filmbox/PRIVACY.md"), encoding: .utf8)
            } ?? "请查看源代码仓库中的 PRIVACY.md。", title: "隐私")
        }
    }
}

private struct LicenseView: View {
    let text: String
    var title = "开源许可"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
            }.padding(20)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                        Text((paragraph.hasPrefix("#") ? paragraph.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) : paragraph).replacingOccurrences(of: "`", with: ""))
                            .font(.system(size: paragraph.hasPrefix("#") ? 14 : 12, weight: paragraph.hasPrefix("#") ? .semibold : .regular))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
        }
        .frame(width: 560, height: 440)
    }
}

struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("键盘快捷键").font(.title3.weight(.semibold))
                Spacer()
            }.padding(22)
            Divider()
            ScrollView { ShortcutReferenceView().padding(22) }
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
        }
        .frame(width: 450, height: 580)
    }

}

struct ShortcutReferenceView: View {
    var body: some View {
        VStack(spacing: 22) {
            shortcutSection("资源库与影集", rows: [
                ("添加资源库", "⌘ O"),
                ("刷新资源库", "⌘ R"),
                ("新建影集", "⌘ N"),
                ("所有项目", "⌘ 1"),
                ("收藏", "⌘ 2")
            ])
            shortcutSection("浏览", rows: [
                ("时间线", "⌘ 3"),
                ("翻阅", "⌘ 4"),
                ("在日期尺中切换时段", "滚轮 / 拖动 / ← →"),
                ("放大 / 缩小时间轴", "⌘ + / −"),
                ("滚轮缩放时间轴", "⌘ 滚轮"),
                ("搜索", "⌘ F"),
                ("显示 / 隐藏信息", "⌘ I"),
                ("选择并显示信息", "单击"),
                ("打开查看器", "双击 / 空格 / ↩"),
                ("在时间线中移动", "↑ ↓ ← →"),
                ("关闭查看器", "esc")
            ])
            shortcutSection("图片查看器", rows: [
                ("退出全屏", "esc"),
                ("适应窗口", "⌘ 0"),
                ("实际大小（100%）", "⌥ ⌘ 0"),
                ("放大 / 还原", "双击"),
                ("滑块缩放", "查看器底部"),
                ("放大 / 缩小照片", "⌘ + / −、⌘ 滚轮"),
                ("连续缩放", "触控板捏合"),
                ("平移放大的照片", "拖动"),
                ("上一项 / 下一项", "← / →、滚轮"),
                ("幻灯片 / 视频播放与暂停", "空格")
            ])
            shortcutSection("选择与文件", rows: [
                ("进入多选模式", "顶部「多选」"),
                ("选择模式中增减项目", "点击 / 空格"),
                ("连续选择经过的项目", "按住鼠标拖动"),
                ("从时间线拖出文件", "⌥ 拖动"),
                ("全选（选择模式中）", "⌘ A"),
                ("取消选择", "⇧ ⌘ A"),
                ("选择连续项目", "⇧ 点击 / ⇧ 方向键"),
                ("退出选择模式", "esc"),
                ("收藏 / 取消收藏", "⌘ L"),
                ("隐藏 / 恢复所选项目", "⇧ ⌘ H"),
                ("重命名", "F2"),
                ("移到废纸篓", "⌘ ⌫"),
                ("复制所选文件", "⌘ C"),
                ("复制文件路径", "⌥ ⌘ C"),
                ("在访达中显示", "⇧ ⌘ R")
            ])
            shortcutSection("应用", rows: [
                ("设置", "⌘ ,"),
                ("键盘快捷键", "⌘ /")
            ])
        }
    }

    private func shortcutSection(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { name, keys in
                HStack {
                    Text(name)
                    Spacer(minLength: 20)
                    Text(keys).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }.font(.callout)
    }
}
