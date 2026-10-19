// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Vinyl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Vinyl",
            path: "Sources/Vinyl"
        )
    ]
)
