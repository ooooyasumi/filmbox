#if canImport(Testing)
import Foundation
import FilmboxCore
import Testing

@Test func persistenceRoundTripRetainsLibrariesFavoritesAndOfflineMetadata() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = CatalogPersistence(directory: directory.appendingPathComponent("Application Support/Filmbox"))
    let library = MediaLibrary(url: URL(fileURLWithPath: "/Volumes/相片/家庭"), bookmark: Data([1, 2, 3]), name: "家庭")
    let item = MediaItem(
        url: library.url.appendingPathComponent("旅行.jpg"), kind: .image, fileSize: 12_345,
        modifiedDate: Date(timeIntervalSince1970: 1_600_000_000),
        createdDate: Date(timeIntervalSince1970: 1_500_000_000),
        pixelWidth: 6000, pixelHeight: 4000, camera: "Canon EOS R5"
    )
    try persistence.save(CatalogState(libraries: [library], favorites: [item.id], cachedItems: [item]))
    let restored = try persistence.load()
    #expect(restored.libraries == [library])
    #expect(restored.favorites == [item.id])
    #expect(restored.cachedItems == [item])
    #expect(FileManager.default.fileExists(atPath: persistence.fileURL.path))
    try persistence.save(CatalogState())
    #expect(try persistence.load().libraries.isEmpty)
}

@Test func absentCatalogIsEmptyButCorruptCatalogReportsErrorAndPreservesBytes() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = CatalogPersistence(directory: directory)
    #expect(try persistence.load().libraries.isEmpty)
    let corrupt = Data("{this is broken".utf8)
    try corrupt.write(to: persistence.fileURL)
    #expect(throws: CatalogPersistenceError.self) { try persistence.load() }
    #expect(try Data(contentsOf: persistence.fileURL) == corrupt)
}

@Test func catalogWithoutCacheMigratesToEmptyCache() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = CatalogPersistence(directory: directory)
    try Data("{\"libraries\":[],\"favorites\":[]}".utf8).write(to: persistence.fileURL)
    #expect(try persistence.load().cachedItems.isEmpty)
    #expect(try persistence.load().hiddenIDs.isEmpty)
    #expect(try persistence.load().albums.isEmpty)
}

@Test func catalogRoundTripsHiddenMembershipAndLogicalAlbums() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = CatalogPersistence(directory: directory)
    let album = MediaAlbum(name: "旅行", itemIDs: ["/Media/a.jpg", "/Media/b.mov"], createdDate: Date(timeIntervalSince1970: 1_700_000_000))
    try persistence.save(CatalogState(favorites: ["/Media/a.jpg"], hiddenIDs: ["/Media/a.jpg"], albums: [album]))
    let restored = try persistence.load()
    #expect(restored.albums == [album])
    #expect(restored.hiddenIDs == ["/Media/a.jpg"])
    #expect(restored.favorites == ["/Media/a.jpg"])
    #expect(restored.cachedItems.isEmpty)
}

@Test func malformedManagementFieldsRemainReportedAsCorruption() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = CatalogPersistence(directory: directory)
    for json in [
        "{\"libraries\":[],\"favorites\":[],\"hiddenIDs\":3}",
        "{\"libraries\":[],\"favorites\":[],\"albums\":[{\"name\":\"broken\"}]}"
    ] {
        let original = Data(json.utf8)
        try original.write(to: persistence.fileURL)
        #expect(throws: CatalogPersistenceError.self) { try persistence.load() }
        #expect(try Data(contentsOf: persistence.fileURL) == original)
    }
}

@Test func corruptCatalogBackupIsUniqueAndPreservesOriginal() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = CatalogPersistence(directory: directory)
    let original = Data("{invalid original catalog".utf8)
    try original.write(to: persistence.fileURL)
    let first = try persistence.backupCorruptCatalog()
    let second = try persistence.backupCorruptCatalog()
    #expect(first != second)
    #expect(try Data(contentsOf: first) == original)
    #expect(try Data(contentsOf: second) == original)
    #expect(try Data(contentsOf: persistence.fileURL) == original)
    try persistence.save(CatalogState())
    #expect(try persistence.load().libraries.isEmpty)
    #expect(try Data(contentsOf: first) == original)
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FilmboxTests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

#endif
