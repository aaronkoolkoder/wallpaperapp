// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Diorama",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Diorama", targets: ["DioramaApp"]),
        .executable(name: "wetool", targets: ["wetool"]),
        .library(name: "WEFormat", targets: ["WEFormat"]),
    ],
    targets: [
        // Leaf: pure parsing. No GPU, no UI, no AppKit.
        .target(name: "WEFormat"),

        // Leaf: WE GLSL -> MSL.
        .target(name: "ShaderTranspiler"),

        // Leaf: Metal render graph, FBO pool, caches.
        .target(name: "MetalRenderer"),

        // Leaf: desktop surfaces, display topology, power policy.
        .target(name: "WallpaperKit"),

        // Leaf: compatibility reports, perf sampling.
        .target(name: "Diagnostics"),

        .target(name: "LibraryKit", dependencies: ["WEFormat", "Diagnostics"]),

        .target(name: "SceneEngine", dependencies: ["WEFormat", "MetalRenderer", "ShaderTranspiler", "Diagnostics"]),

        .target(name: "PlayerCore", dependencies: ["WallpaperKit", "SceneEngine", "LibraryKit", "Diagnostics"]),

        .executableTarget(
            name: "DioramaApp",
            dependencies: ["PlayerCore", "WallpaperKit", "LibraryKit", "SceneEngine", "Diagnostics"]
        ),

        .executableTarget(name: "wetool", dependencies: ["WEFormat", "ShaderTranspiler", "LibraryKit", "SceneEngine", "MetalRenderer"]),

        .testTarget(name: "WEFormatTests", dependencies: ["WEFormat"]),
        .testTarget(name: "ShaderTranspilerTests", dependencies: ["ShaderTranspiler"]),
        .testTarget(name: "SceneEngineTests", dependencies: ["SceneEngine"]),
        .testTarget(name: "WallpaperKitTests", dependencies: ["WallpaperKit"]),
        .testTarget(name: "LibraryKitTests", dependencies: ["LibraryKit"]),
    ]
)
