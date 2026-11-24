#if canImport(Testing)
import Foundation
import FilmboxCore
import Testing

@Test func legacyCatalogStillDecodesLocalItemsAndDefaultsCloudAccounts() throws {
    let original = MediaItem(url: URL(fileURLWithPath: "/Volumes/Media/Trip/../Trip/photo.jpg"), kind: .image,
                             fileSize: 123, modifiedDate: .distantPast, createdDate: .distantPast)
    let library = MediaLibrary(url: URL(fileURLWithPath: "/Volumes/Media/Trip"), name: "旅行")
    let folder = MediaFolder(url: library.url, name: library.name)
    let encoder = JSONEncoder()
    let encoded = try encoder.encode(CatalogState(libraries: [library], cachedItems: [original]))
    var legacyJSON = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacyJSON.removeValue(forKey: "cloudAccounts")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
    let restored = try JSONDecoder().decode(CatalogState.self, from: legacyData)
    #expect(restored.cloudAccounts.isEmpty)
    #expect(restored.cachedItems == [original])
    #expect(restored.cachedItems[0].cloud == nil)
    #expect(restored.cachedItems[0].id == "/Volumes/Media/Trip/photo.jpg")
    #expect(restored.cachedItems[0].selectionPath == original.id)
    #expect(restored.cachedItems[0].belongs(to: library))
    #expect(folder.isLocal)
    #expect(folder.selectionPath == library.selectionPath)
    #expect(folder.belongs(to: library))
}

@Test func cloudIdentitySurvivesRenameMoveAndSignedThumbnailReplacement() throws {
    let accountID = UUID()
    let originalReference = CloudMediaReference(accountID: accountID, fileID: "file-01", parentID: "folder-01",
                                               remotePath: "/旅行/日出.jpg", revision: "v1",
                                               thumbnailURL: URL(string: "https://example.com/thumb?token=one"))
    let movedReference = CloudMediaReference(accountID: accountID, fileID: "file-01", parentID: "folder-02",
                                            remotePath: "/影集/海边 日出.jpg", revision: "v2",
                                            thumbnailURL: URL(string: "https://example.com/thumb?token=two"))
    let original = makeCloudItem(originalReference)
    let moved = makeCloudItem(movedReference)
    #expect(original.id == moved.id)
    #expect(original.id == "cloud:\(accountID.uuidString):file-01")
    #expect(original.selectionPath != moved.selectionPath)
    #expect(moved.name == "海边 日出.jpg")
    #expect(moved.displayPath == "/影集/海边 日出.jpg")
    #expect(!moved.isLocal)
    #expect(!moved.url.isFileURL)
    #expect(moved.url.scheme == "filmbox-cloud")
    #expect(moved.url.host == accountID.uuidString.lowercased())
    #expect(moved.url.path == moved.displayPath)
    #expect(moved.relocated(to: URL(fileURLWithPath: "/tmp/wrong.jpg")) == moved)
    let restored = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(moved))
    #expect(restored == moved)
}

