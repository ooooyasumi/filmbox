import FilmboxCore

func parentSelectionCanExcludeChildAndRestorePartialParent() throws {
    var selection = DirectorySelection()
    selection.toggle("/Photos")
    try expect(selection.contains("/Photos/2024/trip.jpg"))
    try expect(selection.state(for: "/Photos/2024") == .all)
    selection.toggle("/Photos/2024")
    try expect(!selection.contains("/Photos/2024/trip.jpg"))
    try expect(selection.contains("/Photos/2025/trip.jpg"))
    try expect(selection.state(for: "/Photos") == .partial)
    selection.toggle("/Photos")
    try expect(selection.state(for: "/Photos") == .all)
    try expect(selection.excluded.isEmpty)
    try expect(selection.included == ["/Photos"])
}

func mostSpecificRuleWinsAndDirectoryBoundariesAreRespected() throws {
    var selection = DirectorySelection(
        included: ["/Photos", "/Photos/2024/Keep"],
        excluded: ["/Photos/2024"]
    )
    try expect(selection.contains("/Photos/2024/Keep/memory.jpg"))
    try expect(!selection.contains("/Photos/2024/Other/memory.jpg"))
    try expect(!selection.contains("/Photos-old/memory.jpg"))
    try expect(selection.state(for: "/Photos/2024") == .partial)
    selection.toggle("/Photos")
    try expect(selection.state(for: "/Photos") == .all)
    selection.toggle("/Photos")
    try expect(selection.state(for: "/Photos") == .none)
    try expect(selection.included.isEmpty)
    try expect(selection.excluded == ["/Photos"])
}

func selectingChildMarksAncestorPartialAndPreservesSibling() throws {
    var selection = DirectorySelection()
    selection.toggle("/Photos/Trip")
    selection.toggle("/Videos")
    try expect(selection.state(for: "/Photos") == .partial)
    try expect(selection.state(for: "/Photos/Other") == .none)
    try expect(selection.state(for: "/Videos") == .all)
    selection.toggle("/Photos")
    try expect(selection.state(for: "/Photos") == .all)
    try expect(selection.contains("/Videos/movie.mov"))
}

func rootAndNormalizedPathsHavePredictableRules() throws {
    var selection = DirectorySelection(included: ["/"])
    try expect(selection.contains("/anywhere/photo.jpg"))
    selection.toggle("/Photos/../Private/")
    try expect(!selection.contains("/Private/photo.jpg"))
    try expect(selection.contains("/Private-old/photo.jpg"))
    try expect(selection.state(for: "/") == .partial)
    selection.toggle("/")
    try expect(selection.state(for: "/") == .all)
}
