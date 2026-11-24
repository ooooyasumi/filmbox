import AppKit
import FilmboxCore

/// Metadata is learned independently of image delivery. Batch geometry updates
/// after interaction settles so a cover cannot rebuild the entire visible list.
@MainActor final class CloudMetadataUpdates {
    static let shared = CloudMetadataUpdates()
    private final class Batch {
        weak var store: AppStore?
        var values: [String: [AnyHashable: Any]] = [:]
        var task: Task<Void, Never>?
        init(_ store: AppStore) { self.store = store }
    }
    private var batches: [ObjectIdentifier: Batch] = [:]
    private var lastInteraction = Date.distantPast

    func noteInteraction() { lastInteraction = .now }

    func enqueue(_ notification: Notification, store: AppStore) {
        guard let values = notification.userInfo, let id = values["id"] as? String,
              let revision = values["revision"] as? String else { return }
        let identity = id + "|" + revision
        let key = ObjectIdentifier(store)
        let batch = batches[key] ?? Batch(store)
        batch.values[identity, default: [:]].merge(values) { _, new in new }
        batches[key] = batch
        guard batch.task == nil else { return }
        batch.task = Task { [weak self, weak batch] in
            do {
                try await Task.sleep(for: .milliseconds(400))
                let deadline = Date().addingTimeInterval(2)
                while let self, Date() < deadline, Date().timeIntervalSince(self.lastInteraction) < 0.22 || NSEvent.pressedMouseButtons != 0 {
                    try await Task.sleep(for: .milliseconds(120))
                }
            } catch { return }
            guard let self, let batch else { return }
            // An import or a warm cache may deliver thousands at once. Bound
            // each main-thread turn and yield to input between commits. Keep
            // the same queue while draining so newer values cannot be overtaken
            // by an older chunk for the same media.
            while !batch.values.isEmpty {
                let values = Array(batch.values.values)
                batch.values.removeAll(keepingCapacity: true)
                for offset in stride(from: 0, to: values.count, by: 256) {
                    guard let store = batch.store else { self.batches[key] = nil; return }
                    store.commitCloudMetadata(Array(values[offset..<min(values.count, offset + 256)]))
                    if offset + 256 < values.count || !batch.values.isEmpty {
                        do { try await Task.sleep(for: .milliseconds(8)) } catch { self.batches[key] = nil; return }
                    }
                }
            }
            batch.task = nil
            self.batches[key] = nil
        }
    }
}
