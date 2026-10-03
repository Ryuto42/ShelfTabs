// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ShelfTabs",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "ShelfTabs",
            path: "Sources/ShelfTabs"
        )
    ],
    swiftLanguageModes: [.v5]
)
