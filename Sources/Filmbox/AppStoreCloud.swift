import AppKit
import FilmboxCore

@MainActor extension AppStore {
    func beginCloudConnection() {
        reconnectCloudAccount = nil
        showCloudConnection = true
    }

    func addCloudLibrary(account: CloudAccount, reference: CloudLibraryReference, name: String) {
        if reconnectCloudAccount?.id == account.id {
            updateCloudAccount(account)
            reconnectCloudAccount = nil
            showCloudConnection = false
            return
        }
        if let index = cloudAccounts.firstIndex(where: { $0.id == account.id }) { cloudAccounts[index] = account }
        else { cloudAccounts.append(account) }
        var addedID: UUID?
        if !libraries.contains(where: { $0.cloud == reference }) {
            let prefix = account.provider.displayName
            let title = reference.path == "/" ? prefix : name
            let library = MediaLibrary(cloud: reference, name: title)
            libraries.append(library)
            addedID = library.id
        }
        reconnectCloudAccount = nil
        showCloudConnection = false
        scope = .all
        save()
        if let addedID { refreshCloudLibrary(addedID) }
    }

    func reconnectAccount(_ account: CloudAccount) {
        reconnectCloudAccount = account
        showCloudConnection = true
    }

    func updateCloudAccount(_ account: CloudAccount) {
        if let index = cloudAccounts.firstIndex(where: { $0.id == account.id }) { cloudAccounts[index] = account }
        else { cloudAccounts.append(account) }
        save()
        for library in libraries where library.cloud?.accountID == account.id { refreshCloudLibrary(library.id, restart: true) }
        NotificationCenter.default.post(name: Notification.Name("FilmboxPreviewRetry"), object: nil)
    }

    func applyCloudMetadata(_ notification: Notification) {
        CloudMetadataUpdates.shared.enqueue(notification, store: self)
    }

    func commitCloudMetadata(_ batch: [[AnyHashable: Any]]) {
        var updates: [String: MediaItem] = [:]
        var geometry = Set<String>()
        for values in batch {
        guard let id = values["id"] as? String,
              let revision = values["revision"] as? String,
              let old = updates[id] ?? cachedMediaItem(id: id), let cloud = old.cloud,
              cloud.revision == revision else { continue }
        let ratio = (values["ratio"] as? Double) ?? old.previewAspectRatio
        let updated = MediaItem(url: old.url, kind: old.kind, fileSize: old.fileSize, modifiedDate: old.modifiedDate,
                                createdDate: old.createdDate, capturedDate: values["capturedDate"] as? Date ?? old.capturedDate,
                                pixelWidth: values["width"] as? Int ?? old.pixelWidth,
                                pixelHeight: values["height"] as? Int ?? old.pixelHeight,
                                camera: values["camera"] as? String ?? old.camera, lens: values["lens"] as? String ?? old.lens,
                                aperture: values["aperture"] as? Double ?? old.aperture,
                                focalLength: values["focalLength"] as? Double ?? old.focalLength,
                                iso: values["iso"] as? Int ?? old.iso, exposure: values["exposure"] as? String ?? old.exposure,
                                duration: values["duration"] as? Double ?? old.duration, cloud: cloud, previewAspectRatio: ratio)
        guard updated != old else { continue }
        if (old.aspectRatio ?? 1) != (updated.aspectRatio ?? 1) { geometry.insert(id) }
        updates[id] = updated
        }
        guard !updates.isEmpty else { return }
        updateCachedMediaItems(updates)
        // Date ordering remains stable until an explicit sort or refresh.
        publishVisibleMetadata(updates, geometryChangedIDs: geometry)
        saveMetadataChanges()
    }

    func downloadOriginals(_ targets: [MediaItem]) {
        let remote = targets.filter { !$0.isLocal }
        guard !remote.isEmpty else { return }
        Task {
            var completed = 0
            for item in remote {
                do {
                    _ = try await MediaAssetResolver.shared.originalFile(for: item, priority: .background)
                    completed += 1
                } catch is CancellationError { break }
                catch { notify(error.localizedDescription); break }
            }
            if completed == remote.count { notify("已下载 \(completed) 个原文件") }
            NotificationCenter.default.post(name: Notification.Name("FilmboxPreviewRetry"), object: nil)
        }
    }

    func disconnectAccount(_ account: CloudAccount) {
        let linked = libraries.filter { $0.cloud?.accountID == account.id }
        for library in linked { removeLibrary(library) }
        cloudAccounts.removeAll { $0.id == account.id }
        save()
        Task {
            do { try await CloudGateway.shared.forget(accountID: account.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    /// Copy/export succeeds only after every requested original is available.
    /// No signed URL or internal cloud locator is placed on the pasteboard.
    func materialize(_ targets: [MediaItem], completion: @escaping @MainActor ([URL]) -> Void) {
        guard !targets.isEmpty else { return }
        if targets.allSatisfy(\.isLocal) { completion(targets.map(\.url)); return }
        notify("正在准备 \(targets.count) 个文件…")
        Task {
            let lease = await MediaAssetResolver.shared.acquireExportLease(for: targets)
            do {
                var urls: [URL] = []
                for item in targets {
                    try Task.checkCancellation()
                    let url = try await MediaAssetResolver.shared.originalFile(for: item)
                    urls.append(url)
                }
                completion(urls)
                await MediaAssetResolver.shared.retainExportLease(lease)
            } catch is CancellationError { await MediaAssetResolver.shared.releaseExportLease(lease) }
            catch {
                await MediaAssetResolver.shared.releaseExportLease(lease)
                errorMessage = "无法准备云端文件：\(error.localizedDescription)"
            }
        }
    }
}
