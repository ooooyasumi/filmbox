import SwiftUI

struct MediaFilterButton: View {
    @Bindable var store: AppStore
    @State private var isPresented = false
    @Environment(\.colorScheme) private var scheme
    private var palette: LightTablePalette { LightTablePalette(dark: scheme == .dark) }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                Text("筛选")
                if store.activeFilterCount > 0 {
                    Text("\(store.activeFilterCount)").monospacedDigit()
                        .font(.system(size: 10, weight: .medium))
                }
            }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 30)
                .foregroundStyle(store.hasActiveFilters ? palette.accentText : palette.secondary)
                .background(store.hasActiveFilters ? palette.selectedFill : palette.quietFill, in: Capsule())
        }.buttonStyle(.plain).modifier(QuietFocusTreatment())
            .help("筛选类型、格式、来源与云端原图")
            .accessibilityLabel("媒体筛选")
            .accessibilityValue(store.hasActiveFilters ? "已启用 \(store.activeFilterCount) 个条件" : "无筛选条件")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) { MediaFilterPopover(store: store) }
    }
}

struct MediaFilterPopover: View {
    @Bindable var store: AppStore
    @Environment(\.colorScheme) private var scheme
    private var palette: LightTablePalette { LightTablePalette(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("筛选").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("重置") { store.clearFilters() }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
                    .disabled(!store.hasActiveFilters)
            }
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("类型")
                HStack(spacing: 8) {
                    ForEach(AppStore.MediaFilter.allCases, id: \.self) { value in
                        FilterChoiceButton(title: value.rawValue, selected: store.filter == value, expands: true) { store.filter = value }
                    }
                }.accessibilityElement(children: .contain).accessibilityLabel("类型")
            }
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("来源")
                HStack(spacing: 8) {
                    ForEach(AppStore.SourceFilter.allCases, id: \.self) { value in
                        FilterChoiceButton(title: value.rawValue, selected: store.sourceFilter == value, expands: true) { store.setSourceFilter(value) }
                    }
                }.accessibilityElement(children: .contain).accessibilityLabel("来源")
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    sectionTitle("云端原图")
                    if store.isCheckingOriginalCache { ProgressView().controlSize(.mini) }
                }
                HStack(spacing: 8) {
                    ForEach(AppStore.OriginalDownloadFilter.allCases, id: \.self) { value in
                        FilterChoiceButton(title: value.rawValue, selected: store.originalDownloadFilter == value, expands: true) { store.setOriginalDownloadFilter(value) }
                    }
                }.accessibilityElement(children: .contain).accessibilityLabel("云端原图")
                    .disabled(!store.hasLoadedOriginalCache)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionTitle("格式")
                    Spacer()
                    Button("清除") { store.clearFormatFilter() }.buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                        .disabled(store.selectedFormats.isEmpty)
                }
                if store.availableFormats.isEmpty {
                    Text("无可用格式").font(.system(size: 12)).foregroundStyle(palette.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(store.availableFormats, id: \.self) { format in
                                formatButton(format)
                            }
                        }
                    }.frame(height: min(182, CGFloat((store.availableFormats.count + 3) / 4) * 38 - 8))
                }
            }
        }.padding(20).frame(width: 336).foregroundStyle(palette.text)
            .presentationBackground(palette.panel)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary)
    }

    private func formatButton(_ format: String) -> some View {
        let selected = store.selectedFormats.contains(format)
        return FilterChoiceButton(title: format, selected: selected, expands: true) { store.toggleFormat(format) }
            .accessibilityLabel("\(format) 格式")
    }
}
