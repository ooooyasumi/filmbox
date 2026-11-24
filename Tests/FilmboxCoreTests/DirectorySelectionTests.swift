#if canImport(Testing)
import FilmboxCore
import Testing

@Test func parentSelectionCanExcludeChildAndRestorePartialParent() {
    var selection = DirectorySelection()
    selection.toggle("/Photos")
    #expect(selection.contains("/Photos/2024/trip.jpg"))
    #expect(selection.state(for: "/Photos/2024") == .all)
    selection.toggle("/Photos/2024")
    #expect(!selection.contains("/Photos/2024/trip.jpg"))
    #expect(selection.contains("/Photos/2025/trip.jpg"))
    #expect(selection.state(for: "/Photos") == .partial)
    selection.toggle("/Photos")
    #expect(selection.state(for: "/Photos") == .all)
    #expect(selection.excluded.isEmpty)
    #expect(selection.included == ["/Photos"])
}

@Test func mostSpecificRuleWinsAndDirectoryBoundariesAreRespected() {
    var selection = DirectorySelection(
        included: ["/Photos", "/Photos/2024/Keep"],
        excluded: ["/Photos/2024"]
    )
    #expect(selection.contains("/Photos/2024/Keep/memory.jpg"))
    #expect(!selection.contains("/Photos/2024/Other/memory.jpg"))
    #expect(!selection.contains("/Photos-old/memory.jpg"))
    #expect(selection.state(for: "/Photos/2024") == .partial)
    selection.toggle("/Photos")
    #expect(selection.state(for: "/Photos") == .all)
    selection.toggle("/Photos")
    #expect(selection.state(for: "/Photos") == .none)
    #expect(selection.included.isEmpty)
    #expect(selection.excluded == ["/Photos"])
}

@Test func selectingChildMarksAncestorPartialAndPreservesSibling() {
    var selection = DirectorySelection()
    selection.toggle("/Photos/Trip")
    selection.toggle("/Videos")
    #expect(selection.state(for: "/Photos") == .partial)
    #expect(selection.state(for: "/Photos/Other") == .none)
    #expect(selection.state(for: "/Videos") == .all)
    selection.toggle("/Photos")
    #expect(selection.state(for: "/Photos") == .all)
    #expect(selection.contains("/Videos/movie.mov"))
}

@Test func rootAndNormalizedPathsHavePredictableRules() {
    var selection = DirectorySelection(included: ["/"])
    #expect(selection.contains("/anywhere/photo.jpg"))
    selection.toggle("/Photos/../Private/")
    #expect(!selection.contains("/Private/photo.jpg"))
    #expect(selection.contains("/Private-old/photo.jpg"))
    #expect(selection.state(for: "/") == .partial)
    selection.toggle("/")
    #expect(selection.state(for: "/") == .all)
}

#endif