@Test func mixedCloudAccountsAndLocalMediaHaveIndependentIdentityAndScope() throws {
    let baidu = CloudAccount(provider: .baidu, name: "百度")
    let quark = CloudAccount(provider: .quark, name: "夸克")
    let webdav = CloudAccount(provider: .webdav, name: "NAS", endpoint: URL(string: "https://nas.example.com/dav"))
    let baiduItem = makeCloudItem(CloudMediaReference(accountID: baidu.id, fileID: "100", parentID: "10", remotePath: "/Trips/a.jpg", revision: "1"))
    let quarkItem = makeCloudItem(CloudMediaReference(accountID: quark.id, fileID: "100", parentID: "10", remotePath: "/Trips/a.jpg", revision: "1"))
    let localItem = MediaItem(url: URL(fileURLWithPath: "/Trips/a.jpg"), kind: .image,
                              fileSize: 1, modifiedDate: .distantPast, createdDate: .distantPast)
    let library = MediaLibrary(cloud: CloudLibraryReference(accountID: baidu.id, folderID: "10", path: "/Trips"), name: "旅程")
    #expect(Set([baiduItem.id, quarkItem.id, localItem.id]).count == 3)
    #expect(baiduItem.belongs(to: library))
    #expect(!quarkItem.belongs(to: library))
    #expect(!localItem.belongs(to: library))
    #expect(!library.isLocal)
    #expect(library.bookmark == nil)
    #expect(try library.resolvedURL() == library.url)
    let album = MediaAlbum(name: "混合影集", itemIDs: [baiduItem.id, quarkItem.id, localItem.id])
    let state = CatalogState(libraries: [library], favorites: [baiduItem.id], cachedItems: [baiduItem, quarkItem, localItem],
                             hiddenIDs: [quarkItem.id], albums: [album], cloudAccounts: [baidu, quark, webdav])
    let restored = try JSONDecoder().decode(CatalogState.self, from: JSONEncoder().encode(state))
    #expect(restored.cloudAccounts == [baidu, quark, webdav])
    #expect(restored.libraries == state.libraries)
    #expect(restored.cachedItems == state.cachedItems)
    #expect(restored.favorites == state.favorites)
    #expect(restored.hiddenIDs == state.hiddenIDs)
    #expect(restored.albums == state.albums)
}

@Test func cloudFolderSelectionHonorsAccountAndDirectoryBoundaries() {
    let accountID = UUID()
    let otherID = UUID()
    let library = MediaLibrary(cloud: CloudLibraryReference(accountID: accountID, folderID: "10", path: "/Trips"))
    let child = MediaFolder(cloud: CloudFolderReference(accountID: accountID, folderID: "11", path: "/Trips/Summer"))
    let neighbor = makeCloudItem(CloudMediaReference(accountID: accountID, fileID: "12", parentID: "12", remotePath: "/Trips-old/a.jpg", revision: "1"))
    let nested = makeCloudItem(CloudMediaReference(accountID: accountID, fileID: "13", parentID: "11", remotePath: "/Trips/Summer/b.jpg", revision: "1"))
    let unrelated = makeCloudItem(CloudMediaReference(accountID: otherID, fileID: "13", parentID: "11", remotePath: "/Trips/Summer/b.jpg", revision: "1"))
    let root = MediaFolder(cloud: CloudFolderReference(accountID: accountID, folderID: "0", path: "/"))
    #expect(child.belongs(to: library))
    #expect(child.parentPath == library.selectionPath)
    #expect(root.parentPath == nil)
    #expect(!neighbor.belongs(to: library))
    #expect(nested.belongs(to: library))
    #expect(!unrelated.belongs(to: library))
    var selection = DirectorySelection(included: [library.selectionPath])
    #expect(selection.contains(nested.selectionPath))
    #expect(!selection.contains(neighbor.selectionPath))
    #expect(!selection.contains(unrelated.selectionPath))
    selection.toggle(child.selectionPath)
    #expect(!selection.contains(nested.selectionPath))
    #expect(selection.state(for: library.selectionPath) == .partial)
}

@Test func cloudLogicalPathsNormalizeWithoutEscapingTheirAccountNamespace() {
    let accountID = UUID()
    let first = CloudLibraryReference(accountID: accountID, folderID: "0", path: "/")
    let traversal = CloudMediaReference(accountID: accountID, fileID: "a", parentID: "0",
                                       remotePath: "../../旅行/./海边//日出 #1 %.heic", revision: "1")
    #expect(traversal.remotePath == "/旅行/海边/日出 #1 %.heic")
    #expect(DirectorySelection.isWithin(traversal.selectionPath, directory: first.selectionPath))
    #expect(traversal.locatorURL.path == traversal.remotePath)
    #expect(traversal.locatorURL.query == nil)
    #expect(traversal.locatorURL.fragment == nil)
}

private func makeCloudItem(_ reference: CloudMediaReference) -> MediaItem {
    MediaItem(cloud: reference, kind: .image, fileSize: 1_024, modifiedDate: Date(timeIntervalSince1970: 1_700_000_000),
              createdDate: Date(timeIntervalSince1970: 1_600_000_000), pixelWidth: 6000, pixelHeight: 4000)
}
#endif
