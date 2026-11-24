import SwiftUI
import AppKit

struct LightTablePalette {
    let dark: Bool
    var canvas: Color { Color(hex: dark ? 0x181818 : 0xECECEC) }
    var panel: Color { Color(hex: dark ? 0x17191D : 0xF5F6F7) }
    var raised: Color { Color(hex: dark ? 0x22252B : 0xFFFFFF) }
    var border: Color { Color(hex: dark ? 0x363A42 : 0xDCDDE0) }
    var text: Color { Color(hex: dark ? 0xF5F6F7 : 0x17191D) }
    var secondary: Color { Color(hex: dark ? 0xA9AFBA : 0x616974) }
    var accentText: Color { Color(hex: dark ? 0x8FA7FF : 0x315BFF) }
    var quietFill: Color { text.opacity(dark ? 0.055 : 0.035) }
    var selectedFill: Color { Self.blue.opacity(dark ? 0.12 : 0.065) }
    static let blue = Color(hex: 0x315BFF)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

/// The identity is four exact rectangles; the centre top block alone is blue.
struct FilmboxMark: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 88, geometry.size.height / 104)
            let ink = scheme == .dark ? Color.white : Color.black
            ZStack(alignment: .topLeading) {
                Rectangle().fill(ink).frame(width: 24 * scale, height: 72 * scale).offset(y: 16 * scale)
                Rectangle().fill(LightTablePalette.blue).frame(width: 24 * scale, height: 44 * scale).offset(x: 32 * scale)
                Rectangle().fill(ink).frame(width: 24 * scale, height: 44 * scale).offset(x: 32 * scale, y: 60 * scale)
                Rectangle().fill(ink).frame(width: 24 * scale, height: 72 * scale).offset(x: 64 * scale, y: 16 * scale)
            }.frame(width: 88 * scale, height: 104 * scale, alignment: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }.accessibilityHidden(true)
    }
}

struct ChromeButtonStyle: ButtonStyle {
    var active = false
    var focused = false
    var hovered = false
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        let palette = LightTablePalette(dark: scheme == .dark)
        configuration.label
            .foregroundStyle(active || focused ? palette.accentText : palette.secondary)
            .frame(minWidth: 30, minHeight: 30)
            .background(active || focused ? palette.selectedFill : (configuration.isPressed || hovered ? palette.quietFill : .clear), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ChromeIconButton: View {
    let title: String
    let symbol: String
    var active = false
    var accessibilityState: String? = nil
    let action: () -> Void
    @FocusState private var keyboardFocused: Bool
    @State private var hovering = false
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .regular)) }
            .buttonStyle(ChromeButtonStyle(active: active, focused: keyboardFocused, hovered: hovering))
            .focusable().focused($keyboardFocused).focusEffectDisabled()
            .onHover { hovering = $0 }
            .accessibilityLabel(title).accessibilityValue(accessibilityState ?? (active ? "已选中" : ""))
            .accessibilityAddTraits(active && accessibilityState == nil ? .isSelected : []).help(title)
    }
}

/// Mark selection without tinting the photograph. Shared by the timeline
/// and continuous photo roll.
struct MediaSelectionTreatment: ViewModifier {
    let selected: Bool
    var selectionMode = false
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if selected || selectionMode {
                    ZStack {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(LightTablePalette(dark: scheme == .dark).accentText)
                        } else {
                            Circle().strokeBorder(.secondary.opacity(0.55), lineWidth: 1).padding(4)
                        }
                    }
                        .frame(width: 21, height: 21)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.13), radius: 3, y: 1)
                        .padding(7).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

struct QuietFocusTreatment: ViewModifier {
    @FocusState private var keyboardFocused: Bool
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let palette = LightTablePalette(dark: scheme == .dark)
        content
            .focusable().focused($keyboardFocused).focusEffectDisabled()
            .background(keyboardFocused ? palette.selectedFill : .clear, in: Capsule())
    }
}

/// One visual language for single-choice filters and format selections.
struct FilterChoiceButton: View {
    let title: String
    let selected: Bool
    var expands = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    @FocusState private var keyboardFocused: Bool
    private var palette: LightTablePalette { LightTablePalette(dark: scheme == .dark) }

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 12)
                .frame(maxWidth: expands ? .infinity : nil, minHeight: 30, maxHeight: 30)
                .foregroundStyle(selected ? palette.accentText : palette.secondary)
                .background(selected ? palette.selectedFill : (hovering && enabled ? palette.text.opacity(scheme == .dark ? 0.10 : 0.07) : palette.quietFill), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain).focusable().focused($keyboardFocused).focusEffectDisabled()
            .overlay {
                Capsule().strokeBorder(keyboardFocused && enabled ? palette.secondary.opacity(0.45) : .clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .opacity(enabled ? 1 : 0.4)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .onKeyPress(keys: [.space, .return], phases: .down) { _ in
                guard enabled else { return .ignored }
                action()
                return .handled
            }
    }
}

/// A plain native editor avoids the automatic macOS rectangular focus ring.
/// Focus is communicated by the surrounding search surface instead.
struct FilmboxSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = "搜索"
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.drawsBackground = false
        field.isBezeled = false
        field.isBordered = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("搜索名称或文件夹")
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        if field.stringValue != text { field.stringValue = text }
        if isFocused, !context.coordinator.isEditing {
            DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
                guard let field, let coordinator, coordinator.parent.isFocused,
                      !coordinator.isEditing, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) { field.delegate = nil }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FilmboxSearchField
        var isEditing = false
        init(parent: FilmboxSearchField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) {
            isEditing = true
            parent.isFocused = true
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            isEditing = false
            parent.isFocused = false
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if !parent.text.isEmpty {
                    parent.text = ""
                    (control as? NSTextField)?.stringValue = ""
                } else { control.window?.makeFirstResponder(nil) }
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

struct TimelineZoomControl: View {
    @Bindable var store: AppStore
    @Environment(\.colorScheme) private var scheme
    private var palette: LightTablePalette { LightTablePalette(dark: scheme == .dark) }
    var body: some View {
        HStack(spacing: 8) {
            Text("按\(store.layout == .browse ? store.browseTimelineScaleLabel : store.timelineScaleLabel)")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary).frame(width: 28)
            Button { store.zoomTimeline(-1) } label: { Image(systemName: "minus").frame(width: 20, height: 22) }
                .buttonStyle(.plain).help("缩小时间轴 (⌘−)").accessibilityLabel(store.layout == .browse ? "缩小照片卷时间轴" : "缩小时间线")
            Slider(value: Binding(get: { store.activeTimelineSize }, set: { store.setActiveTimelineSize($0) }), in: 64...280)
                .tint(LightTablePalette.blue).frame(width: 90).controlSize(.mini)
                .accessibilityLabel(store.layout == .browse ? "照片卷时间轴缩放" : "时间线缩放")
                .accessibilityValue("按\(store.layout == .browse ? store.browseTimelineScaleLabel : store.timelineScaleLabel)，\(Int(store.activeTimelineSize))")
            Button { store.zoomTimeline(1) } label: { Image(systemName: "plus").frame(width: 20, height: 22) }
                .buttonStyle(.plain).help("放大时间轴 (⌘+)").accessibilityLabel(store.layout == .browse ? "放大照片卷时间轴" : "放大时间线")
        }.foregroundStyle(palette.secondary)
    }
}
