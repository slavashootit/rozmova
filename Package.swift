// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rozmova",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Parakeet speech recognition on the Neural Engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "Rozmova",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Rozmova",
            // Not autolinked by `swift build`; without it the player crashes at runtime.
            linkerSettings: [.linkedFramework("AVKit")]
        )
    ]
)
