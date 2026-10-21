// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WinSCPMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WinSCPMac", targets: ["WinSCPMac"])],
    targets: [
        .target(name: "CCurlTransport", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "WinSCPCore", dependencies: ["CCurlTransport"]),
        .executableTarget(name: "WinSCPMac", dependencies: ["WinSCPCore"]),
        .testTarget(name: "WinSCPCoreTests", dependencies: ["WinSCPCore"])
    ]
)
