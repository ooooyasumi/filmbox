import SwiftUI

private enum CacheChoice: String, CaseIterable, Identifiable {
    case local, cloud, highResolution, original, legacy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: "本地媒体缩略图"
        case .cloud: "云端媒体缩略图"
        case .highResolution: "高清预览"
        case .original: "云端原文件"
        case .legacy: "旧版预览"
        }
    }
}

struct CacheManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var sizes: [CacheChoice: Int64] = [:]
    @State private var selected: Set<CacheChoice> = []
    @State private var loading = true
    @State private var clearing = false
    @State private var protectedBytes: Int64 = 0
    @State private var result: String?
    private var palette: LightTablePalette { LightTablePalette(dark: scheme == .dark) }
    private var choices: [CacheChoice] { CacheChoice.allCases.filter { $0 != .legacy || sizes[.legacy, default: 0] > 0 } }
    private var selectedBytes: Int64 { selected.reduce(0) { $0 + sizes[$1, default: 0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("清理缓存").font(.system(size: 20, weight: .semibold))
                Spacer()
                ChromeIconButton(title: "关闭", symbol: "xmark") { dismiss() }.disabled(clearing)
            }.padding(24)
            VStack(spacing: 2) {
                ForEach(choices) { choice in
                    Toggle(isOn: Binding(get: { selected.contains(choice) }, set: { enabled in
                        if enabled { selected.insert(choice) } else { selected.remove(choice) }
                    })) {
                        HStack {
                            Text(choice.title)
                            Spacer()
                            if loading { ProgressView().controlSize(.mini) }
                            else { Text(cloudByteCount(sizes[choice, default: 0])).foregroundStyle(.secondary).monospacedDigit() }
                        }
                    }.toggleStyle(.checkbox).padding(.horizontal, 14).padding(.vertical, 11)
                        .disabled(loading || clearing || sizes[choice, default: 0] == 0)
                }
            }.background(palette.raised, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 24)
            Text("原始资源库文件保留。正在查看或使用的文件会跳过。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 14)
            if protectedBytes > 0 {
                Text("正在使用：\(cloudByteCount(protectedBytes))")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 6)
            }
            if let result { Text(result).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 12) }
            Spacer(minLength: 22)
            Divider()
            HStack {
                if clearing { ProgressView().controlSize(.small) }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(clearing)
                Button("清理 \(cloudByteCount(selectedBytes))") { clearSelected() }
                    .buttonStyle(.borderedProminent).disabled(clearing || loading || selectedBytes == 0)
            }.padding(20)
        }.frame(width: 480, height: sizes[.legacy, default: 0] > 0 ? 470 : 430)
            .background(palette.panel).task { await reload() }
            .interactiveDismissDisabled(clearing)
    }

    private func reload() async {
        async let previews = ThumbnailService.shared.cacheSizes()
        async let cloud = MediaAssetResolver.shared.cacheSizes()
        let (previewSizes, cloudSizes) = await (previews, cloud)
        sizes = [.local: previewSizes[.local, default: 0],
                 .cloud: previewSizes[.cloud, default: 0] + cloudSizes.thumbnailBytes,
                 .highResolution: previewSizes[.highResolution, default: 0],
                 .original: cloudSizes.originalBytes,
                 .legacy: previewSizes[.legacy, default: 0]]
        protectedBytes = cloudSizes.protectedBytes
        loading = false
    }

    private func clearSelected() {
        let choices = selected
        let transfers = CloudTransferCenter.shared
        let preloader = CloudThumbnailPreloader.shared
        let touchesCloud = !choices.isDisjoint(with: [.cloud, .highResolution, .original])
        let backgroundTasks = transfers.tasks.contains { $0.priority == .background && [.queued, .downloading, .paused].contains($0.state) }
        let preloadPending = preloader.isRunning || (UserDefaults.standard.string(forKey: "cloudThumbnailMode") == "all"
            && preloader.isCapacityPaused && preloader.completed < preloader.total)
        let pausedBackground = touchesCloud && (backgroundTasks || preloadPending)
        if pausedBackground || choices.contains(.cloud) { transfers.pauseBackground(true) }
        clearing = true
        result = nil
        Task {
            var categories = Set<PreviewCacheCategory>()
            if choices.contains(.local) { categories.insert(.local) }
            if choices.contains(.cloud) { categories.insert(.cloud) }
            if choices.contains(.highResolution) { categories.insert(.highResolution) }
            if choices.contains(.legacy) { categories.insert(.legacy) }
            let before = sizes.values.reduce(0, +)
            if !categories.isEmpty { await ThumbnailService.shared.clearCache(categories: categories) }
            if choices.contains(.cloud) {
                _ = await MediaAssetResolver.shared.clearThumbnailCache()
                preloader.resetCompletion()
            }
            if choices.contains(.original) { _ = await MediaAssetResolver.shared.clearOriginalCache() }
            await reload()
            let removed = max(0, before - sizes.values.reduce(0, +))
            selected.removeAll()
            clearing = false
            result = "已清理 \(cloudByteCount(removed))" + (pausedBackground ? "。后台下载已暂停。" : "")
            NotificationCenter.default.post(name: Notification.Name("FilmboxCacheChanged"), object: nil)
        }
    }
}
