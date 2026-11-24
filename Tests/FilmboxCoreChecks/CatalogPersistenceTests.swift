import Foundation
import FilmboxCore

func persistenceRoundTripRetainsLibrariesFavoritesAndOfflineMetadata() throws {
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
    try expect(restored.libraries == [library])
    try expect(restored.favorites == [item.id])
    try expect(restored.cachedItems == [item])
    try expect(FileManager.default.fileExists(atPath: persistence.fileURL.path))
    try persistence.save(CatalogState())
    try expect(try persistence.load().libraries.isEmpty)
}

func absentCatalogIsEmptyButCorruptCatalogReportsErrorAndPreservesBytes() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = CatalogPersistence(directory: directory)
    try expect(try persistence.load().libraries.isEmpty)
    let corrupt = Data("{this is broken".utf8)
    try corrupt.write(to: persistence.fileURL)
    try expectThrows(CatalogPersistenceError.self) { try persistence.load() }
    try expect(try Data(contentsOf: persistence.fileURL) == corrupt)
}

func catalogWithoutCacheMigratesToEmptyCache() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = CatalogPersistence(directory: directory)
    try Data("{\"libraries\":[],\"favorites\":[]}".utf8).write(to: persistence.fileURL)
    try expect(try persistence.load().cachedItems.isEmpty)
    try expect(try persistence.load().hiddenIDs.isEmpty)
    try expect(try persistence.load().albums.isEmpty)
}

func catalogRoundTripsHiddenMembershipAndLogicalAlbums() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = CatalogPersistence(directory: directory)
    let album = MediaAlbum(name: "旅行", itemIDs: ["/Media/a.jpg", "/Media/b.mov"], createdDate: Date(timeIntervalSince1970: 1_700_000_000))
    try persistence.save(CatalogState(favorites: ["/Media/a.jpg"], hiddenIDs: ["/Media/a.jpg"], albums: [album]))
    let restored = try persistence.load()
    try expect(restored.albums == [album])
    try expect(restored.hiddenIDs == ["/Media/a.jpg"])
    try expect(restored.favorites == ["/Media/a.jpg"])
    try expect(restored.cachedItems.isEmpty)
}

func malformedManagementFieldsRemainReportedAsCorruption() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = CatalogPersistence(directory: directory)
    for json in [
        "{\"libraries\":[],\"favorites\":[],\"hiddenIDs\":3}",
        "{\"libraries\":[],\"favorites\":[],\"albums\":[{\"name\":\"broken\"}]}"
    ] {
        let original = Data(json.utf8)
        try original.write(to: persistence.fileURL)
        try expectThrows(CatalogPersistenceError.self) { try persistence.load() }
        try expect(try Data(contentsOf: persistence.fileURL) == original)
    }
}

func corruptCatalogBackupIsUniqueAndPreservesOriginal() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = CatalogPersistence(directory: directory)
    let original = Data("{invalid original catalog".utf8)
    try original.write(to: persistence.fileURL)
    let first = try persistence.backupCorruptCatalog()
    let second = try persistence.backupCorruptCatalog()
    try expect(first != second)
    try expect(try Data(contentsOf: first) == original)
    try expect(try Data(contentsOf: second) == original)
    try expect(try Data(contentsOf: persistence.fileURL) == original)
    try persistence.save(CatalogState())
    try expect(try persistence.load().libraries.isEmpty)
    try expect(try Data(contentsOf: first) == original)
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FilmboxTests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
