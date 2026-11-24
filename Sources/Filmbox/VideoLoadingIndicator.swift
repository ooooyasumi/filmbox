import SwiftUI

/// Media buffering uses the same wording in the grid, roll and viewer.
struct VideoLoadingIndicator: View {
    let title: String
    var compact = false
    @State private var presented = false

    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small).frame(width: 18, height: 18)
            if !compact { Text(title).font(.system(size: 12, weight: .medium)) }
        }
        .padding(.horizontal, compact ? 10 : 15).padding(.vertical, 11)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .allowsHitTesting(false)
        .opacity(presented ? 1 : 0)
        .accessibilityHidden(!presented)
        .task(id: title) {
            presented = false
            do { try await Task.sleep(for: .milliseconds(title == MediaLoadingText.loading ? 600 : 220)) } catch { return }
            guard !Task.isCancelled else { return }
            presented = true
        }
    }
}
