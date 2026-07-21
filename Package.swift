// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentIsland", targets: ["AgentIsland"])
    ],
    targets: [
        .executableTarget(
            name: "AgentIsland",
            path: "macos/Sources/AgentIsland",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AgentIslandTests",
            dependencies: ["AgentIsland"],
            path: "macos/Tests/AgentIslandTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
