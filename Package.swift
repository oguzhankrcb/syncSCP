// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SyncSCP",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SyncSCP", targets: ["SyncSCP"]), .executable(name: "syncscp-cli", targets: ["syncscp-cli"])],
    dependencies: [
        // Terminal emulator for the SSH terminal window (MIT). Pinned exactly; update deliberately.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0")
    ],
    targets: [
        .target(name: "CCurlTransport", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "SyncSCPCore", dependencies: ["CCurlTransport"]),
        .executableTarget(name: "SyncSCP", dependencies: ["SyncSCPCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "syncscp-cli", dependencies: ["SyncSCPCore"]),
        .testTarget(name: "SyncSCPCoreTests", dependencies: ["SyncSCPCore"])
    ]
)
