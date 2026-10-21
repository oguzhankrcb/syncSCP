// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SyncSCP",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SyncSCP", targets: ["SyncSCP"])],
    targets: [
        .target(name: "CCurlTransport", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "SyncSCPCore", dependencies: ["CCurlTransport"]),
        .executableTarget(name: "SyncSCP", dependencies: ["SyncSCPCore"]),
        .testTarget(name: "SyncSCPCoreTests", dependencies: ["SyncSCPCore"])
    ]
)
