import AppKit
import FilmboxCore
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    let store: AppStore
    var isViewer = false
    @Environment(\.colorScheme) private var scheme
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("信息").font(.headline)
                Spacer()
                Button("关闭信息", systemImage: "xmark") { if let onClose { onClose() } else { store.showInspector = false } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("关闭信息")
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            Divider()

            if !isViewer && store.selectedItems.count > 1 {
                InspectorSelectionView(items: store.selectedItems, store: store)
            } else if let item = isViewer ? store.focusedItem : store.libraryFocusedItem {
                InspectorItemView(item: item, store: store)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "info.circle").font(.system(size: 30, weight: .light))
                    Text("选择项目以查看信息").font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(LightTablePalette(dark: scheme == .dark).panel)
    }
}

private struct InspectorSelectionView: View {
    let items: [MediaItem]
    let store: AppStore

    private var allFavorite: Bool { items.allSatisfy { store.favorites.contains($0.id) } }
    private var imageCount: Int { items.filter { $0.kind == .image }.count }
    private var videoCount: Int { items.count - imageCount }
    private var totalSize: Int64 { items.reduce(0) { $0 + $1.fileSize } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                    ForEach(Array(items.prefix(4))) { item in
                        AsyncThumbnail(item: item, pixelSize: 256, contentMode: .fit)
                            .frame(height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
                HStack {
                    Text("\(items.count.formatted()) 个项目").font(.headline)
                    Spacer()
                    Button(allFavorite ? "取消收藏所选项目" : "收藏所选项目", systemImage: allFavorite ? "heart.fill" : "heart") {
                        store.favoriteSelection()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(allFavorite ? Color.accentColor : .secondary)
                    .help(allFavorite ? "取消收藏所选项目" : "收藏所选项目")
                }
                InspectorSection("概览") {
                    if imageCount > 0 { InspectorRow("照片", value: "\(imageCount.formatted()) 张") }
                    if videoCount > 0 { InspectorRow("视频", value: "\(videoCount.formatted()) 段") }
                    InspectorRow("总大小", value: ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                }
                if let first = items.map(\.displayDate).min(), let last = items.map(\.displayDate).max() {
                    Divider()
                    InspectorSection("日期范围") {
                        InspectorRow("最早", value: first.formatted(date: .abbreviated, time: .omitted))
                        InspectorRow("最近", value: last.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                Divider()
                Button("在访达中显示", systemImage: "folder") {
                    for item in items { store.reveal(item) }
                }
                .frame(maxWidth: .infinity)
                .controlSize(.small)
            }
            .padding(18)
        }
    }
}

private struct InspectorItemView: View {
    let item: MediaItem
    let store: AppStore
    @State private var videoDetails: VideoDetails?
    @State private var loadedRequest: RequestID?

    private struct RequestID: Hashable {
        let url: URL
        let modifiedDate: Date
    }

    private var requestID: RequestID { RequestID(url: item.url, modifiedDate: item.modifiedDate) }
    private var details: VideoDetails? { loadedRequest == requestID ? videoDetails : nil }
    private var favorite: Bool { store.favorites.contains(item.id) }
    private var fileType: String {
        UTType(filenameExtension: item.url.pathExtension)?.localizedDescription
            ?? (item.kind == .image ? "照片" : "视频")
    }
    private var dimensions: String? {
        let width = details?.width ?? item.pixelWidth
        let height = details?.height ?? item.pixelHeight
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width.formatted()) × \(height.formatted())"
    }
    private var duration: String? {
        guard let value = details?.duration ?? item.duration, value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
        let seconds = Int(value.rounded())
        if seconds >= 3_600 { return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private var codec: String? {
        guard let raw = nonempty(details?.codec) else { return nil }
        return ["avc1": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "av01": "AV1", "vp09": "VP9", "jpeg": "Motion JPEG"][raw] ?? raw
    }
    private var hasCameraMetadata: Bool {
        nonempty(item.camera) != nil || nonempty(item.lens) != nil || valid(item.aperture) != nil
            || valid(item.focalLength) != nil || (item.iso ?? 0) > 0 || nonempty(item.exposure) != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button { store.open(item) } label: {
                    AsyncThumbnail(item: item, pixelSize: 640, contentMode: .fit)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开 \(item.name)")
                .help("打开查看器")

                HStack(alignment: .top, spacing: 12) {
                    Text(item.name)
                        .font(.headline)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(favorite ? "取消收藏" : "收藏", systemImage: favorite ? "heart.fill" : "heart") {
                        store.toggleFavorite(item)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(favorite ? Color.accentColor : .secondary)
                    .help(favorite ? "取消收藏" : "收藏")
                }

                InspectorSection("文件") {
                    InspectorRow("类型", value: fileType)
                    InspectorRow("大小", value: ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                    if let dimensions { InspectorRow("尺寸", value: dimensions) }
                    if item.kind == .video, let duration { InspectorRow("时长", value: duration) }
                    if let codec { InspectorRow("编码", value: codec) }
                }
                Divider()
                InspectorSection("日期") {
                    if let capturedDate = item.capturedDate { InspectorRow("拍摄", value: date(capturedDate)) }
                    InspectorRow("创建", value: date(item.createdDate))
                    InspectorRow("修改", value: date(item.modifiedDate))
                }
                if hasCameraMetadata {
                    Divider()
                    InspectorSection("拍摄参数") {
                        if let camera = nonempty(item.camera) { InspectorRow("相机", value: camera) }
                        if let lens = nonempty(item.lens) { InspectorRow("镜头", value: lens) }
                        if let aperture = valid(item.aperture) { InspectorRow("光圈", value: "ƒ/\(number(aperture))") }
                        if let iso = item.iso, iso > 0 { InspectorRow("ISO", value: iso.formatted(.number.grouping(.never))) }
                        if let exposure = nonempty(item.exposure) { InspectorRow("曝光", value: exposure) }
                        if let focalLength = valid(item.focalLength) { InspectorRow("焦距", value: "\(number(focalLength)) mm") }
                    }
                }
                Divider()
                InspectorSection("位置") {
                    if let ref = item.cloud, let account = store.cloudAccounts.first(where: { $0.id == ref.accountID }) {
                        Label(account.provider.displayName, systemImage: "cloud").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.displayPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .contextMenu {
                            Button("复制文件路径") { copyPath() }
                            Button(item.isLocal ? "在访达中显示" : "下载并在访达中显示") { store.reveal(item) }
                        }
                }
                HStack {
                    Button(item.isLocal ? "在访达中显示" : "下载原文件", systemImage: item.isLocal ? "folder" : "arrow.down.circle") { store.reveal(item) }
                    Spacer(minLength: 4)
                    Button("复制路径", systemImage: "doc.on.doc") { copyPath() }
                }.controlSize(.small)
            }
            .padding(18)
        }
        .task(id: requestID) {
            guard item.kind == .video else { return }
            if !item.isLocal {
                if let asset = try? await MediaAssetResolver.shared.playbackAsset(for: item), !Task.isCancelled {
                    await CloudPreviewMetadata.streamingVideoMetadata(item: item, url: asset.url, headers: asset.headers)
                }
                return
            }
            let result = await DetailsService.shared.videoDetails(url: item.url)
            guard !Task.isCancelled else { return }
            videoDetails = result
            loadedRequest = requestID
        }
    }

    private func date(_ value: Date) -> String {
        value.formatted(.dateTime.year().month().day().hour().minute().second())
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    private func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.displayPath, forType: .string)
        store.notify("已复制路径")
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }
}
