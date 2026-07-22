// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cowork",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .target(name: "CoworkCore"),
        // The sugar layer's own module (ADR 002): provisioning that the core must not
        // know about — ADR 002's confirmation is "no core code references git", so
        // worktree logic lives here, testable, outside CoworkCore.
        .target(name: "CoworkSugar"),
        .executableTarget(name: "cowork", dependencies: [
            "CoworkCore",
            "CoworkSugar",
            .product(name: "MCP", package: "swift-sdk"),
        ]),
        .testTarget(name: "CoworkCoreTests", dependencies: ["CoworkCore", "CoworkSugar"]),
    ]
)
