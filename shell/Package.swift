// swift-tools-version: 6.0
import PackageDescription

// ADR 0008: the engine is WKWebView; the shell implements the brain protocol
// natively (BrainBridge.swift). The Rust/Servo host in ../host is dormant.
let package = Package(
    name: "Bowser",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "SurfaceKit")],
    targets: [
        .binaryTarget(name: "CLiteRTLM_mac", url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.18.0/CLiteRTLM_mac.xcframework.zip", checksum: "5f6ee68d95eeccb084c6e66d5ee47255e3020fa0fb29696dd0301ae26d6cfb4f"),
        .target(name: "HistoryCore"),
        .executableTarget(name: "BowserHistoryWorker", dependencies: ["HistoryCore", "CLiteRTLM_mac"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .target(name: "BackendRuntime", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "BowserBackendHost", dependencies: ["BackendRuntime"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "BowserRuntimeTool", dependencies: ["BackendRuntime"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "IconRendering"),
        .executableTarget(name: "BowserIconWorker", dependencies: ["IconRendering"]),
        .executableTarget(
            name: "Bowser",
            dependencies: ["BackendRuntime", "HistoryCore", .product(name: "BowserSurfaceKit", package: "SurfaceKit")],
            path: "Sources/Bowser",
            resources: [.copy("Resources/ProfileCharacters"), .copy("Resources/AppIcon.png")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "BowserTests",
            dependencies: ["Bowser", "IconRendering"],
            path: "Tests/BowserTests"
        ),
        .testTarget(name: "HistoryCoreTests", dependencies: ["HistoryCore"]),
    ]
)
