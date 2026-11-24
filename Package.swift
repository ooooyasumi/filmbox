// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Filmbox",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Filmbox", targets: ["Filmbox"])],
    targets: [
        .target(name: "FilmboxCore"),
        .executableTarget(name: "Filmbox", dependencies: ["FilmboxCore"]),
        .testTarget(name: "FilmboxCoreTests", dependencies: ["FilmboxCore"]),
        .executableTarget(name: "FilmboxCoreChecks", dependencies: ["FilmboxCore"], path: "Tests/FilmboxCoreChecks")
    ],
    swiftLanguageModes: [.v6]
)
