// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vela",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "LockLab", targets: ["LockLab"]),
        .executable(name: "Vela", targets: ["Vela"]),
        .executable(name: "VelaConnect", targets: ["VelaConnect"])
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "154.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5")
    ],
    targets: [
        .executableTarget(name: "LockLab", dependencies: ["VelaLocalization"]),
        .target(name: "VelaLocalization", resources: [.copy("Resources/zh-Hans.json")]),
        .target(name: "LidServiceShared"),
        .target(name: "AppUpdateCore"),
        .target(name: "RemoteNetworkBridge"),
        .target(name: "RemoteCore", dependencies: ["RemoteNetworkBridge"]),
        .target(name: "RemoteDisplayBridge", linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]),
        .target(name: "RemoteRTC", dependencies: ["RemoteCore", "RemoteDisplayBridge", .product(name: "WebRTC", package: "WebRTC")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RemoteServer", dependencies: ["RemoteCore", "RemoteRTC",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl")],
            resources: [.copy("Web")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "VelaConnect", dependencies: ["VelaLocalization", "RemoteCore", "RemoteRTC"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Vela", dependencies: ["VelaLocalization", "LidServiceShared", "RemoteCore", "RemoteServer", "AppUpdateCore"], resources: [.copy("Assets")]),
        .testTarget(name: "VelaLocalizationTests", dependencies: ["VelaLocalization", "RemoteCore"]),
        .testTarget(name: "AppUpdateCoreTests", dependencies: ["AppUpdateCore"]),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"]),
        .testTarget(name: "RemoteServerTests", dependencies: ["RemoteServer"])
    ]
)
